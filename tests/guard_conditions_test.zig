const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for guard condition testing
const GuardTestInstance = struct {
    base: hsm.Instance,
    counter: i32,
    flag: bool,
    status: []const u8,
    guard_calls: std.ArrayList([]const u8),
    guard_results: std.ArrayList(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .base = hsm.Instance.init(),
            .counter = 0,
            .flag = false,
            .status = "initial",
            .guard_calls = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .guard_results = try std.ArrayList(bool).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.guard_calls.deinit(self.allocator);
        self.guard_results.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordGuardCall(self: *Self, name: []const u8, result: bool) void {
        self.guard_calls.append(self.allocator, name) catch unreachable;
        self.guard_results.append(self.allocator, result) catch unreachable;
    }
};

// Basic guard functions
fn counterGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    const result = test_inst.counter >= 5;
    test_inst.recordGuardCall("counter", result);
    return result;
}

fn flagGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    const result = test_inst.flag;
    test_inst.recordGuardCall("flag", result);
    return result;
}

fn statusGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    const result = std.mem.eql(u8, test_inst.status, "ready");
    test_inst.recordGuardCall("status", result);
    return result;
}

fn eventDataGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));

    if (event.getData("threshold")) |data| {
        const threshold_ptr: *i32 = @ptrCast(@alignCast(data));
        const result = test_inst.counter >= threshold_ptr.*;
        test_inst.recordGuardCall("event_data", result);
        return result;
    }

    test_inst.recordGuardCall("event_data", false);
    return false;
}

fn contextCancelGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    const result = !ctx.is_done();
    test_inst.recordGuardCall("context", result);
    return result;
}

fn alwaysTrueGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardCall("always_true", true);
    return true;
}

fn alwaysFalseGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardCall("always_false", false);
    return false;
}

// Effect functions for state tracking
fn incrementCounter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    test_inst.counter += 1;
}

fn setFlag(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    test_inst.flag = true;
}

fn setStatus(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *GuardTestInstance = @ptrCast(@alignCast(inst));
    test_inst.status = "ready";
}

test "Basic guard evaluation true and false" {
    const model = comptime hsm.define("BasicGuardTest", .{
        hsm.initial(hsm.target("waiting")),
        hsm.state("waiting", .{
            hsm.transition(.{ hsm.on("test"), hsm.guard(counterGuard), hsm.target("passed") }),
            hsm.transition(.{ hsm.on("test"), hsm.target("failed") }), // Fallback
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementCounter) }),
        }),
        hsm.state("passed", .{}),
        hsm.state("failed", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Initially counter is 0, guard should fail
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "test"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "failed"));
    try testing.expect(instance.guard_calls.items.len == 1);
    try testing.expectEqualStrings("counter", instance.guard_calls.items[0]);
    try testing.expect(instance.guard_results.items[0] == false);

    // Create new state machine for second test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try GuardTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Increment counter enough times to satisfy guard
    for (0..6) |_| {
        try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    }
    try testing.expect(instance2.counter == 6);

    // Now guard should pass
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "test"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "passed"));
    try testing.expect(instance2.guard_calls.items.len == 1);
    try testing.expectEqualStrings("counter", instance2.guard_calls.items[0]);
    try testing.expect(instance2.guard_results.items[0] == true);
}

test "Multiple guards evaluation order" {
    const model = comptime hsm.define("MultipleGuardTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("check"), hsm.guard(alwaysFalseGuard), hsm.target("first") }),
            hsm.transition(.{ hsm.on("check"), hsm.guard(flagGuard), hsm.target("second") }),
            hsm.transition(.{ hsm.on("check"), hsm.guard(counterGuard), hsm.target("third") }),
            hsm.transition(.{ hsm.on("check"), hsm.target("fallback") }), // Guardless fallback
            hsm.transition(.{ hsm.on("setup"), hsm.effect(.{ setFlag, incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter }) }),
        }),
        hsm.state("first", .{}),
        hsm.state("second", .{}),
        hsm.state("third", .{}),
        hsm.state("fallback", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Set up conditions: flag = true, counter = 6
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "setup"));
    try testing.expect(instance.flag == true);
    try testing.expect(instance.counter == 6);

    // Test guard evaluation order - should stop at first successful guard (flagGuard)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "check"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "second"));

    // Should have evaluated guards in order: false, true (stops here)
    try testing.expect(instance.guard_calls.items.len == 2);
    try testing.expectEqualStrings("always_false", instance.guard_calls.items[0]);
    try testing.expect(instance.guard_results.items[0] == false);
    try testing.expectEqualStrings("flag", instance.guard_calls.items[1]);
    try testing.expect(instance.guard_results.items[1] == true);
}

