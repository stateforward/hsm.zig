const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for tracking activity execution
const ActivityTestInstance = struct {
    base: hsm.Instance,
    activity_starts: std.ArrayList([]const u8),
    activity_completions: std.ArrayList([]const u8),
    activity_counter: std.atomic.Value(i32),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .activity_starts = std.ArrayList([]const u8).init(allocator),
            .activity_completions = std.ArrayList([]const u8).init(allocator),
            .activity_counter = std.atomic.Value(i32).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.activity_starts.deinit();
        self.activity_completions.deinit();
        self.base.deinit();
    }
    
    pub fn recordActivityStart(self: *Self, name: []const u8) void {
        self.activity_starts.append(name) catch unreachable;
        _ = self.activity_counter.fetchAdd(1, .monotonic);
    }
    
    pub fn recordActivityCompletion(self: *Self, name: []const u8) void {
        self.activity_completions.append(name) catch unreachable;
        _ = self.activity_counter.fetchSub(1, .monotonic);
    }
    
    pub fn getActiveCount(self: *const Self) i32 {
        return self.activity_counter.load(.monotonic);
    }
};

// Activity functions
fn quickActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordActivityStart("quick");
    
    // Simulate very short work
    std.time.sleep(std.time.ns_per_ms * 10); // 10ms
    
    if (!ctx.is_done()) {
        test_inst.recordActivityCompletion("quick");
    }
}

fn mediumActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordActivityStart("medium");
    
    // Simulate medium work with cancellation checks
    var iterations: i32 = 0;
    while (iterations < 10 and !ctx.is_done()) {
        std.time.sleep(std.time.ns_per_ms * 20); // 20ms chunks
        iterations += 1;
    }
    
    if (!ctx.is_done()) {
        test_inst.recordActivityCompletion("medium");
    } else {
        test_inst.recordActivityCompletion("medium_cancelled");
    }
}

fn longActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordActivityStart("long");
    
    // Simulate long work with frequent cancellation checks
    var iterations: i32 = 0;
    while (iterations < 50 and !ctx.is_done()) {
        std.time.sleep(std.time.ns_per_ms * 10); // 10ms chunks
        iterations += 1;
    }
    
    if (!ctx.is_done()) {
        test_inst.recordActivityCompletion("long");
    } else {
        test_inst.recordActivityCompletion("long_cancelled");
    }
}

fn networkActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordActivityStart("network");
    
    // Simulate network activity with retries
    var retries: i32 = 0;
    while (retries < 3 and !ctx.is_done()) {
        std.time.sleep(std.time.ns_per_ms * 50); // Simulate network delay
        retries += 1;
        
        // Simulate successful connection on last retry
        if (retries == 3 and !ctx.is_done()) {
            test_inst.recordActivityCompletion("network");
            return;
        }
    }
    
    if (ctx.is_done()) {
        test_inst.recordActivityCompletion("network_cancelled");
    }
}

fn monitoringActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordActivityStart("monitoring");
    
    // Continuous monitoring loop
    while (!ctx.is_done()) {
        std.time.sleep(std.time.ns_per_ms * 30); // Check every 30ms
    }
    
    test_inst.recordActivityCompletion("monitoring_cancelled");
}

test "Single activity execution" {
    const model = comptime hsm.define("SingleActivityTest", .{
        hsm.initial(hsm.target("working")),
        hsm.state("working", .{
            hsm.activity(quickActivity),
            hsm.transition(.{ hsm.on("done"), hsm.target("finished") })
        }),
        hsm.final("finished")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in working state and begin activity
    try testing.expect(std.mem.endsWith(u8, sm.state(), "working"));
    
    // Wait for activity to complete
    std.time.sleep(std.time.ns_per_ms * 50); // Give activity time to finish
    
    try testing.expect(instance.activity_starts.items.len == 1);
    try testing.expectEqualStrings("quick", instance.activity_starts.items[0]);
    try testing.expect(instance.activity_completions.items.len == 1);
    try testing.expectEqualStrings("quick", instance.activity_completions.items[0]);
    
    // Transition to finished
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "done"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "finished"));
}

