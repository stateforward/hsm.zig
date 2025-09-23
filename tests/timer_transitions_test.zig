const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for timer transitions testing
const TimerTestInstance = struct {
    base: hsm.Instance,
    timer_count: i32,
    timeout_count: i32,
    timer_sequence: std.ArrayList([]const u8),
    timer_values: std.ArrayList(u64),
    last_timeout: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .base = hsm.Instance.init(),
            .timer_count = 0,
            .timeout_count = 0,
            .timer_sequence = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .timer_values = try std.ArrayList(u64).initCapacity(allocator, 0),
            .last_timeout = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.timer_sequence.deinit(self.allocator);
        self.timer_values.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordTimer(self: *Self, name: []const u8, value: u64) void {
        self.timer_sequence.append(self.allocator, name) catch unreachable;
        self.timer_values.append(self.allocator, value) catch unreachable;
    }

    pub fn incrementTimerCount(self: *Self) void {
        self.timer_count += 1;
    }

    pub fn incrementTimeoutCount(self: *Self) void {
        self.timeout_count += 1;
    }
};

// Timer functions returning nanoseconds
fn shortDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    const delay = std.time.ns_per_ms * 100; // 100ms
    test_inst.recordTimer("short_delay", delay);
    return delay;
}

fn mediumDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    const delay = std.time.ns_per_ms * 500; // 500ms
    test_inst.recordTimer("medium_delay", delay);
    return delay;
}

fn longDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    const delay = std.time.ns_per_s * 2; // 2 seconds
    test_inst.recordTimer("long_delay", delay);
    return delay;
}

fn periodicInterval(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    const interval = std.time.ns_per_ms * 200; // 200ms
    test_inst.recordTimer("periodic", interval);
    return interval;
}

fn dynamicDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    // Delay increases with each call
    const delay = std.time.ns_per_ms * @as(u64, @intCast(100 * (test_inst.timer_count + 1)));
    test_inst.recordTimer("dynamic", delay);
    test_inst.incrementTimerCount();
    return delay;
}

fn contextAwareDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));

    if (ctx.is_done()) {
        const delay = std.time.ns_per_ms * 10; // Very short if cancelled
        test_inst.recordTimer("cancelled_delay", delay);
        return delay;
    } else {
        const delay = std.time.ns_per_s; // 1 second if normal
        test_inst.recordTimer("normal_delay", delay);
        return delay;
    }
}

fn eventDataDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));

    if (event.getData("delay_ms")) |data| {
        const delay_ptr: *u64 = @ptrCast(@alignCast(data));
        const delay = std.time.ns_per_ms * delay_ptr.*;
        test_inst.recordTimer("event_data_delay", delay);
        return delay;
    } else {
        const delay = std.time.ns_per_ms * 50; // Default 50ms
        test_inst.recordTimer("default_delay", delay);
        return delay;
    }
}

// Effect functions for tracking
fn incrementTimerEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    test_inst.incrementTimerCount();
}

fn incrementTimeoutEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    test_inst.incrementTimeoutCount();
}

fn recordTimeoutEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
    test_inst.last_timeout = @intCast(std.time.nanoTimestamp());
}

test "Basic after timer transition" {
    const model = comptime hsm.define("BasicAfterTest", .{ hsm.initial(hsm.target("waiting")), hsm.state("waiting", .{ hsm.transition(.{ hsm.after(shortDelay), hsm.effect(incrementTimeoutEffect), hsm.target("timeout") }), hsm.transition(.{ hsm.on("manual"), hsm.target("manual") }) }), hsm.state("timeout", .{}), hsm.state("manual", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in waiting
    try testing.expect(std.mem.endsWith(u8, sm.state(), "waiting"));

    // Timer function should have been called during state entry
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("short_delay", instance.timer_sequence.items[0]);
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_ms * 100);

    // Simulate timer expiration by waiting and then dispatching timeout event
    std.Thread.sleep(std.time.ns_per_ms * 150); // Wait longer than timer

    // In a real implementation, the timer would dispatch a timeout event automatically
    // For testing, we simulate this by dispatching the timeout event manually
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout"));

    try testing.expect(std.mem.endsWith(u8, sm.state(), "timeout"));
    try testing.expect(instance.timeout_count == 1);

    // Test that manual event can interrupt timer
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try TimerTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Dispatch manual event before timer expires
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "manual"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "manual"));
    try testing.expect(instance2.timeout_count == 0); // No timeout
}

