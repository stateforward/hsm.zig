const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create HSM library (using new flat storage implementation)
    const hsm_lib = b.addLibrary(.{
        .name = "hsm",
        .root_module = b.addModule("hsm", .{
            .root_source_file = b.path("src/hsm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(hsm_lib);

    // Create example executable
    const example = b.addExecutable(.{
        .name = "hsm_example",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/simple.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(example);

    // Create flat storage example executable
    const flat_example = b.addExecutable(.{
        .name = "flat_example",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/flat_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    flat_example.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(flat_example);

    // Create polyglot API example executable
    const polyglot_example = b.addExecutable(.{
        .name = "polyglot_example",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/polyglot_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    polyglot_example.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(polyglot_example);

    // Create real HSM benchmark
    const real_hsm_bench = b.addExecutable(.{
        .name = "light_bench_real",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("src/light_bench_real.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(real_hsm_bench);

    // Create basic API demo executable
    const basic_demo = b.addExecutable(.{
        .name = "basic_demo",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/basic_api_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_demo.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(basic_demo);

    // Create feature demo executable
    const feature_demo = b.addExecutable(.{
        .name = "feature_demo",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/feature_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    feature_demo.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(feature_demo);

    // Run examples
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the basic example");
    example_step.dependOn(&run_example.step);

    const run_flat_example = b.addRunArtifact(flat_example);
    const flat_example_step = b.step("flat", "Run the flat storage example");
    flat_example_step.dependOn(&run_flat_example.step);

    const run_polyglot_example = b.addRunArtifact(polyglot_example);
    const polyglot_example_step = b.step("polyglot", "Run the polyglot API example");
    polyglot_example_step.dependOn(&run_polyglot_example.step);

    const run_basic_demo = b.addRunArtifact(basic_demo);
    const basic_demo_step = b.step("basic", "Run the basic API demo");
    basic_demo_step.dependOn(&run_basic_demo.step);

    const run_feature_demo = b.addRunArtifact(feature_demo);
    const feature_demo_step = b.step("features", "Run the feature demonstration");
    feature_demo_step.dependOn(&run_feature_demo.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const hsm_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("src/hsm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_hsm_tests = b.addRunArtifact(hsm_tests);
    test_step.dependOn(&run_hsm_tests.step);

    // Add individual test files
    const basic_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/basic_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const choice_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/choice_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    choice_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const hierarchical_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/hierarchical_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hierarchical_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const initial_transitions_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/initial_transitions_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    initial_transitions_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const guard_conditions_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/guard_conditions_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    guard_conditions_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const effects_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/effects_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    effects_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const timer_transitions_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/timer_transitions_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    timer_transitions_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const history_tests = b.addTest(.{
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("tests/history_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    history_tests.root_module.addImport("hsm", hsm_lib.root_module);

    const run_basic_tests = b.addRunArtifact(basic_tests);
    const run_choice_tests = b.addRunArtifact(choice_tests);
    const run_hierarchical_tests = b.addRunArtifact(hierarchical_tests);
    const run_initial_transitions_tests = b.addRunArtifact(initial_transitions_tests);
    const run_guard_conditions_tests = b.addRunArtifact(guard_conditions_tests);
    const run_effects_tests = b.addRunArtifact(effects_tests);
    const run_timer_transitions_tests = b.addRunArtifact(timer_transitions_tests);
    const run_history_tests = b.addRunArtifact(history_tests);

    test_step.dependOn(&run_basic_tests.step);
    test_step.dependOn(&run_choice_tests.step);
    test_step.dependOn(&run_hierarchical_tests.step);
    test_step.dependOn(&run_initial_transitions_tests.step);
    test_step.dependOn(&run_guard_conditions_tests.step);
    test_step.dependOn(&run_effects_tests.step);
    test_step.dependOn(&run_timer_transitions_tests.step);
    test_step.dependOn(&run_history_tests.step);
}
