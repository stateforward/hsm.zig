const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for tracking choice state behavior
const ChoiceTestInstance = struct {
    base: hsm.Instance,
    choice_route: []const u8,
    guard_evaluations: std.ArrayList([]const u8),
    value: i32,
    flag: bool,
    counter: i32,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .choice_route = "none",
            .guard_evaluations = std.ArrayList([]const u8).init(allocator),
            .value = 0,
            .flag = false,
            .counter = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.guard_evaluations.deinit();
        self.base.deinit();
    }
    
    pub fn recordGuardEvaluation(self: *Self, guard_name: []const u8) void {
        self.guard_evaluations.append(guard_name) catch unreachable;
    }
    
    pub fn setRoute(self: *Self, route: []const u8) void {
        self.choice_route = route;
    }
};

// Guard functions
fn lowValueGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardEvaluation("low_value");
    return test_inst.value < 10;
}

fn midValueGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardEvaluation("mid_value");
    return test_inst.value >= 10 and test_inst.value < 50;
}

fn highValueGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardEvaluation("high_value");
    return test_inst.value >= 50;
}

fn flagGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardEvaluation("flag");
    return test_inst.flag;
}

fn counterGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordGuardEvaluation("counter");
    return test_inst.counter > 0;
}

// Route marking functions
fn markLowRoute(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setRoute("low");
}

fn markMidRoute(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setRoute("mid");
}

fn markHighRoute(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setRoute("high");
}

fn markFallbackRoute(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setRoute("fallback");
}

fn setValue(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
    
    if (event.getData("value")) |data| {
        const value_ptr: *i32 = @ptrCast(@alignCast(data));
        test_inst.value = value_ptr.*;
    }
}

test "Basic choice state with guards" {
    const model = comptime hsm.define("BasicChoiceTest", .{
        hsm.initial(hsm.target("input")),
        hsm.state("input", .{
            hsm.transition(.{ hsm.on("set_value"), hsm.effect(setValue), hsm.target("decision") })
        }),
        hsm.choice("decision", .{
            hsm.transition(.{ hsm.guard(lowValueGuard), hsm.effect(markLowRoute), hsm.target("../low_state") }),
            hsm.transition(.{ hsm.guard(highValueGuard), hsm.effect(markHighRoute), hsm.target("../high_state") }),
            hsm.transition(.{ hsm.effect(markFallbackRoute), hsm.target("../fallback_state") }) // Guardless fallback
        }),
        hsm.state("low_state", .{}),
        hsm.state("high_state", .{}),
        hsm.state("fallback_state", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test low value routing
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        var low_value: i32 = 5;
        var event = hsm.Event.withData(testing.allocator, "set_value");
        defer event.deinit();
        try event.putData("value", &low_value);
        try sm.dispatch(&context, event);
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "low_state"));
        try testing.expectEqualStrings("low", instance.choice_route);
        try testing.expect(instance.guard_evaluations.items.len == 1);
        try testing.expectEqualStrings("low_value", instance.guard_evaluations.items[0]);
    }
    
    // Test high value routing
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        var high_value: i32 = 75;
        var event = hsm.Event.withData(testing.allocator, "set_value");
        defer event.deinit();
        try event.putData("value", &high_value);
        try sm.dispatch(&context, event);
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "high_state"));
        try testing.expectEqualStrings("high", instance.choice_route);
        // Should evaluate low_value (false), then high_value (true)
        try testing.expect(instance.guard_evaluations.items.len == 2);
        try testing.expectEqualStrings("low_value", instance.guard_evaluations.items[0]);
        try testing.expectEqualStrings("high_value", instance.guard_evaluations.items[1]);
    }
    
    // Test fallback routing
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 25; // Mid value, no guard will match
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "set_value"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "fallback_state"));
        try testing.expectEqualStrings("fallback", instance.choice_route);
        // Should evaluate both guards before falling back
        try testing.expect(instance.guard_evaluations.items.len == 2);
    }
}