test "Multiple after timers with different delays" {
    const model = comptime hsm.define("MultipleAfterTest", .{ hsm.initial(hsm.target("multi_timer")), hsm.state("multi_timer", .{ hsm.transition(.{ hsm.after(shortDelay), hsm.target("short_timeout") }), hsm.transition(.{ hsm.after(mediumDelay), hsm.target("medium_timeout") }), hsm.transition(.{ hsm.after(longDelay), hsm.target("long_timeout") }), hsm.transition(.{ hsm.on("cancel"), hsm.target("cancelled") }) }), hsm.state("short_timeout", .{}), hsm.state("medium_timeout", .{}), hsm.state("long_timeout", .{}), hsm.state("cancelled", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in multi_timer with all timer functions called
    try testing.expect(std.mem.endsWith(u8, sm.state(), "multi_timer"));
    try testing.expect(instance.timer_sequence.items.len == 3);

    // Check that all timers were set up
    try testing.expectEqualStrings("short_delay", instance.timer_sequence.items[0]);
    try testing.expectEqualStrings("medium_delay", instance.timer_sequence.items[1]);
    try testing.expectEqualStrings("long_delay", instance.timer_sequence.items[2]);

    // Verify timer values
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_ms * 100);
    try testing.expect(instance.timer_values.items[1] == std.time.ns_per_ms * 500);
    try testing.expect(instance.timer_values.items[2] == std.time.ns_per_s * 2);

    // In a real implementation, the shortest timer would fire first
    // For testing, we simulate the shortest timeout
    std.Thread.sleep(std.time.ns_per_ms * 150);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout_short"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "short_timeout"));
}

test "Every timer with periodic behavior" {
    const model = comptime hsm.define("PeriodicEveryTest", .{
        hsm.initial(hsm.target("periodic_state")),
        hsm.state("periodic_state", .{
            hsm.transition(.{ hsm.every(periodicInterval), hsm.effect(incrementTimerEffect), hsm.target(".") }), // Self transition
            hsm.transition(.{ hsm.on("stop"), hsm.target("stopped") }),
        }),
        hsm.state("stopped", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in periodic_state with timer set
    try testing.expect(std.mem.endsWith(u8, sm.state(), "periodic_state"));
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("periodic", instance.timer_sequence.items[0]);
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_ms * 200);

    // Simulate multiple periodic timeouts
    for (0..3) |_| {
        std.Thread.sleep(std.time.ns_per_ms * 250); // Wait longer than interval
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_periodic"));
    }

    // Should still be in periodic_state with multiple timer increments
    try testing.expect(std.mem.endsWith(u8, sm.state(), "periodic_state"));
    try testing.expect(instance.timer_count == 3);

    // Should have recorded multiple timer calls (initial + 3 self-transitions)
    try testing.expect(instance.timer_sequence.items.len == 4);
    for (instance.timer_sequence.items) |name| {
        try testing.expectEqualStrings("periodic", name);
    }

    // Stop the periodic behavior
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "stop"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "stopped"));
}

test "Dynamic timer values based on instance state" {
    const model = comptime hsm.define("DynamicTimerTest", .{
        hsm.initial(hsm.target("dynamic_delays")),
        hsm.state("dynamic_delays", .{
            hsm.transition(.{ hsm.after(dynamicDelay), hsm.effect(recordTimeoutEffect), hsm.target(".") }), // Self transition
            hsm.transition(.{ hsm.on("finish"), hsm.target("finished") }),
        }),
        hsm.state("finished", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start with first timer (100ms)
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("dynamic", instance.timer_sequence.items[0]);
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_ms * 100);
    try testing.expect(instance.timer_count == 1);

    // Simulate first timeout
    std.Thread.sleep(std.time.ns_per_ms * 150);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout"));

    // Should have set up second timer (200ms)
    try testing.expect(instance.timer_sequence.items.len == 2);
    try testing.expectEqualStrings("dynamic", instance.timer_sequence.items[1]);
    try testing.expect(instance.timer_values.items[1] == std.time.ns_per_ms * 200);
    try testing.expect(instance.timer_count == 2);

    // Simulate second timeout
    std.Thread.sleep(std.time.ns_per_ms * 250);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout"));

    // Should have set up third timer (300ms)
    try testing.expect(instance.timer_sequence.items.len == 3);
    try testing.expectEqualStrings("dynamic", instance.timer_sequence.items[2]);
    try testing.expect(instance.timer_values.items[2] == std.time.ns_per_ms * 300);
    try testing.expect(instance.timer_count == 3);

    // Finish before next timeout
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "finished"));
}

test "Timer functions with event data" {
    const model = comptime hsm.define("EventDataTimerTest", .{ hsm.initial(hsm.target("configurable_timer")), hsm.state("configurable_timer", .{hsm.transition(.{ hsm.on("set_timer"), hsm.after(eventDataDelay), hsm.target("timed_out") })}), hsm.state("timed_out", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test with custom delay from event data
    var delay_value: u64 = 300;
    var timer_event = hsm.Event.withData(testing.allocator, "set_timer");
    defer timer_event.deinit();
    try timer_event.putData("delay_ms", &delay_value);

    try sm.dispatch(&context, timer_event);

    // Timer function should have been called with event data
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("event_data_delay", instance.timer_sequence.items[0]);
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_ms * 300);

    // Test without event data (should use default)
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = try TimerTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "set_timer"));

    try testing.expect(instance2.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("default_delay", instance2.timer_sequence.items[0]);
    try testing.expect(instance2.timer_values.items[0] == std.time.ns_per_ms * 50);
}

test "Timer functions with context cancellation" {
    const model = comptime hsm.define("ContextTimerTest", .{ hsm.initial(hsm.target("context_aware")), hsm.state("context_aware", .{hsm.transition(.{ hsm.after(contextAwareDelay), hsm.target("completed") })}), hsm.state("completed", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // With normal context, should use long delay
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("normal_delay", instance.timer_sequence.items[0]);
    try testing.expect(instance.timer_values.items[0] == std.time.ns_per_s);

    // Test with cancelled context
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var context2 = hsm.Context.init(testing.allocator);
    context2.cancel(); // Cancel before starting
    var instance2 = try TimerTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context2, &instance2, &built_model2);
    defer sm2.deinit();

    // With cancelled context, should use short delay
    try testing.expect(instance2.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("cancelled_delay", instance2.timer_sequence.items[0]);
    try testing.expect(instance2.timer_values.items[0] == std.time.ns_per_ms * 10);
}

test "Timer cancellation on state exit" {
    const model = comptime hsm.define("TimerCancellationTest", .{ hsm.initial(hsm.target("timer_state")), hsm.state("timer_state", .{ hsm.transition(.{ hsm.after(longDelay), hsm.target("timeout_state") }), hsm.transition(.{ hsm.on("interrupt"), hsm.target("interrupted_state") }) }), hsm.state("timeout_state", .{}), hsm.state("interrupted_state", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in timer_state with long timer set
    try testing.expect(std.mem.endsWith(u8, sm.state(), "timer_state"));
    try testing.expect(instance.timer_sequence.items.len == 1);
    try testing.expectEqualStrings("long_delay", instance.timer_sequence.items[0]);

    // Interrupt before timer expires
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "interrupt"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "interrupted_state"));

    // Timer should be cancelled, so even if we wait, no timeout should occur
    std.Thread.sleep(std.time.ns_per_s * 3); // Wait longer than timer

    // State should remain interrupted (timer was cancelled)
    try testing.expect(std.mem.endsWith(u8, sm.state(), "interrupted_state"));
}

test "Hierarchical states with timer inheritance" {
    const model = comptime hsm.define("HierarchicalTimerTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("child")),
            hsm.transition(.{ hsm.after(longDelay), hsm.target("parent_timeout") }), // Parent-level timer
            hsm.state("child", .{
                hsm.transition(.{ hsm.after(shortDelay), hsm.target("../sibling") }), // Child-level timer
                hsm.transition(.{ hsm.on("manual"), hsm.target("../sibling") }),
            }),
            hsm.state("sibling", .{
                hsm.transition(.{ hsm.every(periodicInterval), hsm.effect(incrementTimerEffect) }), // Internal periodic
            }),
        }),
        hsm.state("parent_timeout", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child with both timers active
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));
    try testing.expect(instance.timer_sequence.items.len == 2);

    // Check that both parent and child timers were set
    var has_long = false;
    var has_short = false;
    for (instance.timer_sequence.items) |name| {
        if (std.mem.eql(u8, name, "long_delay")) has_long = true;
        if (std.mem.eql(u8, name, "short_delay")) has_short = true;
    }
    try testing.expect(has_long and has_short);

    // Child timer should fire first (shorter delay)
    std.Thread.sleep(std.time.ns_per_ms * 150);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout_child"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "sibling"));

    // Now in sibling with periodic timer
    try testing.expect(instance.timer_sequence.items.len == 3);
    try testing.expectEqualStrings("periodic", instance.timer_sequence.items[2]);

    // Test periodic behavior
    std.Thread.sleep(std.time.ns_per_ms * 250);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_periodic"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "sibling")); // Still in sibling
    try testing.expect(instance.timer_count == 1); // Effect executed

    // Parent timer should still be active and can fire
    std.Thread.sleep(std.time.ns_per_s * 3);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_timeout_parent"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "parent_timeout"));
}

test "Complex timer interactions with multiple every timers" {
    var counter_a: i32 = 0;
    var counter_b: i32 = 0;

    const FastInterval = struct {
        var counter: *i32 = undefined;
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
            _ = ctx;
            _ = event;
            const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
            counter.* += 1;
            const interval = std.time.ns_per_ms * 50; // 50ms
            test_inst.recordTimer("fast", interval);
            return interval;
        }
    };

    const SlowInterval = struct {
        var counter: *i32 = undefined;
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
            _ = ctx;
            _ = event;
            const test_inst: *TimerTestInstance = @ptrCast(@alignCast(inst));
            counter.* += 1;
            const interval = std.time.ns_per_ms * 150; // 150ms
            test_inst.recordTimer("slow", interval);
            return interval;
        }
    };

    FastInterval.counter = &counter_a;
    SlowInterval.counter = &counter_b;

    const model = comptime hsm.define("MultipleEveryTest", .{
        hsm.initial(hsm.target("dual_periodic")),
        hsm.state("dual_periodic", .{
            hsm.transition(.{ hsm.every(FastInterval.func), hsm.effect(incrementTimerEffect) }), // Internal
            hsm.transition(.{ hsm.every(SlowInterval.func), hsm.effect(incrementTimeoutEffect) }), // Internal
            hsm.transition(.{ hsm.on("stop"), hsm.target("stopped") }),
        }),
        hsm.state("stopped", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TimerTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start with both timers set
    try testing.expect(std.mem.endsWith(u8, sm.state(), "dual_periodic"));
    try testing.expect(instance.timer_sequence.items.len == 2);

    // Simulate multiple timer firings
    // Fast timer: 50ms intervals, should fire ~4 times in 200ms
    // Slow timer: 150ms intervals, should fire ~1 time in 200ms

    for (0..4) |_| {
        std.Thread.sleep(std.time.ns_per_ms * 60); // Slightly longer than fast interval
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_periodic_fast"));
    }

    // One slow timer firing
    std.Thread.sleep(std.time.ns_per_ms * 160);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "_periodic_slow"));

    // Check counters
    try testing.expect(instance.timer_count == 4); // Fast timer effects
    try testing.expect(instance.timeout_count == 1); // Slow timer effect
    try testing.expect(counter_a >= 4); // Fast timer function calls
    try testing.expect(counter_b >= 1); // Slow timer function calls

    // Stop the timers
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "stop"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "stopped"));
}
