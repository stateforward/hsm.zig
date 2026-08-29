const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for validation testing
const ValidationTestInstance = struct {
    base: hsm.Instance,
    validation_errors: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .validation_errors = .{},
            .warnings = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.validation_errors.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordError(self: *Self, error_msg: []const u8) void {
        self.validation_errors.append(self.allocator, error_msg) catch unreachable;
    }

    pub fn recordWarning(self: *Self, warning_msg: []const u8) void {
        self.warnings.append(self.allocator, warning_msg) catch unreachable;
    }
};

// Dummy functions for testing
fn dummyEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

fn dummyExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

fn dummyEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

fn dummyGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = inst;
    _ = event;
    return true;
}

fn dummyActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

fn dummyTimer(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return std.time.ns_per_ms * 100;
}

test "Valid state machine passes validation" {
    const model = comptime hsm.define("ValidStateMachine", .{ hsm.initial(hsm.target("start")), hsm.state("start", .{ hsm.entry(dummyEntry), hsm.exit(dummyExit), hsm.activity(dummyActivity), hsm.transition(.{ hsm.on("go"), hsm.effect(dummyEffect), hsm.target("middle") }), hsm.transition(.{ hsm.after(dummyTimer), hsm.target("timeout") }) }), hsm.state("middle", .{ hsm.transition(.{ hsm.on("continue"), hsm.guard(dummyGuard), hsm.target("end") }), hsm.transition(.{ hsm.on("back"), hsm.target("../start") }) }), hsm.state("timeout", .{hsm.transition(.{ hsm.on("retry"), hsm.target("../start") })}), hsm.final("end") });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();

    // Should validate without errors
    try hsm.validate(&built_model);

    // Can start successfully
    var context = hsm.Context.init(testing.allocator);
    var instance = ValidationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
}

