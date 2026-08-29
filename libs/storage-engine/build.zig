const std = @import("std");

pub const Modules = struct {
    storage: *std.Build.Module,
    crc32c: *std.Build.Module,
};

pub const Component = struct {
    modules: Modules,
    tests: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const component = addComponent(
        b,
        target,
        optimize,
        "",
        "../../vendor/utf8proc",
        "test",
    );

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check storage-engine formatting");
    fmt_step.dependOn(&fmt.step);

    const ci_step = b.step("ci", "Run storage-engine CI checks");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(component.tests);
}

pub fn addComponent(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base_dir: []const u8,
    utf8proc_dir: []const u8,
    test_step_name: []const u8,
) Component {
    const crc32c_dependency = b.dependency("crc32c", .{});
    const crc32c = createCrc32cModule(b, target, optimize, crc32c_dependency, base_dir);
    const storage = b.addModule("zettide_storage", .{
        .root_source_file = componentPath(b, base_dir, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addStorageDependencies(b, storage, target, optimize, crc32c, utf8proc_dir);

    const library = b.addLibrary(.{
        .name = "zettide-storage-engine",
        .root_module = storage,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{ .root_module = storage });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step(test_step_name, "Run portable storage-engine tests");
    test_step.dependOn(&run_unit_tests.step);

    return .{
        .modules = .{ .storage = storage, .crc32c = crc32c },
        .tests = test_step,
    };
}

pub fn createPrivateModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base_dir: []const u8,
    utf8proc_dir: []const u8,
) Modules {
    const crc32c_dependency = b.dependency("crc32c", .{});
    const crc32c = createCrc32cModule(b, target, optimize, crc32c_dependency, base_dir);
    const storage = b.createModule(.{
        .root_source_file = componentPath(b, base_dir, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addStorageDependencies(b, storage, target, optimize, crc32c, utf8proc_dir);
    return .{ .storage = storage, .crc32c = crc32c };
}

fn addStorageDependencies(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    crc32c: *std.Build.Module,
    utf8proc_dir: []const u8,
) void {
    const utf8proc_root = b.path(utf8proc_dir);
    module.addIncludePath(utf8proc_root);
    module.addCMacro("UTF8PROC_STATIC", "1");
    module.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ utf8proc_dir, "utf8proc.c" })),
        .flags = &.{ "-std=c99", "-DUTF8PROC_STATIC" },
    });
    const utf8proc_header = b.addWriteFiles().add("utf8proc_c.h",
        \\#include <stdlib.h>
        \\#include <utf8proc.h>
    );
    const utf8proc_translate = b.addTranslateC(.{
        .root_source_file = utf8proc_header,
        .target = target,
        .optimize = optimize,
    });
    utf8proc_translate.addIncludePath(utf8proc_root);
    utf8proc_translate.defineCMacro("UTF8PROC_STATIC", "1");
    module.addImport("utf8proc_c", utf8proc_translate.createModule());
    module.addImport("crc32c", crc32c);
}

fn createCrc32cModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: *std.Build.Dependency,
    base_dir: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = componentPath(b, base_dir, "src/crc32c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const config = addCrc32c(module, dependency, target);
    const translate = b.addTranslateC(.{
        .root_source_file = dependency.path("include/crc32c/crc32c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addConfigHeader(config);
    translate.addIncludePath(dependency.path("include"));
    translate.addIncludePath(dependency.path("src"));
    module.addImport("crc32c_c", translate.createModule());
    module.link_libcpp = true;
    return module;
}

fn addCrc32c(
    module: *std.Build.Module,
    dependency: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.ConfigHeader {
    const b = module.owner;
    const arch = target.result.cpu.arch;
    const is_x86 = arch == .x86 or arch == .x86_64;
    const is_aarch64 = arch == .aarch64 or arch == .aarch64_be;
    const config_header = b.addConfigHeader(.{
        .style = .{ .cmake = dependency.path("src/crc32c_config.h.in") },
        .include_path = "crc32c/crc32c_config.h",
    }, .{
        .BYTE_ORDER_BIG_ENDIAN = arch.endian() == .big,
        .HAVE_BUILTIN_PREFETCH = true,
        .HAVE_MM_PREFETCH = is_x86,
        .HAVE_SSE42 = is_x86,
        .HAVE_ARM64_CRC32C = is_aarch64,
        .HAVE_STRONG_GETAUXVAL = is_aarch64 and target.result.os.tag == .linux,
        .HAVE_WEAK_GETAUXVAL = false,
        .CRC32C_TESTS_BUILT_WITH_GLOG = false,
    });
    module.addConfigHeader(config_header);
    module.addIncludePath(dependency.path("include"));
    module.addIncludePath(dependency.path("src"));
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &.{ "src/crc32c.cc", "src/crc32c_portable.cc" },
        .flags = &.{ "-fno-exceptions", "-fno-rtti" },
    });
    if (is_x86) {
        module.addCSourceFile(.{
            .file = dependency.path("src/crc32c_sse42.cc"),
            .flags = &.{
                "-fno-exceptions", "-fno-rtti",
                "-Xclang",         "-target-feature",
                "-Xclang",         "+sse4.2",
                "-Xclang",         "-target-feature",
                "-Xclang",         "+crc32",
            },
        });
    }
    if (is_aarch64) {
        module.addCSourceFile(.{
            .file = dependency.path("src/crc32c_arm64.cc"),
            .flags = &.{
                "-fno-exceptions", "-fno-rtti",
                "-Xclang",         "-target-feature",
                "-Xclang",         "+crc",
                "-Xclang",         "-target-feature",
                "-Xclang",         "+aes",
            },
        });
    }
    return config_header;
}

fn componentPath(b: *std.Build, base_dir: []const u8, sub_path: []const u8) std.Build.LazyPath {
    if (base_dir.len == 0) return b.path(sub_path);
    return b.path(b.pathJoin(&.{ base_dir, sub_path }));
}
