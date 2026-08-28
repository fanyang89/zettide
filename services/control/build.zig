const std = @import("std");
const raft_build = @import("raftz");

pub const StepNames = struct {
    generate: []const u8 = "gen-proto",
    run: []const u8 = "run",
    tests: []const u8 = "test",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = addComponent(b, target, optimize, "", .{});

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);

    const ci_step = b.step("ci", "Run local CI checks");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(test_step);
}

pub fn addComponent(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base_dir: []const u8,
    step_names: StepNames,
) *std.Build.Step {
    const raft_dependency = b.dependency("raftz", .{
        .target = target,
        .optimize = optimize,
    });
    const grpc_dependency = raft_build.grpcLiteDependency(raft_dependency, target, optimize);
    const grpc_module = grpc_dependency.module("grpc_lite");
    const protobuf_module = grpc_module.import_table.get("protobuf").?;
    const clap_dependency = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const uuid_dependency = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });
    const node_protocol_dependency = b.dependency("zettide_node_protocol", .{
        .target = target,
        .optimize = optimize,
    });

    const generated_control_dir = createGeneratedDirectory(b, ".zettide-control-proto");
    const generate_proto = raft_build.createProtocStep(raft_dependency, target, optimize, .{
        .destination_directory = generated_control_dir,
        .source_files = &.{componentPath(b, base_dir, "proto/zettide/control/v1/control.proto")},
        .include_directories = &.{componentPath(b, base_dir, "proto")},
    });
    generated_control_dir.addStepDependencies(&generate_proto.step);

    const generated_node_dir = createGeneratedDirectory(b, ".zettide-node-proto");
    const generate_node_proto = raft_build.createProtocStep(raft_dependency, target, optimize, .{
        .destination_directory = generated_node_dir,
        .source_files = &.{node_protocol_dependency.path("proto/zettide/control/v1/data_service.proto")},
        .include_directories = &.{node_protocol_dependency.path("proto")},
    });
    generated_node_dir.addStepDependencies(&generate_node_proto.step);

    const control_proto_output = ProtoOutput.create(
        b,
        &generate_proto.step,
        generated_control_dir,
        "zettide/control/v1.pb.zig",
    );
    const node_proto_output = ProtoOutput.create(
        b,
        &generate_node_proto.step,
        generated_node_dir,
        "zettide/control/v1.pb.zig",
    );

    const generate_proto_step = b.step(step_names.generate, "Generate control-plane Zig protobuf sources");
    generate_proto_step.dependOn(&control_proto_output.step);
    generate_proto_step.dependOn(&node_proto_output.step);

    const control_proto = b.createModule(.{
        .root_source_file = control_proto_output.getOutput(),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf_module }},
    });
    const node_proto = b.createModule(.{
        .root_source_file = node_proto_output.getOutput(),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf_module }},
    });

    const control = b.addModule("zettide_control", .{
        .root_source_file = componentPath(b, base_dir, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap_dependency.module("clap") },
            .{ .name = "control_proto", .module = control_proto },
            .{ .name = "grpc_lite", .module = grpc_module },
            .{ .name = "node_proto", .module = node_proto },
            .{ .name = "raftz", .module = raft_dependency.module("raftz") },
            .{ .name = "uuid", .module = uuid_dependency.module("uuid") },
            .{ .name = "zettide_node_protocol", .module = node_protocol_dependency.module("zettide_node_protocol") },
        },
    });

    const library = b.addLibrary(.{
        .name = "zettide-control",
        .root_module = control,
    });
    b.installArtifact(library);

    const executable_module = b.createModule(.{
        .root_source_file = componentPath(b, base_dir, "src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zettide_control", .module = control }},
    });
    const executable = b.addExecutable(.{
        .name = "zettide-control",
        .root_module = executable_module,
    });
    b.installArtifact(executable);

    const run_executable = b.addRunArtifact(executable);
    if (b.args) |args| run_executable.addArgs(args);
    const run_step = b.step(step_names.run, "Run the metadata control plane");
    run_step.dependOn(&run_executable.step);

    const tests = b.addTest(.{ .root_module = control });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step(step_names.tests, "Run control-plane unit tests");
    test_step.dependOn(&run_tests.step);
    return test_step;
}

fn componentPath(b: *std.Build, base_dir: []const u8, sub_path: []const u8) std.Build.LazyPath {
    if (base_dir.len == 0) return b.path(sub_path);
    return b.path(b.pathJoin(&.{ base_dir, sub_path }));
}

fn createGeneratedDirectory(b: *std.Build, marker_name: []const u8) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.add(marker_name, "");
    return files.getDirectory();
}

const ProtoOutput = struct {
    step: std.Build.Step,
    generated_file: std.Build.GeneratedFile,
    directory: std.Build.LazyPath,
    relative_path: []const u8,

    fn create(
        b: *std.Build,
        producer: *std.Build.Step,
        directory: std.Build.LazyPath,
        relative_path: []const u8,
    ) *ProtoOutput {
        const output = b.allocator.create(ProtoOutput) catch @panic("OOM");
        output.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("expose generated protobuf {s}", .{relative_path}),
                .owner = b,
                .makeFn = make,
            }),
            .generated_file = undefined,
            .directory = directory.dupe(b),
            .relative_path = b.dupe(relative_path),
        };
        output.generated_file = .{ .step = &output.step };
        output.step.dependOn(producer);
        directory.addStepDependencies(&output.step);
        return output;
    }

    fn getOutput(output: *const ProtoOutput) std.Build.LazyPath {
        return .{ .generated = .{ .file = &output.generated_file } };
    }

    fn make(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
        _ = make_options;
        const output: *ProtoOutput = @fieldParentPtr("step", step);
        const directory = output.directory.getPath2(step.owner, step);
        output.generated_file.path = step.owner.pathJoin(&.{ directory, output.relative_path });
    }
};