test "Guards with event data" {
    const model = comptime hsm.define("EventDataGuardTest", .{ hsm.initial(hsm.target("waiting")), hsm.state("waiting", .{ hsm.transition(.{ hsm.on("check_threshold"), hsm.guard(eventDataGuard), hsm.target("above_threshold") }), hsm.transition(.{ hsm.on("check_threshold"), hsm.target("below_threshold") }), hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementCounter) }) }), hsm.state("above_threshold", .{}), hsm.state("below_threshold", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Set counter to 3
    for (0..3) |_| {
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    }
    try testing.expect(instance.counter == 3);

    // Test with threshold = 5 (counter < threshold)
    var threshold_value: i32 = 5;
    var event1 = hsm.Event.withData(testing.allocator, "check_threshold");
    defer event1.deinit();
    try event1.putData("threshold", &threshold_value);

    try sm.dispatch(&context, event1);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "below_threshold"));
    try testing.expect(instance.guard_calls.items.len == 1);
    try testing.expectEqualStrings("event_data", instance.guard_calls.items[0]);
    try testing.expect(instance.guard_results.items[0] == false);

    // Create new state machine for second test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try GuardTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Set counter to 7
    for (0..7) |_| {
        try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    }
    try testing.expect(instance2.counter == 7);

    // Test with threshold = 5 (counter >= threshold)
    var threshold_value2: i32 = 5;
    var event2 = hsm.Event.withData(testing.allocator, "check_threshold");
    defer event2.deinit();
    try event2.putData("threshold", &threshold_value2);

    try sm2.dispatch(&context, event2);
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "above_threshold"));
    try testing.expect(instance2.guard_calls.items.len == 1);
    try testing.expectEqualStrings("event_data", instance2.guard_calls.items[0]);
    try testing.expect(instance2.guard_results.items[0] == true);
}

test "Guards in hierarchical states" {
    const model = comptime hsm.define("HierarchicalGuardTest", .{ hsm.initial(hsm.target("parent")), hsm.state("parent", .{ hsm.initial(hsm.target("child")), hsm.transition(.{ hsm.on("escape"), hsm.guard(counterGuard), hsm.target("sibling") }), hsm.state("child", .{ hsm.transition(.{ hsm.on("move"), hsm.guard(flagGuard), hsm.target("../other_child") }), hsm.transition(.{ hsm.on("move"), hsm.target("../blocked") }), hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementCounter) }), hsm.transition(.{ hsm.on("set_flag"), hsm.effect(setFlag) }) }), hsm.state("other_child", .{}), hsm.state("blocked", .{}) }), hsm.state("sibling", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));

    // Try to move without flag set
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "move"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "blocked"));
    try testing.expect(instance.guard_calls.items.len == 1);
    try testing.expectEqualStrings("flag", instance.guard_calls.items[0]);
    try testing.expect(instance.guard_results.items[0] == false);

    // Reset to parent/child for second test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try GuardTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Set flag and try to move
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "set_flag"));
    for (0..6) |_| {
        try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    }
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "move"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "other_child"));
    try testing.expect(instance2.guard_calls.items.len == 1);
    try testing.expectEqualStrings("flag", instance2.guard_calls.items[0]);
    try testing.expect(instance2.guard_results.items[0] == true);

    // Test parent-level guard
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "escape"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "sibling"));
    try testing.expect(instance2.guard_calls.items.len == 2);
    try testing.expectEqualStrings("counter", instance2.guard_calls.items[1]);
    try testing.expect(instance2.guard_results.items[1] == true);
}

test "Guards with context cancellation" {
    const model = comptime hsm.define("ContextGuardTest", .{ hsm.initial(hsm.target("active")), hsm.state("active", .{ hsm.transition(.{ hsm.on("check_context"), hsm.guard(contextCancelGuard), hsm.target("running") }), hsm.transition(.{ hsm.on("check_context"), hsm.target("cancelled") }) }), hsm.state("running", .{}), hsm.state("cancelled", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test with active context
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "check_context"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "running"));
    try testing.expect(instance.guard_calls.items.len == 1);
    try testing.expectEqualStrings("context", instance.guard_calls.items[0]);
    try testing.expect(instance.guard_results.items[0] == true);

    // Create new state machine for cancelled context test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var context2 = hsm.Context.init(testing.allocator);
    context2.cancel(); // Cancel before testing
    var instance2 = try GuardTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context2, &instance2, &built_model2);
    defer sm2.deinit();

    try sm2.dispatch(&context2, hsm.Event.init(testing.allocator, "check_context"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "cancelled"));
    try testing.expect(instance2.guard_calls.items.len == 1);
    try testing.expectEqualStrings("context", instance2.guard_calls.items[0]);
    try testing.expect(instance2.guard_results.items[0] == false);
}

