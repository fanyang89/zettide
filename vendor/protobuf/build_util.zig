const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const PROTOC_VERSION = "32.1";

// File system utilities
pub fn pathExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn ensureProtocBinaryDownloaded(
    protoc_owner: *std.Build,
    step: *std.Build.Step,
) !?[]const u8 {
    if (try getProtocBin(protoc_owner, step)) |executable_path| {
        if (pathExists(step.owner.graph.io, executable_path)) {
            return executable_path;
        }
        std.log.err("zig-protobuf: file not found: {s}", .{executable_path});
        std.process.exit(1);
    }
    return null;
}

pub fn getProtocDependency(b: *std.Build) !?*std.Build.Dependency {
    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => null,
    };

    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .powerpcle, .powerpc64le => "ppcle",
        .aarch64, .aarch64_be => "aarch_64",
        .s390x => "s390",
        .x86_64 => "x86_64",
        .x86 => "x86_32",
        else => null,
    };

    const dependencyName = if (builtin.os.tag == .windows)
        try std.mem.concat(b.allocator, u8, &.{"protoc-win64"})
    else if (os != null and arch != null)
        try std.mem.concat(b.allocator, u8, &.{ "protoc-", os.?, "-", arch.? })
    else
        @panic("Platform not supported");
    defer b.allocator.free(dependencyName);

    if (b.lazyDependency(dependencyName, .{})) |dep| {
        return dep;
    }

    return null;
}

pub fn getProtocBin(protoc_owner: *std.Build, step: *std.Build.Step) !?[]const u8 {
    if (try getProtocDependency(protoc_owner)) |dep| {
        if (builtin.os.tag == .windows)
            return dep.path("bin/protoc.exe").getPath2(protoc_owner, step);

        return dep.path("bin/protoc").getPath2(protoc_owner, step);
    }
    return null;
}

fn dupeLazyPaths(b: *std.Build, paths: []const std.Build.LazyPath) []std.Build.LazyPath {
    const array = b.allocator.alloc(std.Build.LazyPath, paths.len) catch @panic("OOM");
    for (array, paths) |*dest, source|
        dest.* = source.dupe(b);
    return array;
}

pub const RunProtocStep = struct {
    step: *std.Build.Step,

    pub const Options = struct {
        source_files: []const std.Build.LazyPath,
        include_directories: []const std.Build.LazyPath = &.{},
        destination_directory: std.Build.LazyPath,
        /// Optional pre-built protoc-gen-zig artifact. When provided, the
        /// protoc step can be owned by a consumer builder while the generator
        /// stays owned by the zig-protobuf dependency builder.
        generator: ?*std.Build.Step.Compile = null,
        /// Optional pre-built protoc binary. When provided, overrides the
        /// built-in protoc download mechanism.
        protoc: ?std.Build.LazyPath = null,
        /// When true, every generated message preserves unknown fields during
        /// binary decode/encode round trips. Defaults to false.
        preserve_unknown_fields: bool = false,
    };

    pub fn create(
        owner: *std.Build,
        target: std.Build.ResolvedTarget,
        options: Options,
    ) *RunProtocStep {
        const generator = options.generator orelse buildGenerator(owner, .{ .target = target });
        const mkdir = owner.addSystemCommand(&.{ "mkdir", "-p" });
        mkdir.addDirectoryArg(options.destination_directory);
        const protoc_bin = options.protoc orelse blk: {
            const dependency = (getProtocDependency(owner) catch @panic("OOM")) orelse
                @panic("protoc is not available for this platform");
            break :blk dependency.path(if (builtin.os.tag == .windows) "bin/protoc.exe" else "bin/protoc");
        };
        const protoc = owner.addRunFile(protoc_bin);
        protoc.step.dependOn(&mkdir.step);
        protoc.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", generator);
        protoc.addPrefixedDirectoryArg(
            if (options.preserve_unknown_fields) "--zig_out=preserve_unknown_fields=true:" else "--zig_out=",
            options.destination_directory,
        );
        for (options.include_directories) |include_directory| {
            protoc.addPrefixedDirectoryArg("-I", include_directory);
        }
        for (options.source_files) |source_file| protoc.addFileArg(source_file);

        const format = owner.addSystemCommand(&.{ owner.graph.zig_exe, "fmt" });
        format.addDirectoryArg(options.destination_directory);
        format.step.dependOn(&protoc.step);

        const self = owner.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{ .step = &format.step };
        return self;
    }

    pub fn createWithGenerator(
        owner: *std.Build,
        generator: *std.Build.Step.Compile,
        options: Options,
    ) *RunProtocStep {
        return create(owner, generator.root_module.resolved_target.?, .{
            .source_files = options.source_files,
            .include_directories = options.include_directories,
            .destination_directory = options.destination_directory,
            .generator = generator,
            .protoc = options.protoc,
            .preserve_unknown_fields = options.preserve_unknown_fields,
        });
    }

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }
};

pub const GenOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub fn buildGenerator(b: *std.Build, opt: GenOptions) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bootstrapped-generator/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);

    return exe;
}
