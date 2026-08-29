const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test hierarchical state machine with nested states
const HierarchicalInstance = struct {
    base: hsm.Instance,
    enter_count: i32,
    exit_count: i32,
    level: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{
            .base = hsm.Instance.init(),
            .enter_count = 0,
            .exit_count = 0,
            .level = "none",
        };
    }

    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Entry/exit tracking functions
fn enterOuter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const h_inst: *HierarchicalInstance = @ptrCast(@alignCast(inst));
    h_inst.enter_count += 1;
    h_inst.level = "outer";
}

fn exitOuter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const h_inst: *HierarchicalInstance = @ptrCast(@alignCast(inst));
    h_inst.exit_count += 1;
}

fn enterInner(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const h_inst: *HierarchicalInstance = @ptrCast(@alignCast(inst));
    h_inst.enter_count += 1;
    h_inst.level = "inner";
}

fn exitInner(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const h_inst: *HierarchicalInstance = @ptrCast(@alignCast(inst));
    h_inst.exit_count += 1;
}

fn internalEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

test "Hierarchical state transitions" {
    const model = comptime hsm.define("HierarchicalTest", .{
        hsm.initial(hsm.target("outer")),

        hsm.state("outer", .{
            hsm.entry(enterOuter),
            hsm.exit(exitOuter),
            hsm.initial(hsm.target("inner1")),
            // Nested states
            hsm.state("inner1", .{ hsm.entry(enterInner), hsm.exit(exitInner), hsm.transition(.{ hsm.on("next"), hsm.target("../inner2") }) }),
            hsm.state("inner2", .{ hsm.entry(enterInner), hsm.exit(exitInner), hsm.transition(.{ hsm.on("back"), hsm.target("../inner1") }), hsm.transition(.{ hsm.on("out"), hsm.target("../../standalone") }) }),
            // Transition from outer level
            hsm.transition(.{ hsm.on("exit"), hsm.target("../standalone") }),
        }),

        hsm.state("standalone", .{hsm.transition(.{ hsm.on("enter"), hsm.target("../outer") })}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in outer/inner1
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner1"));
    try testing.expect(instance.enter_count == 2); // outer + inner1
    try testing.expect(instance.exit_count == 0);

    // Transition to inner2 (local transition within outer)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner2"));
    try testing.expect(instance.enter_count == 3); // + inner2
    try testing.expect(instance.exit_count == 1); // - inner1

    // Transition back to inner1
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner1"));
    try testing.expect(instance.enter_count == 4); // + inner1
    try testing.expect(instance.exit_count == 2); // - inner2

    // Transition from outer level (should bubble up)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "exit"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "standalone"));
    try testing.expect(instance.enter_count == 4); // no new entries
    try testing.expect(instance.exit_count == 4); // - inner1, - outer
}

test "Path resolution" {
    const model = comptime hsm.define("PathTest", .{ hsm.initial(hsm.target("level1")), hsm.state("level1", .{ hsm.initial(hsm.target("level2a")), hsm.state("level2a", .{ hsm.transition(.{ hsm.on("sibling"), hsm.target("../level2b") }), hsm.transition(.{ hsm.on("absolute"), hsm.target("/PathTest/level1/level2b") }), hsm.transition(.{ hsm.on("self"), hsm.target(".") }) }), hsm.state("level2b", .{ hsm.transition(.{ hsm.on("up"), hsm.target("../../other") }), hsm.transition(.{ hsm.on("down"), hsm.target("level3") }), hsm.state("level3", .{hsm.transition(.{ hsm.on("top"), hsm.target("/PathTest/other") })}) }) }), hsm.state("other", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in level2a
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level2a"));

    // Test sibling path
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "sibling"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level2b"));

    // Test going down to level3
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "down"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level3"));

    // Test absolute path
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "top"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "other"));
}

test "Self transitions" {
    const model = comptime hsm.define("SelfTest", .{
        hsm.initial(hsm.target("state1")),

        hsm.state("state1", .{
            hsm.entry(enterOuter),
            hsm.exit(exitOuter),
            hsm.transition(.{ hsm.on("self"), hsm.target(".") }),
            hsm.transition(.{ hsm.on("internal"), hsm.effect(internalEffect) }), // Internal transition
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    const initial_enters = instance.enter_count;
    const initial_exits = instance.exit_count;

    // Self transition should exit and re-enter
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "self"));
    try testing.expect(instance.enter_count == initial_enters + 1);
    try testing.expect(instance.exit_count == initial_exits + 1);

    // Internal transition should not exit/enter
    const before_internal_enters = instance.enter_count;
    const before_internal_exits = instance.exit_count;

    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "internal"));
    try testing.expect(instance.enter_count == before_internal_enters); // No new entries
    try testing.expect(instance.exit_count == before_internal_exits); // No new exits
}