test "Complex guard combinations and precedence" {
    const model = comptime hsm.define("ComplexGuardTest", .{
        hsm.initial(hsm.target("evaluator")),
        hsm.state("evaluator", .{
            // Multiple guarded transitions with different priorities
            hsm.transition(.{ hsm.on("evaluate"), hsm.guard(alwaysFalseGuard), hsm.target("impossible") }),
            hsm.transition(.{ hsm.on("evaluate"), hsm.guard(counterGuard), hsm.guard(flagGuard), hsm.target("both_true") }),
            hsm.transition(.{ hsm.on("evaluate"), hsm.guard(counterGuard), hsm.target("counter_only") }),
            hsm.transition(.{ hsm.on("evaluate"), hsm.guard(flagGuard), hsm.target("flag_only") }),
            hsm.transition(.{ hsm.on("evaluate"), hsm.target("none_true") }),
            // Setup transitions
            hsm.transition(.{ hsm.on("setup_both"), hsm.effect(.{ setFlag, incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter }) }),
            hsm.transition(.{ hsm.on("setup_counter"), hsm.effect(.{ incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter, incrementCounter }) }),
            hsm.transition(.{ hsm.on("setup_flag"), hsm.effect(setFlag) }),
        }),
        hsm.state("impossible", .{}),
        hsm.state("both_true", .{}),
        hsm.state("counter_only", .{}),
        hsm.state("flag_only", .{}),
        hsm.state("none_true", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);

    // Test case 1: Both conditions true - should take first matching transition
    {
        var instance = try GuardTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "setup_both"));
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));

        try testing.expect(std.mem.endsWith(u8, sm.state(), "both_true"));
        // Should evaluate: always_false (false), then counter AND flag (both true)
        try testing.expect(instance.guard_calls.items.len == 3);
        try testing.expectEqualStrings("always_false", instance.guard_calls.items[0]);
        try testing.expect(instance.guard_results.items[0] == false);
        try testing.expectEqualStrings("counter", instance.guard_calls.items[1]);
        try testing.expect(instance.guard_results.items[1] == true);
        try testing.expectEqualStrings("flag", instance.guard_calls.items[2]);
        try testing.expect(instance.guard_results.items[2] == true);
    }

    // Test case 2: Only counter true
    {
        var instance = try GuardTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "setup_counter"));
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));

        try testing.expect(std.mem.endsWith(u8, sm.state(), "counter_only"));
    }

    // Test case 3: Only flag true
    {
        var instance = try GuardTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "setup_flag"));
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));

        try testing.expect(std.mem.endsWith(u8, sm.state(), "flag_only"));
    }

    // Test case 4: Neither condition true
    {
        var instance = try GuardTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));

        try testing.expect(std.mem.endsWith(u8, sm.state(), "none_true"));
    }
}

test "Guards with internal transitions" {
    const model = comptime hsm.define("InternalGuardTest", .{
        hsm.initial(hsm.target("processor")),
        hsm.state("processor", .{
            // Internal transitions with guards
            hsm.transition(.{ hsm.on("process"), hsm.guard(counterGuard), hsm.effect(incrementCounter) }), // Internal if guard passes
            hsm.transition(.{ hsm.on("process"), hsm.effect(incrementCounter) }), // Internal fallback
            // External transition to check final state
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") }),
        }),
        hsm.state("done", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try GuardTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Initially counter = 0, first guard will fail, fallback will increment
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));
    try testing.expect(instance.counter == 1);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "processor")); // Still in same state

    // Continue until counter guard passes
    for (0..5) |_| {
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));
    }

    // At this point counter should be >= 5, so first transition should be taken
    try testing.expect(instance.counter >= 5);

    // Verify we can still finish normally
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "done"));

    // Check that guards were evaluated
    try testing.expect(instance.guard_calls.items.len > 0);
    // Check that "counter" appears in the guard calls
    var found_counter = false;
    for (instance.guard_calls.items) |call| {
        if (std.mem.eql(u8, call, "counter")) {
            found_counter = true;
            break;
        }
    }
    try testing.expect(found_counter);
}
