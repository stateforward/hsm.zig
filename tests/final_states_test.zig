const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for final states testing
const FinalStateTestInstance = struct {
    base: hsm.Instance,
    completion_count: i32,
    final_states_reached: std.ArrayList([]const u8),
    transition_attempts: i32,
    invalid_operations: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .completion_count = 0,
            .final_states_reached = std.ArrayList([]const u8).init(allocator),
            .transition_attempts = 0,
            .invalid_operations = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.final_states_reached.deinit();
        self.invalid_operations.deinit();
        self.base.deinit();
    }
    
    pub fn recordCompletion(self: *Self, final_state: []const u8) void {
        self.completion_count += 1;
        self.final_states_reached.append(final_state) catch unreachable;
    }
    
    pub fn recordTransitionAttempt(self: *Self) void {
        self.transition_attempts += 1;
    }
    
    pub fn recordInvalidOperation(self: *Self, operation: []const u8) void {
        self.invalid_operations.append(operation) catch unreachable;
    }
};

// Effect functions for tracking
fn completionEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *FinalStateTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordCompletion("completed");
}

fn successEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *FinalStateTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordCompletion("success");
}

fn failureEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *FinalStateTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordCompletion("failure");
}

fn transitionAttemptEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *FinalStateTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordTransitionAttempt();
}

// Guard function for conditional completion
fn shouldComplete(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *FinalStateTestInstance = @ptrCast(@alignCast(inst));
    return test_inst.completion_count == 0; // Only complete once
}

test "Basic final state termination" {
    const model = comptime hsm.define("BasicFinalTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("complete"), hsm.effect(completionEffect), hsm.target("finished") })
        }),
        hsm.final("finished")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in start state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    
    // Transition to final state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "complete"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "finished"));
    try testing.expect(instance.completion_count == 1);
    try testing.expectEqualStrings("completed", instance.final_states_reached.items[0]);
    
    // Verify state machine is in final state
    try testing.expect(std.mem.contains(u8, sm.state(), "finished"));
}

test "Multiple final states with different completion paths" {
    const model = comptime hsm.define("MultipleFinalTest", .{
        hsm.initial(hsm.target("processing")),
        hsm.state("processing", .{
            hsm.transition(.{ hsm.on("succeed"), hsm.effect(successEffect), hsm.target("success") }),
            hsm.transition(.{ hsm.on("fail"), hsm.effect(failureEffect), hsm.target("failure") }),
            hsm.transition(.{ hsm.on("cancel"), hsm.target("cancelled") })
        }),
        hsm.final("success"),
        hsm.final("failure"),
        hsm.final("cancelled")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test success path
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "succeed"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "success"));
        try testing.expect(instance.completion_count == 1);
        try testing.expectEqualStrings("success", instance.final_states_reached.items[0]);
    }
    
    // Test failure path
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "fail"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "failure"));
        try testing.expect(instance.completion_count == 1);
        try testing.expectEqualStrings("failure", instance.final_states_reached.items[0]);
    }
    
    // Test cancellation path (no effect)
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "cancel"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "cancelled"));
        try testing.expect(instance.completion_count == 0); // No effect executed
    }
}

test "Final states in hierarchical state machines" {
    const model = comptime hsm.define("HierarchicalFinalTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("child")),
            hsm.state("child", .{
                hsm.transition(.{ hsm.on("finish_child"), hsm.target("../child_done") }),
                hsm.transition(.{ hsm.on("finish_parent"), hsm.target("../../parent_done") })
            }),
            hsm.final("child_done")
        }),
        hsm.final("parent_done")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test child-level final state
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        // Should start in parent/child
        try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));
        
        // Finish at child level
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish_child"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "child_done"));
        try testing.expect(std.mem.contains(u8, sm.state(), "parent"));
    }
    
    // Test parent-level final state
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        // Finish at parent level (exit entire hierarchy)
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish_parent"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "parent_done"));
        try testing.expect(!std.mem.contains(u8, sm.state(), "parent/"));
    }
}

test "Final state restrictions - no transitions" {
    // This test verifies that final states correctly restrict transitions
    // In the current implementation, this would be caught at validation time
    
    const valid_model = comptime hsm.define("ValidFinalRestrictionsTest", .{
        hsm.initial(hsm.target("active")),
        hsm.state("active", .{
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") })
        }),
        hsm.final("done") // Properly has no transitions
    });
    
    var built_model = try valid_model.build(testing.allocator);
    defer built_model.deinit();
    
    // Should validate without issues
    hsm.validate(&built_model) catch |err| {
        try testing.expect(false); // Should not error
        _ = err;
    };
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Transition to final state should work
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "done"));
    
    // Attempting to dispatch events to final state should have no effect
    // (the state machine should remain in the final state)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "any_event"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "done"));
}

test "Final state restrictions - no entry/exit actions" {
    // This test demonstrates that final states should not have entry/exit actions
    // In proper implementation, this would be enforced by validation
    
    const minimal_final_model = comptime hsm.define("MinimalFinalTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("end"), hsm.target("end") })
        }),
        hsm.final("end") // Final state with no actions
    });
    
    var built_model = try minimal_final_model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "end"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
}

