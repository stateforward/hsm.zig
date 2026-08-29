const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for context cancellation testing
const CancellationTestInstance = struct {
    base: hsm.Instance,
    cancellation_count: i32,
    activity_executions: i32,
    cleanup_calls: i32,
    operation_results: std.ArrayList([]const u8),
    last_cancellation_reason: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .cancellation_count = 0,
            .activity_executions = 0,
            .cleanup_calls = 0,
            .operation_results = .{},
            .last_cancellation_reason = "none",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.operation_results.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordCancellation(self: *Self, reason: []const u8) void {
        self.cancellation_count += 1;
        self.last_cancellation_reason = reason;
    }

    pub fn recordActivity(self: *Self) void {
        self.activity_executions += 1;
    }

    pub fn recordCleanup(self: *Self) void {
        self.cleanup_calls += 1;
    }

    pub fn recordResult(self: *Self, result: []const u8) void {
        self.operation_results.append(self.allocator, result) catch unreachable;
    }
};

// Activity functions that respect cancellation
fn cancellableActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    test_inst.recordActivity();

    // Simulate work with cancellation checks
    var iterations: i32 = 0;
    while (iterations < 10) {
        if (ctx.is_done()) {
            test_inst.recordCancellation("activity_cancelled");
            return;
        }

        // Simulate some work
        std.Thread.sleep(std.time.ns_per_ms * 10); // 10ms
        iterations += 1;
    }

    test_inst.recordResult("activity_completed");
}

fn longRunningActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    test_inst.recordActivity();

    // Longer simulation with frequent cancellation checks
    var iterations: i32 = 0;
    while (iterations < 100) {
        if (ctx.is_done()) {
            test_inst.recordCancellation("long_activity_cancelled");
            return;
        }

        std.Thread.sleep(std.time.ns_per_ms * 5); // 5ms
        iterations += 1;
    }

    test_inst.recordResult("long_activity_completed");
}

fn immediateActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    test_inst.recordActivity();

    // Check cancellation immediately
    if (ctx.is_done()) {
        test_inst.recordCancellation("immediate_cancelled");
        return;
    }

    test_inst.recordResult("immediate_completed");
}

// Entry/Exit functions that check cancellation
fn cancellationAwareEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    if (ctx.is_done()) {
        test_inst.recordCancellation("entry_cancelled");
    } else {
        test_inst.recordResult("entry_normal");
    }
}

fn cancellationAwareExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    if (ctx.is_done()) {
        test_inst.recordCancellation("exit_cancelled");
    } else {
        test_inst.recordResult("exit_normal");
    }
}

fn cleanupExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordCleanup();
}

// Guard functions that check cancellation
fn cancellationGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = event;
    const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

    if (ctx.is_done()) {
        test_inst.recordCancellation("guard_cancelled");
        return false;
    }

    return true;
}

