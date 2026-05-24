const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for effects testing
const EffectsTestInstance = struct {
    base: hsm.Instance,
    counter: i32,
    effect_sequence: std.ArrayList([]const u8),
    effect_data: std.HashMap([]const u8, i32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    status: []const u8,
    multiplier: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .base = hsm.Instance.init(),
            .counter = 0,
            .effect_sequence = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .effect_data = std.HashMap([]const u8, i32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .status = "initial",
            .multiplier = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.effect_sequence.deinit(self.allocator);
        self.effect_data.deinit();
        self.base.deinit();
    }

    pub fn recordEffect(self: *Self, name: []const u8) void {
        self.effect_sequence.append(self.allocator, name) catch unreachable;
    }

    pub fn storeData(self: *Self, key: []const u8, value: i32) void {
        self.effect_data.put(key, value) catch unreachable;
    }
};

// Single effect functions
fn incrementEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.counter += 1;
    test_inst.recordEffect("increment");
}

fn doubleEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.counter *= 2;
    test_inst.recordEffect("double");
}

fn resetEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.counter = 0;
    test_inst.recordEffect("reset");
}

fn setStatusEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.status = "processed";
    test_inst.recordEffect("set_status");
}

fn multiplyEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.counter *= test_inst.multiplier;
    test_inst.recordEffect("multiply");
}

fn storeCounterEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.storeData("stored_counter", test_inst.counter);
    test_inst.recordEffect("store_counter");
}

fn eventDataEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));

    if (event.getData("increment_value")) |data| {
        const value_ptr: *i32 = @ptrCast(@alignCast(data));
        test_inst.counter += value_ptr.*;
        test_inst.recordEffect("event_data");
    } else {
        test_inst.recordEffect("no_event_data");
    }
}

fn contextCheckEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));

    if (ctx.is_done()) {
        test_inst.recordEffect("cancelled");
    } else {
        test_inst.recordEffect("normal");
    }
}

fn setMultiplierEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));
    test_inst.multiplier = 3;
    test_inst.recordEffect("set_multiplier");
}

test "Single effect execution" {
    const model = comptime hsm.define("SingleEffectTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementEffect) }), // Internal transition
            hsm.transition(.{ hsm.on("move"), hsm.effect(setStatusEffect), hsm.target("end") }),
        }),
        hsm.state("end", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test internal transition with effect
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start")); // Still in start
    try testing.expect(instance.counter == 1);
    try testing.expect(instance.effect_sequence.items.len == 1);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[0]);

    // Test external transition with effect
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "move"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
    try testing.expectEqualStrings("processed", instance.status);
    try testing.expect(instance.effect_sequence.items.len == 2);
    try testing.expectEqualStrings("set_status", instance.effect_sequence.items[1]);
}

test "Multiple effects execution order" {
    const model = comptime hsm.define("MultipleEffectTest", .{ hsm.initial(hsm.target("calculator")), hsm.state("calculator", .{ hsm.transition(.{ hsm.on("complex_operation"), hsm.effect(.{ incrementEffect, doubleEffect, incrementEffect, multiplyEffect }), hsm.target("result") }), hsm.transition(.{ hsm.on("setup"), hsm.effect(setMultiplierEffect) }) }), hsm.state("result", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Setup multiplier first
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "setup"));
    try testing.expect(instance.multiplier == 3);

    // Execute complex operation: counter starts at 0
    // 1. increment: 0 + 1 = 1
    // 2. double: 1 * 2 = 2
    // 3. increment: 2 + 1 = 3
    // 4. multiply: 3 * 3 = 9
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "complex_operation"));

    try testing.expect(std.mem.endsWith(u8, sm.state(), "result"));
    try testing.expect(instance.counter == 9);

    // Check execution order
    try testing.expect(instance.effect_sequence.items.len == 5); // setup + 4 effects
    try testing.expectEqualStrings("set_multiplier", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[1]);
    try testing.expectEqualStrings("double", instance.effect_sequence.items[2]);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[3]);
    try testing.expectEqualStrings("multiply", instance.effect_sequence.items[4]);
}

