const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance with custom data
const TestInstance = struct {
    base: hsm.Instance,
    value: i32,
    flag: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{
            .base = hsm.Instance.init(),
            .value = 0,
            .flag = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Test action functions
fn incrementValue(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    test_inst.value += 1;
}

fn setFlag(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    test_inst.flag = true;
}

fn clearFlag(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    test_inst.flag = false;
}

fn checkValue(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    return test_inst.value >= 3;
}

test "Basic state machine functionality" {
    const model = comptime hsm.define("BasicTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.entry(setFlag),
            hsm.transition(.{ hsm.on("next"), hsm.effect(incrementValue), hsm.target("middle") })
        }),
        hsm.state("middle", .{
            hsm.entry(incrementValue),
            hsm.transition(.{ hsm.on("next"), hsm.effect(incrementValue), hsm.target("end") }),
            hsm.transition(.{ hsm.on("back"), hsm.target("../start") })
        }),
        hsm.final("end")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in start state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.flag == true); // Entry action should have run
    try testing.expect(instance.value == 0); // No value increment yet
    
    // Transition to middle
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "middle"));
    try testing.expect(instance.value == 2); // Effect + entry = 2 increments
    
    // Go back to start
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.flag == true); // Entry action should have run again
    
    // Go to middle again
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "middle"));
    
    // Go to end
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
}

test "Guard conditions" {
    const model = comptime hsm.define("GuardTest", .{
        hsm.initial(hsm.target("waiting")),
        hsm.state("waiting", .{
            hsm.transition(.{ hsm.on("check"), hsm.guard(checkValue), hsm.target("passed") }),
            hsm.transition(.{ hsm.on("check"), hsm.target("failed") }), // Fallback without guard
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementValue) }) // Internal transition
        }),
        hsm.state("passed", .{}),
        hsm.state("failed", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Initially value is 0, guard should fail
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "check"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "failed"));
    
    // Reset to waiting
    const model2 = comptime hsm.define("GuardTest2", .{
        hsm.initial(hsm.target("waiting")),
        hsm.state("waiting", .{
            hsm.transition(.{ hsm.on("check"), hsm.guard(checkValue), hsm.target("passed") }),
            hsm.transition(.{ hsm.on("check"), hsm.target("failed") }),
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementValue) })
        }),
        hsm.state("passed", .{}),
        hsm.state("failed", .{})
    });
    
    var built_model2 = try model2.build(testing.allocator);
    defer built_model2.deinit();
    try hsm.validate(&built_model2);
    
    var sm2 = try hsm.start(&context, &instance, &built_model2);
    defer sm2.deinit();
    
    // Increment value to satisfy guard
    for (0..4) |_| {
        try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "increment"));
    }
    try testing.expect(instance.value >= 3);
    
    // Now guard should pass
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "check"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "passed"));
}

test "Choice states" {
    const model = comptime hsm.define("ChoiceTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.transition(.{ hsm.on("decide"), hsm.target("decision") })
        }),
        hsm.choice("decision", .{
            hsm.transition(.{ hsm.guard(checkValue), hsm.target("../high") }),
            hsm.transition(.{ hsm.target("../low") }) // Guardless fallback
        }),
        hsm.state("high", .{}),
        hsm.state("low", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // With value 0, should go to low
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "decide"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "low"));
}

test "Multiple entry and exit actions" {
    const model = comptime hsm.define("MultiActionTest", .{
        hsm.initial(hsm.target("state1")),
        hsm.state("state1", .{
            hsm.entry(.{ setFlag, incrementValue }),
            hsm.exit(.{ clearFlag, incrementValue }),
            hsm.transition(.{ hsm.on("next"), hsm.target("state2") })
        }),
        hsm.state("state2", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Entry actions should have run
    try testing.expect(instance.flag == true);
    try testing.expect(instance.value == 1);
    
    // Transition to state2
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    
    // Exit actions should have run
    try testing.expect(instance.flag == false);
    try testing.expect(instance.value == 2);
}