test "Multiple concurrent activities" {
    const model = comptime hsm.define("MultipleActivityTest", .{
        hsm.initial(hsm.target("busy")),
        hsm.state("busy", .{
            hsm.activity(.{ quickActivity, mediumActivity, networkActivity }),
            hsm.transition(.{ hsm.on("stop"), hsm.target("idle") })
        }),
        hsm.state("idle", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in busy state and begin all activities concurrently
    try testing.expect(std.mem.endsWith(u8, sm.state(), "busy"));
    
    // Give activities time to start
    std.time.sleep(std.time.ns_per_ms * 30);
    
    // All three activities should have started
    try testing.expect(instance.activity_starts.items.len == 3);
    try testing.expect(instance.getActiveCount() == 3);
    
    // Wait longer for activities to complete
    std.time.sleep(std.time.ns_per_ms * 300);
    
    // All activities should eventually complete
    try testing.expect(instance.activity_completions.items.len == 3);
    try testing.expect(instance.getActiveCount() == 0);
    
    // Verify all activities completed successfully
    var quick_completed = false;
    var medium_completed = false;
    var network_completed = false;
    
    for (instance.activity_completions.items) |completion| {
        if (std.mem.eql(u8, completion, "quick")) quick_completed = true;
        if (std.mem.eql(u8, completion, "medium")) medium_completed = true;
        if (std.mem.eql(u8, completion, "network")) network_completed = true;
    }
    
    try testing.expect(quick_completed);
    try testing.expect(medium_completed);
    try testing.expect(network_completed);
}

test "Activity cancellation on state exit" {
    const model = comptime hsm.define("ActivityCancellationTest", .{
        hsm.initial(hsm.target("running")),
        hsm.state("running", .{
            hsm.activity(.{ longActivity, monitoringActivity }),
            hsm.transition(.{ hsm.on("interrupt"), hsm.target("stopped") })
        }),
        hsm.state("stopped", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in running state and begin activities
    try testing.expect(std.mem.endsWith(u8, sm.state(), "running"));
    
    // Give activities time to start
    std.time.sleep(std.time.ns_per_ms * 50);
    
    try testing.expect(instance.activity_starts.items.len == 2);
    try testing.expect(instance.getActiveCount() == 2);
    
    // Interrupt before activities complete
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "interrupt"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "stopped"));
    
    // Give time for activities to detect cancellation and complete
    std.time.sleep(std.time.ns_per_ms * 100);
    
    // Activities should have been cancelled
    try testing.expect(instance.activity_completions.items.len == 2);
    try testing.expect(instance.getActiveCount() == 0);
    
    // Verify activities were cancelled
    var long_cancelled = false;
    var monitoring_cancelled = false;
    
    for (instance.activity_completions.items) |completion| {
        if (std.mem.eql(u8, completion, "long_cancelled")) long_cancelled = true;
        if (std.mem.eql(u8, completion, "monitoring_cancelled")) monitoring_cancelled = true;
    }
    
    try testing.expect(long_cancelled);
    try testing.expect(monitoring_cancelled);
}

test "Activity with event data access" {
    var event_data: i32 = 123;
    
    const dataActivity = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordActivityStart("data_activity");
            
            // Access event data
            if (event.getData("work_amount")) |data| {
                const amount_ptr: *i32 = @ptrCast(@alignCast(data));
                const work_amount = amount_ptr.*;
                
                // Simulate work proportional to data
                var i: i32 = 0;
                while (i < work_amount and !ctx.is_done()) {
                    std.time.sleep(std.time.ns_per_ms * 5);
                    i += 1;
                }
                
                if (!ctx.is_done()) {
                    test_inst.recordActivityCompletion("data_activity");
                }
            }
        }
    }.func;
    
    const model = comptime hsm.define("ActivityDataTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("work"), hsm.target("processing") })
        }),
        hsm.state("processing", .{
            hsm.activity(dataActivity),
            hsm.transition(.{ hsm.on("done"), hsm.target("finished") })
        }),
        hsm.final("finished")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Create event with work data
    var event = hsm.Event.withData(testing.allocator, "work");
    defer event.deinit();
    try event.putData("work_amount", &event_data);
    
    try sm.dispatch(&context, event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "processing"));
    
    // Give activity time to complete
    std.time.sleep(std.time.ns_per_ms * 700); // Should be enough for 123 * 5ms
    
    try testing.expect(instance.activity_starts.items.len == 1);
    try testing.expectEqualStrings("data_activity", instance.activity_starts.items[0]);
    try testing.expect(instance.activity_completions.items.len == 1);
    try testing.expectEqualStrings("data_activity", instance.activity_completions.items[0]);
}