test "Choice state without guardless fallback fails validation" {
    const invalid_model = comptime hsm.define("InvalidChoiceStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{hsm.transition(.{ hsm.on("choose"), hsm.target("decision") })}),
        hsm.choice("decision", .{
            hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../option_a") }),
            hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../option_b") }),
            // Missing guardless fallback transition!
        }),
        hsm.state("option_a", .{}),
        hsm.state("option_b", .{}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.ChoiceWithoutGuardlessFallback, validation_result);
}

test "Final state with transitions fails validation" {
    const invalid_model = comptime hsm.define("InvalidFinalStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{hsm.transition(.{ hsm.on("finish"), hsm.target("end") })}),
        hsm.state("end", .{
            // Final states cannot have transitions!
            hsm.transition(.{ hsm.on("restart"), hsm.target("../start") })}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();
    hsm.getState(&built_model, "/InvalidFinalStateMachine/end").?.element.kind = .final;

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.InvalidTransitionSource, validation_result);
}

test "Final state with entry/exit actions fails validation" {
    const invalid_model = comptime hsm.define("InvalidFinalWithActionsStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{hsm.transition(.{ hsm.on("finish"), hsm.target("end") })}),
        hsm.state("end", .{
            // Final states cannot have entry/exit actions!
            hsm.entry(dummyEntry),
            hsm.exit(dummyExit),
        }),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();
    hsm.getState(&built_model, "/InvalidFinalWithActionsStateMachine/end").?.element.kind = .final;

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.FinalStateWithEntry, validation_result);
}

test "Final state with activities fails validation" {
    const invalid_model = comptime hsm.define("InvalidFinalWithActivityStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{hsm.transition(.{ hsm.on("finish"), hsm.target("end") })}),
        hsm.state("end", .{
            // Final states cannot have activities!
            hsm.activity(dummyActivity)}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();
    hsm.getState(&built_model, "/InvalidFinalWithActivityStateMachine/end").?.element.kind = .final;

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.FinalStateWithActivities, validation_result);
}

test "Missing initial state fails validation" {
    const invalid_model = comptime hsm.define("NoInitialStateMachine", .{
        // Missing initial transition!
        hsm.state("start", .{hsm.transition(.{ hsm.on("go"), hsm.target("end") })}),
        hsm.state("end", .{}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.MissingInitialTransition, validation_result);
}

test "Invalid transition target path fails validation" {
    const invalid_model = comptime hsm.define("InvalidTargetStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("go"), hsm.target("nonexistent_state") }), // Invalid target!
        }),
        hsm.state("existing_state", .{}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.InvalidTransitionTarget, validation_result);
}

test "Nested initial transitions pass validation under strict locality" {
    const valid_model = comptime hsm.define("NestedInitialStateMachine", .{
        hsm.initial(hsm.target("container_a")),
        hsm.state("container_a", .{
            hsm.initial(hsm.target("child_a")),
            hsm.state("child_a", .{}),
        }),
        hsm.state("container_b", .{
            hsm.initial(hsm.target("child_b")),
            hsm.state("child_b", .{}),
        }),
    });

    var built_model = try valid_model.build(testing.allocator);
    defer built_model.deinit();

    // Strict-descendant initial targets cannot form a well-formed cycle.
    try hsm.validate(&built_model);
}

test "Complex valid hierarchical state machine passes validation" {
    const complex_model = comptime hsm.define("ComplexValidStateMachine", .{
        hsm.initial(hsm.target("application")),
        hsm.state("application", .{
            hsm.entry(dummyEntry),
            hsm.exit(dummyExit),
            hsm.initial(hsm.target("main_view")),
            hsm.state("main_view", .{
                hsm.entry(dummyEntry),
                hsm.initial(hsm.target("editor")),
                hsm.state("editor", .{
                    hsm.entry(dummyEntry),
                    hsm.exit(dummyExit),
                    hsm.activity(dummyActivity),
                    hsm.transition(.{ hsm.on("save"), hsm.effect(dummyEffect) }), // Internal
                    hsm.transition(.{ hsm.on("switch_mode"), hsm.target("../viewer") }),
                }),
                hsm.state("viewer", .{ hsm.entry(dummyEntry), hsm.transition(.{ hsm.on("edit"), hsm.target("../editor") }) }),
            }),
            hsm.state("settings", .{ hsm.entry(dummyEntry), hsm.initial(hsm.target("general")), hsm.state("general", .{hsm.transition(.{ hsm.on("advanced"), hsm.target("../advanced") })}), hsm.state("advanced", .{hsm.transition(.{ hsm.on("back"), hsm.target("../general") })}) }),
            hsm.choice("mode_selection", .{
                hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../main_view") }),
                hsm.transition(.{hsm.target("../settings")}), // Guardless fallback
            }),
            hsm.transition(.{ hsm.on("configure"), hsm.target("mode_selection") }),
            hsm.transition(.{ hsm.on("quit"), hsm.target("../shutdown") }),
        }),
        hsm.state("shutdown", .{ hsm.entry(dummyEntry), hsm.transition(.{ hsm.after(dummyTimer), hsm.target("../terminated") }) }),
        hsm.final("terminated"),
    });

    var built_model = try complex_model.build(testing.allocator);
    defer built_model.deinit();

    // Should validate successfully
    try hsm.validate(&built_model);

    // Should start successfully
    var context = hsm.Context.init(testing.allocator);
    var instance = ValidationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in the correct nested state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "editor"));
}

test "Invalid nested structure fails validation" {
    const invalid_model = comptime hsm.define("InvalidNestedStateMachine", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("child")),
            hsm.state("child", .{
                // Child has initial but no child states!
                hsm.initial(hsm.target("nonexistent"))}),
        }),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.InvalidTransitionTarget, validation_result);
}

