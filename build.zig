const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.15.2")) {
        @compileError("hsm.zig requires Zig 0.15.2");
    }
}

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

    // Keep the second complete example on the package build surface too.
    const basic_example = b.addExecutable(.{
        .name = "hsm_basic_example",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_example.root_module.addImport("hsm", hsm_lib.root_module);
    b.installArtifact(basic_example);

    // Compile the initial-transition compatibility smoke executable with the
    // same source module used by direct consumers.
    const initial_api = b.addExecutable(.{
        .name = "initial_api",
        .root_module = b.addModule("initial_api", .{
            .root_source_file = b.path("debug_initial.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(initial_api);

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

    // Create traffic light benchmark
    const traffic_light_bench = b.addExecutable(.{
        .name = "traffic_light_bench",
        .root_module = b.addModule("root", .{
            .root_source_file = b.path("bench/traffic_light_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    traffic_light_bench.root_module.addImport("hsm", hsm_lib.root_module);

    const traffic_light_bench_install = b.addInstallArtifact(traffic_light_bench, .{});
    const traffic_light_bench_step = b.step("traffic_light_bench", "Build the traffic light benchmark");
    traffic_light_bench_step.dependOn(&traffic_light_bench_install.step);
    b.installArtifact(traffic_light_bench);

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

    const run_basic_example = b.addRunArtifact(basic_example);
    const basic_example_step = b.step("basic_example", "Run the complete basic example");
    basic_example_step.dependOn(&run_basic_example.step);

    const run_initial_api = b.addRunArtifact(initial_api);
    const initial_api_step = b.step("initial_api", "Run the initial-transition compatibility smoke test");
    initial_api_step.dependOn(&run_initial_api.step);

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

    const hsm_simple_tests = b.addTest(.{
        .root_module = b.addModule("hsm_simple", .{
            .root_source_file = b.path("src/hsm_simple.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_hsm_simple_tests = b.addRunArtifact(hsm_simple_tests);
    test_step.dependOn(&run_hsm_simple_tests.step);

    // Every external test file is a standalone test executable. Keep this
    // list explicit so adding or removing a file changes the package surface
    // visibly in the build manifest.
    const external_tests = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "activities", .path = "tests/activities_test.zig" },
        .{ .name = "basic", .path = "tests/basic_test.zig" },
        .{ .name = "choice_states", .path = "tests/choice_states_test.zig" },
        .{ .name = "choice", .path = "tests/choice_test.zig" },
        .{ .name = "context_cancellation", .path = "tests/context_cancellation_test.zig" },
        .{ .name = "effects", .path = "tests/effects_test.zig" },
        .{ .name = "entry_functions", .path = "tests/entry_functions_test.zig" },
        .{ .name = "event_data", .path = "tests/event_data_test.zig" },
        .{ .name = "exit_functions", .path = "tests/exit_functions_test.zig" },
        .{ .name = "final_states", .path = "tests/final_states_test.zig" },
        .{ .name = "guard_conditions", .path = "tests/guard_conditions_test.zig" },
        .{ .name = "hierarchical_states", .path = "tests/hierarchical_states_test.zig" },
        .{ .name = "hierarchical", .path = "tests/hierarchical_test.zig" },
        .{ .name = "history", .path = "tests/history_test.zig" },
        .{ .name = "initial_transitions", .path = "tests/initial_transitions_test.zig" },
        .{ .name = "path_resolution", .path = "tests/path_resolution_test.zig" },
        .{ .name = "timer_transitions", .path = "tests/timer_transitions_test.zig" },
        .{ .name = "transition_types", .path = "tests/transition_types_test.zig" },
        .{ .name = "validation", .path = "tests/validation_test.zig" },
        .{ .name = "api_parity", .path = "tests/api_parity_test.zig" },
    };

    for (external_tests) |external_test| {
        const test_artifact = b.addTest(.{
            .root_module = b.addModule(external_test.name, .{
                .root_source_file = b.path(external_test.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_artifact.root_module.addImport("hsm", hsm_lib.root_module);
        const run_test = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_test.step);
    }

    const conformance_basic = b.addExecutable(.{
        .name = "conformance_basic",
        .root_module = b.addModule("conformance_basic", .{
            .root_source_file = b.path("conformance/run_case.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conformance_basic.root_module.addImport("hsm", hsm_lib.root_module);
    const run_conformance_basic = b.addRunArtifact(conformance_basic);
    run_conformance_basic.addFileArg(b.path("../conformance/cases/basic_transition.json"));
    const conformance_basic_step = b.step("conformance_basic", "Run the basic conformance case");
    conformance_basic_step.dependOn(&run_conformance_basic.step);
}