test "Activities in hierarchical states" {
    const model = comptime hsm.define("HierarchicalActivityTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.activity(monitoringActivity), // Parent level activity
            hsm.initial(hsm.target("child")),
            hsm.state("child", .{
                hsm.activity(quickActivity), // Child level activity
                hsm.transition(.{ hsm.on("switch"), hsm.target("../sibling") })
            }),
            hsm.state("sibling", .{
                hsm.activity(mediumActivity)
            }),
            hsm.transition(.{ hsm.on("exit"), hsm.target("../other") })
        }),
        hsm.state("other", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in parent/child with both activities running
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));
    
    // Give activities time to start
    std.time.sleep(std.time.ns_per_ms * 50);
    
    try testing.expect(instance.activity_starts.items.len == 2);
    try testing.expect(instance.getActiveCount() == 2);
    
    // Switch to sibling - parent activity continues, child activity stops, sibling starts
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "switch"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "sibling"));
    
    // Give time for state change activities
    std.time.sleep(std.time.ns_per_ms * 100);
    
    // Should have 3 activities started (monitoring, quick, medium)
    try testing.expect(instance.activity_starts.items.len == 3);
    
    // Exit parent completely - all activities should be cancelled
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "exit"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "other"));
    
    // Give time for all activities to be cancelled
    std.time.sleep(std.time.ns_per_ms * 100);
    
    try testing.expect(instance.getActiveCount() == 0);
    try testing.expect(instance.activity_completions.items.len >= 2); // At least monitoring and medium cancelled
}

test "Activity error handling and cleanup" {
    var should_error = false;
    
    const errorProneActivity = struct {
        var error_flag: *bool = undefined;
        
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *ActivityTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordActivityStart("error_prone");
            
            // Simulate some work
            std.time.sleep(std.time.ns_per_ms * 30);
            
            if (error_flag.* and !ctx.is_done()) {
                test_inst.recordActivityCompletion("error_prone_failed");
                // In real implementation, this might dispatch an error event
                return;
            }
            
            if (!ctx.is_done()) {
                test_inst.recordActivityCompletion("error_prone");
            }
        }
    }.func;
    
    errorProneActivity.error_flag = &should_error;
    
    const model = comptime hsm.define("ActivityErrorTest", .{
        hsm.initial(hsm.target("working")),
        hsm.state("working", .{
            hsm.activity(.{ errorProneActivity, quickActivity }),
            hsm.transition(.{ hsm.on("retry"), hsm.target(".") }), // Self transition
            hsm.transition(.{ hsm.on("stop"), hsm.target("stopped") })
        }),
        hsm.state("stopped", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ActivityTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // First run - should succeed
    std.time.sleep(std.time.ns_per_ms * 100);
    
    try testing.expect(instance.activity_starts.items.len == 2);
    try testing.expect(instance.activity_completions.items.len == 2);
    
    // Set error flag and retry
    should_error = true;
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "retry"));
    
    // Give time for activities to run and potentially fail
    std.time.sleep(std.time.ns_per_ms * 100);
    
    // Should have more activity starts and the error completion
    try testing.expect(instance.activity_starts.items.len == 4); // 2 more starts
    
    // Check for error completion
    var error_found = false;
    for (instance.activity_completions.items) |completion| {
        if (std.mem.eql(u8, completion, "error_prone_failed")) {
            error_found = true;
            break;
        }
    }
    try testing.expect(error_found);
}