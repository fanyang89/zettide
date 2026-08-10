const std = @import("std");
const raft_build = @import("raftz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const generate_proto = raft_build.createProtocStep(raft_dependency, target, optimize, .{
        .destination_directory = b.path(".zig-cache/generated"),
        .source_files = &.{b.path("proto/zettide/control/v1/control.proto")},
        .include_directories = &.{b.path("proto")},
    });
    const generate_proto_step = b.step("gen-proto", "Generate Zig protobuf sources");
    generate_proto_step.dependOn(generate_proto.step);

    const control_proto = b.createModule(.{
        .root_source_file = b.path(".zig-cache/generated/zettide/control/v1.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf_module }},
    });

    const control = b.addModule("zettide_control", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap_dependency.module("clap") },
            .{ .name = "control_proto", .module = control_proto },
            .{ .name = "grpc_lite", .module = grpc_module },
            .{ .name = "raftz", .module = raft_dependency.module("raftz") },
            .{ .name = "uuid", .module = uuid_dependency.module("uuid") },
        },
    });

    const library = b.addLibrary(.{
        .name = "zettide-control",
        .root_module = control,
    });
    library.step.dependOn(generate_proto.step);
    b.installArtifact(library);

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zettide_control", .module = control }},
    });
    const executable = b.addExecutable(.{
        .name = "zettide-control",
        .root_module = executable_module,
    });
    executable.step.dependOn(generate_proto.step);
    b.installArtifact(executable);

    const run_executable = b.addRunArtifact(executable);
    run_executable.addPassthruArgs();
    const run_step = b.step("run", "Run the metadata control plane");
    run_step.dependOn(&run_executable.step);

    const tests = b.addTest(.{ .root_module = control });
    tests.step.dependOn(generate_proto.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
