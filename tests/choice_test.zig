const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for choice state testing
const ChoiceInstance = struct {
    base: hsm.Instance,
    value: i32,
    route_taken: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{
            .base = hsm.Instance.init(),
            .value = 0,
            .route_taken = "none",
        };
    }

    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Guard functions for choice states
fn isLow(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    return choice_inst.value < 10;
}

fn isMedium(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    return choice_inst.value >= 10 and choice_inst.value < 50;
}

fn isHigh(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    return choice_inst.value >= 50;
}

// Actions to mark which route was taken
fn markLow(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    choice_inst.route_taken = "low";
}

fn markMedium(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    choice_inst.route_taken = "medium";
}

fn markHigh(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    choice_inst.route_taken = "high";
}

fn markDefault(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));
    choice_inst.route_taken = "default";
}

fn setValue(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const choice_inst: *ChoiceInstance = @ptrCast(@alignCast(inst));

    // Extract value from event data if available
    if (event.getData("value")) |data| {
        const value_ptr: *i32 = @ptrCast(@alignCast(data));
        choice_inst.value = value_ptr.*;
    }
}

test "Choice state with multiple guards" {
    const model = comptime hsm.define("ChoiceTest", .{
        hsm.initial(hsm.target("input")),

        hsm.state("input", .{hsm.transition(.{ hsm.on("set_value"), hsm.effect(setValue), hsm.target("router") })}),

        hsm.choice("router", .{
            hsm.transition(.{ hsm.guard(isLow), hsm.effect(markLow), hsm.target("../low_state") }),
            hsm.transition(.{ hsm.guard(isMedium), hsm.effect(markMedium), hsm.target("../medium_state") }),
            hsm.transition(.{ hsm.guard(isHigh), hsm.effect(markHigh), hsm.target("../high_state") }),
            hsm.transition(.{ hsm.effect(markDefault), hsm.target("../default_state") }), // Guardless fallback
        }),

        hsm.state("low_state", .{}),
        hsm.state("medium_state", .{}),
        hsm.state("high_state", .{}),
        hsm.state("default_state", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);

    // Test low value routing
    {
        var instance = ChoiceInstance.init(testing.allocator);
        defer instance.deinit();

        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var low_value: i32 = 5;
        var event = hsm.Event.withData(testing.allocator, "set_value");
        defer event.deinit();
        try event.putData("value", &low_value);
        try sm.dispatch(&context, event);

        try testing.expect(std.mem.endsWith(u8, sm.state(), "low_state"));
        try testing.expectEqualStrings("low", instance.route_taken);
    }

    // Test medium value routing
    {
        var instance = ChoiceInstance.init(testing.allocator);
        defer instance.deinit();

        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var medium_value: i32 = 25;
        var event = hsm.Event.withData(testing.allocator, "set_value");
        defer event.deinit();
        try event.putData("value", &medium_value);
        try sm.dispatch(&context, event);

        try testing.expect(std.mem.endsWith(u8, sm.state(), "medium_state"));
        try testing.expectEqualStrings("medium", instance.route_taken);
    }

    // Test high value routing
    {
        var instance = ChoiceInstance.init(testing.allocator);
        defer instance.deinit();

        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var high_value: i32 = 75;
        var event = hsm.Event.withData(testing.allocator, "set_value");
        defer event.deinit();
        try event.putData("value", &high_value);
        try sm.dispatch(&context, event);

        try testing.expect(std.mem.endsWith(u8, sm.state(), "high_state"));
        try testing.expectEqualStrings("high", instance.route_taken);
    }
}

test "Choice state fallback behavior" {
    // Test with guards that all fail to verify fallback works
    const model = comptime hsm.define("FallbackTest", .{
        hsm.initial(hsm.target("start")),

        hsm.state("start", .{hsm.transition(.{ hsm.on("decide"), hsm.target("decision") })}),

        hsm.choice("decision", .{
            hsm.transition(.{ hsm.guard(isHigh), hsm.target("../success") }), // Will fail
            hsm.transition(.{hsm.target("../fallback")}), // Should be taken
        }),

        hsm.state("success", .{}),
        hsm.state("fallback", .{}),
    });

    var context = hsm.Context.init(testing.allocator);
    var instance = ChoiceInstance.init(testing.allocator);
    defer instance.deinit();

    // Set low value so isHigh guard will fail
    instance.value = 5;

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "decide"));

    // Should go to fallback since guard failed
    try testing.expect(std.mem.endsWith(u8, sm.state(), "fallback"));
}

test "Nested choice states" {
    const model = comptime hsm.define("NestedChoiceTest", .{ hsm.initial(hsm.target("container")), hsm.state("container", .{ hsm.initial(hsm.target("first_choice")), hsm.choice("first_choice", .{ hsm.transition(.{ hsm.guard(isLow), hsm.target("../second_choice") }), hsm.transition(.{hsm.target("../../outer_state")}) }), hsm.choice("second_choice", .{ hsm.transition(.{ hsm.guard(isLow), hsm.target("../inner_state") }), hsm.transition(.{hsm.target("../../outer_state")}) }), hsm.state("inner_state", .{}) }), hsm.state("outer_state", .{}) });

    var context = hsm.Context.init(testing.allocator);
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    // Test path through both choice states
    {
        var instance = ChoiceInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 5; // Low value

        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try testing.expect(std.mem.endsWith(u8, sm.state(), "inner_state"));
    }

    // Test path that exits at first choice
    {
        var instance = ChoiceInstance.init(testing.allocator);
        defer instance.deinit();
        instance.value = 50; // High value

        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        try testing.expect(std.mem.endsWith(u8, sm.state(), "outer_state"));
    }
}

// This test should fail compilation due to missing guardless transition
// Commented out as it causes intentional compile errors
// test "Choice without guardless fallback should fail validation" {
//     const model = comptime hsm.define("InvalidChoice", .{
//         hsm.initial(hsm.target("start")),
//         hsm.state("start", .{
//             hsm.transition(.{ hsm.on("decide"), hsm.target("decision") })
//         }),
//         hsm.choice("decision", .{
//             hsm.transition(.{ hsm.guard(isLow), hsm.target("../low") }),
//             hsm.transition(.{ hsm.guard(isHigh), hsm.target("../high") })
//             // Missing guardless fallback - should cause compile error
//         }),
//         hsm.state("low", .{}),
//         hsm.state("high", .{})
//     });
//
//     const built_model = try model.build(testing.allocator);
//     defer built_model.deinit();
//     try hsm.validate(&built_model); // This should cause compile error
// }
