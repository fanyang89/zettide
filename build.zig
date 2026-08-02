const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zettide_cawfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "zettide-cawfs",
        .root_module = module,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{
        .root_module = module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zettide_cawfs", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tests" },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);

    const ci_step = b.step("ci", "Run local CI checks");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(test_step);
}