test "Effects with event data" {
    const model = comptime hsm.define("EventDataEffectTest", .{ hsm.initial(hsm.target("processor")), hsm.state("processor", .{ hsm.transition(.{ hsm.on("process_data"), hsm.effect(.{ eventDataEffect, storeCounterEffect }), hsm.target("completed") }), hsm.transition(.{ hsm.on("process_no_data"), hsm.effect(eventDataEffect), hsm.target("completed") }) }), hsm.state("completed", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test with event data
    var data_value: i32 = 42;
    var event_with_data = hsm.Event.withData(testing.allocator, "process_data");
    defer event_with_data.deinit();
    try event_with_data.putData("increment_value", &data_value);

    try sm.dispatch(&context, event_with_data);

    try testing.expect(std.mem.endsWith(u8, sm.state(), "completed"));
    try testing.expect(instance.counter == 42);
    try testing.expect(instance.effect_sequence.items.len == 2);
    try testing.expectEqualStrings("event_data", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("store_counter", instance.effect_sequence.items[1]);

    // Verify stored data
    try testing.expect(instance.effect_data.get("stored_counter").? == 42);

    // Reset for second test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try EffectsTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Test without event data
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "process_no_data"));

    try testing.expect(std.mem.endsWith(u8, sm2.state(), "completed"));
    try testing.expect(instance2.counter == 0); // No increment
    try testing.expect(instance2.effect_sequence.items.len == 1);
    try testing.expectEqualStrings("no_event_data", instance2.effect_sequence.items[0]);
}

test "Effects in hierarchical states" {
    const model = comptime hsm.define("HierarchicalEffectTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("child")),
            hsm.transition(.{ hsm.on("parent_effect"), hsm.effect(doubleEffect) }), // Internal at parent level
            hsm.state("child", .{
                hsm.transition(.{ hsm.on("child_effect"), hsm.effect(incrementEffect) }), // Internal at child level
                hsm.transition(.{ hsm.on("move_up"), hsm.effect(setStatusEffect), hsm.target("../sibling") }),
            }),
            hsm.state("sibling", .{hsm.transition(.{ hsm.on("move_out"), hsm.effect(resetEffect), hsm.target("../../external") })}),
        }),
        hsm.state("external", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));

    // Test child-level internal effect
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "child_effect"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child")); // Still in child
    try testing.expect(instance.counter == 1);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[0]);

    // Test parent-level internal effect
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "parent_effect"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child")); // Still in child
    try testing.expect(instance.counter == 2); // 1 * 2
    try testing.expectEqualStrings("double", instance.effect_sequence.items[1]);

    // Test transition with effect from child to sibling
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "move_up"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "sibling"));
    try testing.expectEqualStrings("processed", instance.status);
    try testing.expectEqualStrings("set_status", instance.effect_sequence.items[2]);

    // Test transition with effect from sibling to external
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "move_out"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "external"));
    try testing.expect(instance.counter == 0); // Reset
    try testing.expectEqualStrings("reset", instance.effect_sequence.items[3]);
}

test "Effects with context cancellation" {
    const model = comptime hsm.define("ContextEffectTest", .{ hsm.initial(hsm.target("active")), hsm.state("active", .{hsm.transition(.{ hsm.on("check"), hsm.effect(.{ contextCheckEffect, incrementEffect }), hsm.target("result") })}), hsm.state("result", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test with normal context
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "check"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "result"));
    try testing.expect(instance.counter == 1);
    try testing.expect(instance.effect_sequence.items.len == 2);
    try testing.expectEqualStrings("normal", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[1]);

    // Reset for cancelled context test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var context2 = hsm.Context.init(testing.allocator);
    context2.cancel(); // Cancel before effects
    var instance2 = try EffectsTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context2, &instance2, &built_model2);
    defer sm2.deinit();

    try sm2.dispatch(&context2, hsm.Event.init(testing.allocator, "check"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "result"));
    try testing.expect(instance2.counter == 1); // Increment still happens
    try testing.expect(instance2.effect_sequence.items.len == 2);
    try testing.expectEqualStrings("cancelled", instance2.effect_sequence.items[0]);
    try testing.expectEqualStrings("increment", instance2.effect_sequence.items[1]);
}