test "Multiple choice states in sequence" {
    const model = comptime hsm.define("SequentialChoiceTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("begin"), hsm.target("first_choice") })
        }),
        hsm.choice("first_choice", .{
            hsm.transition(.{ hsm.guard(flagGuard), hsm.target("../second_choice") }),
            hsm.transition(.{ hsm.target("../direct_end") })
        }),
        hsm.choice("second_choice", .{
            hsm.transition(.{ hsm.guard(lowValueGuard), hsm.effect(markLowRoute), hsm.target("../low_end") }),
            hsm.transition(.{ hsm.effect(markFallbackRoute), hsm.target("../high_end") })
        }),
        hsm.state("direct_end", .{}),
        hsm.state("low_end", .{}),
        hsm.state("high_end", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test path through both choices
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = true;
        instance.value = 3; // Low value
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "begin"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "low_end"));
        try testing.expectEqualStrings("low", instance.choice_route);
        // Should evaluate flag (true), then low_value (true)
        try testing.expect(instance.guard_evaluations.items.len == 2);
        try testing.expectEqualStrings("flag", instance.guard_evaluations.items[0]);
        try testing.expectEqualStrings("low_value", instance.guard_evaluations.items[1]);
    }
    
    // Test direct path (bypass second choice)
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = false; // Will go direct
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "begin"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "direct_end"));
        try testing.expectEqualStrings("none", instance.choice_route); // No route marking
        try testing.expect(instance.guard_evaluations.items.len == 1);
        try testing.expectEqualStrings("flag", instance.guard_evaluations.items[0]);
    }
}

test "Choice states with complex guard combinations" {
    const model = comptime hsm.define("ComplexChoiceTest", .{
        hsm.initial(hsm.target("setup")),
        hsm.state("setup", .{
            hsm.transition(.{ hsm.on("evaluate"), hsm.target("complex_choice") })
        }),
        hsm.choice("complex_choice", .{
            hsm.transition(.{ hsm.guard(flagGuard), hsm.guard(lowValueGuard), hsm.effect(markLowRoute), hsm.target("../flag_and_low") }),
            hsm.transition(.{ hsm.guard(flagGuard), hsm.guard(highValueGuard), hsm.effect(markHighRoute), hsm.target("../flag_and_high") }),
            hsm.transition(.{ hsm.guard(counterGuard), hsm.effect(markMidRoute), hsm.target("../counter_state") }),
            hsm.transition(.{ hsm.effect(markFallbackRoute), hsm.target("../default_state") })
        }),
        hsm.state("flag_and_low", .{}),
        hsm.state("flag_and_high", .{}),
        hsm.state("counter_state", .{}),
        hsm.state("default_state", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test flag + low value combination
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = true;
        instance.value = 5;
        instance.counter = 0;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "flag_and_low"));
        try testing.expectEqualStrings("low", instance.choice_route);
    }
    
    // Test counter path (flag false, but counter > 0)
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = false;
        instance.value = 100;
        instance.counter = 5;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "counter_state"));
        try testing.expectEqualStrings("mid", instance.choice_route);
    }
}

test "Choice states in hierarchical structures" {
    const model = comptime hsm.define("HierarchicalChoiceTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("child_choice")),
            hsm.choice("child_choice", .{
                hsm.transition(.{ hsm.guard(flagGuard), hsm.target("../nested/deep_state") }),
                hsm.transition(.{ hsm.target("../simple_child") })
            }),
            hsm.state("nested", .{
                hsm.state("deep_state", .{
                    hsm.transition(.{ hsm.on("back"), hsm.target("../../parent_choice") })
                })
            }),
            hsm.state("simple_child", .{
                hsm.transition(.{ hsm.on("up"), hsm.target("../parent_choice") })
            }),
            hsm.choice("parent_choice", .{
                hsm.transition(.{ hsm.guard(lowValueGuard), hsm.target("../../other") }),
                hsm.transition(.{ hsm.target("../simple_child") })
            })
        }),
        hsm.state("other", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test nested choice with flag=true
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = true;
        instance.value = 5;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "deep_state"));
        
        // Navigate back to parent choice
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back"));
        
        // Should go to "other" due to low value
        try testing.expect(std.mem.endsWith(u8, sm.state(), "other"));
    }
    
    // Test simple path
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.flag = false;
        instance.value = 50;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "simple_child"));
        
        // Navigate to parent choice
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "up"));
        
        // Should stay in simple_child due to high value
        try testing.expect(std.mem.endsWith(u8, sm.state(), "simple_child"));
    }
}