test "Basic context cancellation in activities" {
    const model = comptime hsm.define("BasicCancellationTest", .{ hsm.initial(hsm.target("active")), hsm.state("active", .{ hsm.activity(cancellableActivity), hsm.transition(.{ hsm.on("stop"), hsm.target("stopped") }) }), hsm.state("stopped", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Activity should start running
    try testing.expect(std.mem.endsWith(u8, sm.state(), "active"));

    // Wait a moment to let activity start
    std.Thread.sleep(std.time.ns_per_ms * 20);

    // Cancel context
    context.cancel();

    // Wait for activity to detect cancellation
    std.Thread.sleep(std.time.ns_per_ms * 50);

    // Activity should have detected cancellation
    try testing.expect(instance.activity_executions == 1);
    try testing.expect(instance.cancellation_count >= 1);
    try testing.expectEqualStrings("activity_cancelled", instance.last_cancellation_reason);
}

test "Context cancellation during state machine startup" {
    const model = comptime hsm.define("StartupCancellationTest", .{ hsm.initial(hsm.target("startup")), hsm.state("startup", .{ hsm.entry(cancellationAwareEntry), hsm.exit(cancellationAwareExit), hsm.initial(hsm.target("nested")), hsm.state("nested", .{ hsm.entry(cancellationAwareEntry), hsm.activity(immediateActivity) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    context.cancel(); // Cancel before starting

    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should detect cancellation in entry functions
    try testing.expect(instance.cancellation_count >= 1);

    // Entry functions should have seen cancellation
    // Activity should detect immediate cancellation
    try testing.expect(instance.activity_executions >= 1);
    try testing.expect(std.mem.eql(u8, instance.last_cancellation_reason, "immediate_cancelled"));
}

test "Multiple concurrent activities with cancellation" {
    const ConcurrentActivity1 = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

            test_inst.recordActivity();

            var iterations: i32 = 0;
            while (iterations < 20) {
                if (ctx.is_done()) {
                    test_inst.recordCancellation("activity1_cancelled");
                    return;
                }
                std.Thread.sleep(std.time.ns_per_ms * 10);
                iterations += 1;
            }

            test_inst.recordResult("activity1_completed");
        }
    }.func;

    const ConcurrentActivity2 = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

            test_inst.recordActivity();

            var iterations: i32 = 0;
            while (iterations < 15) {
                if (ctx.is_done()) {
                    test_inst.recordCancellation("activity2_cancelled");
                    return;
                }
                std.Thread.sleep(std.time.ns_per_ms * 15);
                iterations += 1;
            }

            test_inst.recordResult("activity2_completed");
        }
    }.func;

    const model = comptime hsm.define("ConcurrentCancellationTest", .{ hsm.initial(hsm.target("concurrent")), hsm.state("concurrent", .{ hsm.activity(.{ ConcurrentActivity1, ConcurrentActivity2, longRunningActivity }), hsm.transition(.{ hsm.on("finish"), hsm.target("finished") }) }), hsm.state("finished", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // All activities should start
    try testing.expect(std.mem.endsWith(u8, sm.state(), "concurrent"));

    // Wait for activities to start
    std.Thread.sleep(std.time.ns_per_ms * 30);

    // Cancel context
    context.cancel();

    // Wait for all activities to detect cancellation
    std.Thread.sleep(std.time.ns_per_ms * 100);

    // Should have started 3 activities
    try testing.expect(instance.activity_executions == 3);

    // All should have been cancelled
    try testing.expect(instance.cancellation_count >= 3);
}

test "Cancellation during hierarchical state transitions" {
    const model = comptime hsm.define("HierarchicalCancellationTest", .{ hsm.initial(hsm.target("parent")), hsm.state("parent", .{ hsm.entry(cancellationAwareEntry), hsm.exit(cancellationAwareExit), hsm.initial(hsm.target("child")), hsm.state("child", .{ hsm.entry(cancellationAwareEntry), hsm.exit(cancellationAwareExit), hsm.activity(longRunningActivity), hsm.transition(.{ hsm.on("move"), hsm.target("../sibling") }) }), hsm.state("sibling", .{ hsm.entry(cancellationAwareEntry), hsm.exit(cleanupExit), hsm.activity(cancellableActivity) }) }), hsm.state("external", .{hsm.entry(cancellationAwareEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child with long running activity
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));

    // Wait for activity to start
    std.Thread.sleep(std.time.ns_per_ms * 20);

    // Attempt transition while cancelling context
    context.cancel();

    // Try to transition (may or may not complete depending on timing)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "move"));

    // Wait for cancellation to propagate
    std.Thread.sleep(std.time.ns_per_ms * 50);

    // Activity should have been cancelled
    try testing.expect(instance.activity_executions >= 1);
    try testing.expect(instance.cancellation_count >= 1);
}

test "Guards and effects with context cancellation" {
    const model = comptime hsm.define("GuardCancellationTest", .{ hsm.initial(hsm.target("guarded")), hsm.state("guarded", .{ hsm.entry(cancellationAwareEntry), hsm.transition(.{ hsm.on("test"), hsm.guard(cancellationGuard), hsm.effect(cancellationAwareEntry), hsm.target("passed") }), hsm.transition(.{ hsm.on("test"), hsm.effect(cancellationAwareEntry), hsm.target("failed") }) }), hsm.state("passed", .{hsm.entry(cancellationAwareEntry)}), hsm.state("failed", .{hsm.entry(cancellationAwareEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);

    // Test with normal context
    {
        var instance = CancellationTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "test"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "passed"));
        try testing.expect(instance.cancellation_count == 0);
    }

    // Test with cancelled context
    {
        var cancelled_context = hsm.Context.init(testing.allocator);
        cancelled_context.cancel();

        var instance = CancellationTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&cancelled_context, &instance, &built_model);
        defer sm.deinit();

        try sm.dispatch(&cancelled_context, hsm.Event.init(testing.allocator, "test"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "failed"));
        try testing.expect(instance.cancellation_count >= 1);
        try testing.expectEqualStrings("entry_cancelled", instance.last_cancellation_reason);
    }
}

test "Cleanup during cancellation" {
    const ResourceActivity = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

            test_inst.recordActivity();
            test_inst.recordResult("resource_acquired");

            // Simulate holding a resource
            var work_done: i32 = 0;
            while (work_done < 100) {
                if (ctx.is_done()) {
                    // Cleanup resource before returning
                    test_inst.recordCleanup();
                    test_inst.recordResult("resource_cleaned");
                    test_inst.recordCancellation("resource_cancelled");
                    return;
                }

                std.Thread.sleep(std.time.ns_per_ms * 2);
                work_done += 1;
            }

            test_inst.recordResult("resource_completed");
            test_inst.recordCleanup();
        }
    }.func;

    const model = comptime hsm.define("CleanupCancellationTest", .{ hsm.initial(hsm.target("resource_state")), hsm.state("resource_state", .{ hsm.activity(ResourceActivity), hsm.exit(cleanupExit), hsm.transition(.{ hsm.on("release"), hsm.target("released") }) }), hsm.state("released", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Wait for resource to be acquired
    std.Thread.sleep(std.time.ns_per_ms * 20);

    // Verify resource was acquired
    var found_acquired = false;
    for (instance.operation_results.items) |result| {
        if (std.mem.eql(u8, result, "resource_acquired")) {
            found_acquired = true;
            break;
        }
    }
    try testing.expect(found_acquired);

    // Cancel context
    context.cancel();

    // Wait for cleanup
    std.Thread.sleep(std.time.ns_per_ms * 50);

    // Verify cleanup occurred
    try testing.expect(instance.cleanup_calls >= 1);
    try testing.expect(instance.cancellation_count >= 1);
    try testing.expectEqualStrings("resource_cancelled", instance.last_cancellation_reason);

    // Verify resource was cleaned up
    var found_cleaned = false;
    for (instance.operation_results.items) |result| {
        if (std.mem.eql(u8, result, "resource_cleaned")) {
            found_cleaned = true;
            break;
        }
    }
    try testing.expect(found_cleaned);
}

test "Cancellation propagation timing" {
    var start_time: i64 = 0;
    var end_time: i64 = 0;

    const TimedActivity = struct {
        var start: *i64 = undefined;
        var end: *i64 = undefined;

        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *CancellationTestInstance = @ptrCast(@alignCast(inst));

            start.* = @intCast(std.time.nanoTimestamp());
            test_inst.recordActivity();

            // Work for up to 200ms or until cancelled
            var iterations: i32 = 0;
            while (iterations < 40) { // 40 * 5ms = 200ms max
                if (ctx.is_done()) {
                    end.* = @intCast(std.time.nanoTimestamp());
                    test_inst.recordCancellation("timed_cancelled");
                    return;
                }

                std.Thread.sleep(std.time.ns_per_ms * 5);
                iterations += 1;
            }

            end.* = @intCast(std.time.nanoTimestamp());
            test_inst.recordResult("timed_completed");
        }
    };

    TimedActivity.start = &start_time;
    TimedActivity.end = &end_time;

    const model = comptime hsm.define("TimingCancellationTest", .{ hsm.initial(hsm.target("timed")), hsm.state("timed", .{hsm.activity(TimedActivity.func)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = CancellationTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Wait 50ms then cancel
    std.Thread.sleep(std.time.ns_per_ms * 50);
    context.cancel();

    // Wait for cancellation to be detected
    std.Thread.sleep(std.time.ns_per_ms * 30);

    // Activity should have been cancelled
    try testing.expect(instance.activity_executions == 1);
    try testing.expect(instance.cancellation_count == 1);
    try testing.expectEqualStrings("timed_cancelled", instance.last_cancellation_reason);

    // Check timing - should be cancelled well before 200ms
    const duration_ns = end_time - start_time;
    const duration_ms = @divTrunc(duration_ns, std.time.ns_per_ms);
    try testing.expect(duration_ms < 150); // Should be cancelled before full duration
}