test "Final state restrictions - no activities" {
    // This test verifies that final states cannot have activities
    // Activities are long-running operations that don't make sense in final states
    
    const simple_completion_model = comptime hsm.define("SimpleCompletionTest", .{
        hsm.initial(hsm.target("working")),
        hsm.state("working", .{
            hsm.transition(.{ hsm.on("complete"), hsm.target("completed") })
        }),
        hsm.final("completed") // No activities allowed
    });
    
    var built_model = try simple_completion_model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "complete"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "completed"));
}

test "Conditional transitions to final states" {
    const model = comptime hsm.define("ConditionalFinalTest", .{
        hsm.initial(hsm.target("evaluator")),
        hsm.state("evaluator", .{
            hsm.transition(.{ hsm.on("try_complete"), hsm.guard(shouldComplete), hsm.effect(completionEffect), hsm.target("success") }),
            hsm.transition(.{ hsm.on("try_complete"), hsm.effect(transitionAttemptEffect), hsm.target("retry") })
        }),
        hsm.state("retry", .{
            hsm.transition(.{ hsm.on("try_again"), hsm.target("../evaluator") })
        }),
        hsm.final("success")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // First attempt should succeed (guard passes)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "try_complete"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "success"));
    try testing.expect(instance.completion_count == 1);
    try testing.expect(instance.transition_attempts == 0);
    
    // Reset for second attempt test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = FinalStateTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();
    
    // Prime the completion counter to make guard fail
    instance2.recordCompletion("primed");
    
    // Second attempt should fail and go to retry
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "try_complete"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "retry"));
    try testing.expect(instance2.completion_count == 1); // Still just the priming
    try testing.expect(instance2.transition_attempts == 1);
}

test "Final states with complex completion workflows" {
    const model = comptime hsm.define("ComplexCompletionTest", .{
        hsm.initial(hsm.target("workflow")),
        hsm.state("workflow", .{
            hsm.initial(hsm.target("step1")),
            hsm.state("step1", .{
                hsm.transition(.{ hsm.on("next"), hsm.target("../step2") }),
                hsm.transition(.{ hsm.on("abort"), hsm.target("../../aborted") })
            }),
            hsm.state("step2", .{
                hsm.transition(.{ hsm.on("next"), hsm.target("../step3") }),
                hsm.transition(.{ hsm.on("back"), hsm.target("../step1") }),
                hsm.transition(.{ hsm.on("abort"), hsm.target("../../aborted") })
            }),
            hsm.state("step3", .{
                hsm.transition(.{ hsm.on("finish"), hsm.effect(successEffect), hsm.target("../../completed") }),
                hsm.transition(.{ hsm.on("back"), hsm.target("../step2") }),
                hsm.transition(.{ hsm.on("abort"), hsm.target("../../aborted") })
            })
        }),
        hsm.final("completed"),
        hsm.final("aborted")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test successful completion workflow
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        // Should start in workflow/step1
        try testing.expect(std.mem.endsWith(u8, sm.state(), "step1"));
        
        // Complete workflow: step1 -> step2 -> step3 -> completed
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "step2"));
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "step3"));
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "completed"));
        try testing.expect(instance.completion_count == 1);
        try testing.expectEqualStrings("success", instance.final_states_reached.items[0]);
    }
    
    // Test abort from step2
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next")); // to step2
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "abort"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "aborted"));
        try testing.expect(instance.completion_count == 0); // No completion effect
    }
    
    // Test back navigation then completion
    {
        var instance = FinalStateTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        // Navigate: step1 -> step2 -> step3 -> step2 -> step3 -> completed
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next")); // to step2
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next")); // to step3
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back")); // back to step2
        try testing.expect(std.mem.endsWith(u8, sm.state(), "step2"));
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next")); // to step3 again
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish")); // complete
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "completed"));
        try testing.expect(instance.completion_count == 1);
    }
}

test "Final states termination semantics" {
    const model = comptime hsm.define("TerminationSemanticsTest", .{
        hsm.initial(hsm.target("active")),
        hsm.state("active", .{
            hsm.transition(.{ hsm.on("terminate"), hsm.target("terminated") }),
            hsm.transition(.{ hsm.on("ignore_this"), hsm.effect(transitionAttemptEffect) }) // Internal
        }),
        hsm.final("terminated")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = FinalStateTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Before termination, events should be processed
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "ignore_this"));
    try testing.expect(instance.transition_attempts == 1);
    
    // Terminate the state machine
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "terminate"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "terminated"));
    
    // After termination, no further events should be processed
    // The state machine should remain in the final state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "ignore_this"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "any_event"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "terminate"));
    
    // Should still be in terminated state and no additional transitions processed
    try testing.expect(std.mem.endsWith(u8, sm.state(), "terminated"));
    try testing.expect(instance.transition_attempts == 1); // No additional attempts
}