test "Multiple choice states with proper fallbacks pass validation" {
    const multiple_choice_model = comptime hsm.define("MultipleChoiceStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{ hsm.transition(.{ hsm.on("first_choice"), hsm.target("choice_a") }), hsm.transition(.{ hsm.on("second_choice"), hsm.target("choice_b") }) }),
        hsm.choice("choice_a", .{
            hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../option_1") }),
            hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../option_2") }),
            hsm.transition(.{hsm.target("../fallback_a")}), // Guardless fallback
        }),
        hsm.choice("choice_b", .{
            hsm.transition(.{ hsm.guard(dummyGuard), hsm.target("../option_3") }),
            hsm.transition(.{hsm.target("../fallback_b")}), // Guardless fallback
        }),
        hsm.state("option_1", .{}),
        hsm.state("option_2", .{}),
        hsm.state("option_3", .{}),
        hsm.state("fallback_a", .{}),
        hsm.state("fallback_b", .{}),
    });

    var built_model = try multiple_choice_model.build(testing.allocator);
    defer built_model.deinit();

    // Should validate successfully
    try hsm.validate(&built_model);
}

test "Self-referential paths are validated correctly" {
    const self_ref_model = comptime hsm.define("SelfReferenceStateMachine", .{
        hsm.initial(hsm.target("stateful")),
        hsm.state("stateful", .{
            hsm.transition(.{ hsm.on("reset"), hsm.target(".") }), // Self reference
            hsm.transition(.{ hsm.on("up"), hsm.target("..") }), // Parent reference
            hsm.initial(hsm.target("nested")),
            hsm.state("nested", .{ hsm.transition(.{ hsm.on("self"), hsm.target(".") }), hsm.transition(.{ hsm.on("parent"), hsm.target("..") }), hsm.transition(.{ hsm.on("grandparent"), hsm.target("../..") }) }),
        }),
    });

    var built_model = try self_ref_model.build(testing.allocator);
    defer built_model.deinit();

    // Should validate successfully
    try hsm.validate(&built_model);
}

test "Transition without event or timer fails validation" {
    const invalid_model = comptime hsm.define("InvalidTransitionStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            // Transition without event or timer!
            hsm.transition(.{hsm.target("end")})}),
        hsm.state("end", .{}),
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.TransitionWithoutTrigger, validation_result);
}

test "Event and guard-only transitions fail validation" {
    const event_only_model = comptime hsm.define("MissingTransitionOutcomeStateMachine", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{hsm.transition(.{hsm.on("hit")})}),
    });

    var event_only_built = try event_only_model.buildUnchecked(testing.allocator);
    defer event_only_built.deinit();

    try testing.expectError(
        hsm.ValidationError.TransitionWithoutTargetOrEffect,
        hsm.validate(&event_only_built),
    );

    const guard_only_model = comptime hsm.define("GuardOnlyTransitionStateMachine", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{hsm.transition(.{ hsm.on("hit"), hsm.guard(dummyGuard) })}),
    });

    var guard_only_built = try guard_only_model.buildUnchecked(testing.allocator);
    defer guard_only_built.deinit();

    try testing.expectError(
        hsm.ValidationError.TransitionWithoutTargetOrEffect,
        hsm.validate(&guard_only_built),
    );
}

test "Effect-only internal transition passes validation" {
    const valid_model = comptime hsm.define("EffectOnlyTransitionStateMachine", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{hsm.transition(.{ hsm.on("hit"), hsm.effect(dummyEffect) })}),
    });

    var built_model = try valid_model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = ValidationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "hit"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "idle"));
}

test "Duplicate state names in same scope fail validation" {
    const invalid_model = comptime hsm.define("DuplicateNamesStateMachine", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{hsm.transition(.{ hsm.on("go"), hsm.target("duplicate") })}),
        hsm.state("duplicate", .{}),
        hsm.state("duplicate", .{}), // Duplicate name!
    });

    var built_model = try invalid_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.DuplicateMemberName, validation_result);
}

test "Empty state machine fails validation" {
    const empty_model = comptime hsm.define("EmptyStateMachine", .{
        // No states at all!
    });

    var built_model = try empty_model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    // Should fail validation
    const validation_result = hsm.validate(&built_model);
    try testing.expectError(hsm.ValidationError.EmptyModel, validation_result);
}