test "Effects with self transitions" {
    const model = comptime hsm.define("SelfTransitionEffectTest", .{
        hsm.initial(hsm.target("counter_state")),
        hsm.state("counter_state", .{
            hsm.entry(resetEffect),
            hsm.exit(storeCounterEffect),
            hsm.transition(.{ hsm.on("self_increment"), hsm.effect(incrementEffect), hsm.target(".") }), // Self transition
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementEffect) }), // Internal transition
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") }),
        }),
        hsm.state("done", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Entry should have run, setting counter to 0
    try testing.expect(instance.counter == 0);
    try testing.expectEqualStrings("reset", instance.effect_sequence.items[0]);

    // Internal transition - no exit/entry
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "counter_state"));
    try testing.expect(instance.counter == 1);
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[1]);

    // Self transition - should trigger exit, effect, then entry
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "self_increment"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "counter_state"));
    try testing.expect(instance.counter == 0); // Exit stored 2, effect incremented to 3, entry reset to 0

    // Check sequence: initial reset, increment, store_counter (exit), increment (effect), reset (entry)
    try testing.expect(instance.effect_sequence.items.len == 5);
    try testing.expectEqualStrings("reset", instance.effect_sequence.items[0]); // Initial entry
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[1]); // Internal transition
    try testing.expectEqualStrings("store_counter", instance.effect_sequence.items[2]); // Exit effect
    try testing.expectEqualStrings("increment", instance.effect_sequence.items[3]); // Transition effect
    try testing.expectEqualStrings("reset", instance.effect_sequence.items[4]); // Re-entry

    // Verify stored value
    try testing.expect(instance.effect_data.get("stored_counter").? == 1);
}

test "Complex effects with multiple event data sources" {
    var config_data: i32 = 10;
    var operation_data: i32 = 5;

    const complexEventEffect = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));

            var base_value: i32 = 1;
            var multiplier_value: i32 = 1;

            if (event.getData("base")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                base_value = value_ptr.*;
            }

            if (event.getData("multiplier")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                multiplier_value = value_ptr.*;
            }

            test_inst.counter = base_value * multiplier_value;
            test_inst.recordEffect("complex_calculation");
        }
    }.func;

    const model = comptime hsm.define("ComplexEventEffectTest", .{ hsm.initial(hsm.target("calculator")), hsm.state("calculator", .{hsm.transition(.{ hsm.on("calculate"), hsm.effect(.{ complexEventEffect, storeCounterEffect }), hsm.target("result") })}), hsm.state("result", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Create event with multiple data fields
    var complex_event = hsm.Event.withData(testing.allocator, "calculate");
    defer complex_event.deinit();
    try complex_event.putData("base", &config_data);
    try complex_event.putData("multiplier", &operation_data);

    try sm.dispatch(&context, complex_event);

    try testing.expect(std.mem.endsWith(u8, sm.state(), "result"));
    try testing.expect(instance.counter == 50); // 10 * 5
    try testing.expect(instance.effect_sequence.items.len == 2);
    try testing.expectEqualStrings("complex_calculation", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("store_counter", instance.effect_sequence.items[1]);

    // Verify stored result
    try testing.expect(instance.effect_data.get("stored_counter").? == 50);
}

test "Effects error handling and recovery" {
    var should_fail = false;

    const FailureEffect = struct {
        var fail_flag: *bool = undefined;

        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            const test_inst: *EffectsTestInstance = @ptrCast(@alignCast(inst));

            test_inst.recordEffect("attempting");

            if (fail_flag.*) {
                test_inst.recordEffect("failed");
                // In a real implementation, this might trigger error handling
                // For testing, we just record the failure attempt
            } else {
                test_inst.counter += 10;
                test_inst.recordEffect("succeeded");
            }
        }
    };

    FailureEffect.fail_flag = &should_fail;

    const model = comptime hsm.define("ErrorHandlingEffectTest", .{
        hsm.initial(hsm.target("processor")),
        hsm.state("processor", .{
            hsm.transition(.{ hsm.on("process"), hsm.effect(.{ FailureEffect.func, storeCounterEffect }), hsm.target("completed") }),
            hsm.transition(.{ hsm.on("retry"), hsm.target(".") }), // Self transition for retry
        }),
        hsm.state("completed", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try EffectsTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // First attempt should succeed
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "completed"));
    try testing.expect(instance.counter == 10);
    try testing.expect(instance.effect_sequence.items.len == 3);
    try testing.expectEqualStrings("attempting", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("succeeded", instance.effect_sequence.items[1]);
    try testing.expectEqualStrings("store_counter", instance.effect_sequence.items[2]);

    // Reset for failure test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try EffectsTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Set failure flag and try again
    should_fail = true;
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "process"));

    // Should still transition but with failure recorded
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "completed"));
    try testing.expect(instance2.counter == 0); // No increment due to failure
    try testing.expect(instance2.effect_sequence.items.len == 3);
    try testing.expectEqualStrings("attempting", instance2.effect_sequence.items[0]);
    try testing.expectEqualStrings("failed", instance2.effect_sequence.items[1]);
    try testing.expectEqualStrings("store_counter", instance2.effect_sequence.items[2]); // Still executes

    // Verify stored failure state
    try testing.expect(instance2.effect_data.get("stored_counter").? == 0);
}