test "Choice states with event data in guards" {
    var external_threshold: i32 = 25;
    
    const eventDataGuard = struct {
        var threshold: *i32 = undefined;
        
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
            _ = ctx;
            const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordGuardEvaluation("event_data");
            
            if (event.getData("threshold")) |data| {
                const threshold_ptr: *i32 = @ptrCast(@alignCast(data));
                return test_inst.value > threshold_ptr.*;
            }
            
            // Fallback to static threshold
            return test_inst.value > threshold.*;
        }
    }.func;
    
    eventDataGuard.threshold = &external_threshold;
    
    const model = comptime hsm.define("EventDataChoiceTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("check"), hsm.target("data_choice") })
        }),
        hsm.choice("data_choice", .{
            hsm.transition(.{ hsm.guard(eventDataGuard), hsm.effect(markHighRoute), hsm.target("../above_threshold") }),
            hsm.transition(.{ hsm.effect(markLowRoute), hsm.target("../below_threshold") })
        }),
        hsm.state("above_threshold", .{}),
        hsm.state("below_threshold", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test with event data threshold
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 30;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        var threshold_value: i32 = 20;
        var event = hsm.Event.withData(testing.allocator, "check");
        defer event.deinit();
        try event.putData("threshold", &threshold_value);
        
        try sm.dispatch(&context, event);
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "above_threshold"));
        try testing.expectEqualStrings("high", instance.choice_route);
    }
    
    // Test below threshold
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 15;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        var threshold_value: i32 = 20;
        var event = hsm.Event.withData(testing.allocator, "check");
        defer event.deinit();
        try event.putData("threshold", &threshold_value);
        
        try sm.dispatch(&context, event);
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "below_threshold"));
        try testing.expectEqualStrings("low", instance.choice_route);
    }
}

test "Choice states with context cancellation" {
    const cancelAwareGuard = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
            _ = event;
            const test_inst: *ChoiceTestInstance = @ptrCast(@alignCast(inst));
            
            if (ctx.is_done()) {
                test_inst.recordGuardEvaluation("cancelled");
                return false; // Don't proceed if cancelled
            } else {
                test_inst.recordGuardEvaluation("normal");
                return test_inst.value > 10;
            }
        }
    }.func;
    
    const model = comptime hsm.define("CancellationChoiceTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("evaluate"), hsm.target("cancel_choice") })
        }),
        hsm.choice("cancel_choice", .{
            hsm.transition(.{ hsm.guard(cancelAwareGuard), hsm.effect(markHighRoute), hsm.target("../success") }),
            hsm.transition(.{ hsm.effect(markFallbackRoute), hsm.target("../fallback") })
        }),
        hsm.state("success", .{}),
        hsm.state("fallback", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    
    // Test normal operation
    {
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 15;
        
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "evaluate"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "success"));
        try testing.expectEqualStrings("high", instance.choice_route);
        try testing.expect(instance.guard_evaluations.items.len == 1);
        try testing.expectEqualStrings("normal", instance.guard_evaluations.items[0]);
    }
    
    // Test with cancelled context
    {
        var cancelled_context = hsm.Context.init(testing.allocator);
        cancelled_context.cancel();
        
        var instance = ChoiceTestInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 15;
        
        var sm = try hsm.start(&cancelled_context, &instance, &built_model);
        defer sm.deinit();
        
        try sm.dispatch(&cancelled_context, hsm.Event.init(testing.allocator, "evaluate"));
        
        try testing.expect(std.mem.endsWith(u8, sm.state(), "fallback"));
        try testing.expectEqualStrings("fallback", instance.choice_route);
        try testing.expect(instance.guard_evaluations.items.len == 1);
        try testing.expectEqualStrings("cancelled", instance.guard_evaluations.items[0]);
    }
}