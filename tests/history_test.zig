const std = @import("std");
const hsm = @import("hsm");
const testing = std.testing;

// Test instance
const TestInstance = struct {
    base: hsm.Instance,
    allocator: std.mem.Allocator,
    log: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .base = hsm.Instance.init(),
            .allocator = allocator,
            .log = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.log.items) |msg| {
            self.allocator.free(msg);
        }
        self.log.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn addLog(self: *Self, msg: []const u8) !void {
        try self.log.append(self.allocator, try self.allocator.dupe(u8, msg));
    }
};

fn logAction(comptime msg: []const u8) fn (ctx: *hsm.Context, inst: *TestInstance, event: hsm.Event) void {
    return struct {
        fn func(ctx: *hsm.Context, inst: *TestInstance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            inst.addLog(msg) catch {};
        }
    }.func;
}

fn historyGuard(ctx: *hsm.Context, inst: *TestInstance, event: hsm.Event) bool {
    _ = ctx;
    _ = inst;
    _ = event;
    return true;
}

test "history default transition guards and effects are native DSL" {
    const model = hsm.define("HistoryDefaultDsl", .{
        hsm.initial(hsm.target("outside")),
        hsm.state("parent", .{
            hsm.history("h", .{
                hsm.transition(.{ hsm.guard(historyGuard), hsm.effect(logAction("effect_1")), hsm.target("child") }),
                hsm.transition(.{ hsm.effect(logAction("effect_2")), hsm.target("child") }),
            }),
            hsm.state("child", .{hsm.entry(logAction("entry_child"))}),
        }),
        hsm.state("outside", .{
            hsm.transition(.{ hsm.on("enter"), hsm.target("parent/h") }),
        }),
    });

    var context = hsm.Context.init(testing.allocator);
    var instance = try TestInstance.init(testing.allocator);
    defer instance.deinit();
    var machine = try hsm.start(&context, &instance, model);
    defer machine.deinit();

    try machine.dispatch(&context, hsm.Event.init(testing.allocator, "enter"));
    try testing.expectEqualStrings("/HistoryDefaultDsl/parent/child", machine.state());
    try testing.expectEqual(@as(usize, 2), instance.log.items.len);
    try testing.expectEqualStrings("effect_1", instance.log.items[0]);
    try testing.expectEqualStrings("entry_child", instance.log.items[1]);
}

test "history state restoration" {
    const model = hsm.define("HistoryMachine", .{
        hsm.initial(hsm.target("parent")),

        hsm.state("parent", .{
            hsm.initial(hsm.target("child1")),
            hsm.history("H", hsm.target("child1")),
            hsm.state("child1", .{
                hsm.entry(logAction("enter_child1")),
                hsm.exit(logAction("exit_child1")),
                hsm.transition(.{
                    hsm.on("next"),
                    hsm.target("child2"),
                }),
            }),
            hsm.state("child2", .{
                hsm.entry(logAction("enter_child2")),
                hsm.exit(logAction("exit_child2")),
            }),
            hsm.transition(.{
                hsm.on("exit_parent"),
                hsm.target("outside"),
            }),
        }),

        hsm.state("outside", .{
            hsm.entry(logAction("enter_outside")),
            hsm.transition(.{
                hsm.on("back_history"),
                hsm.target("parent/H"),
            }),
            hsm.transition(.{
                hsm.on("back_default"),
                hsm.target("parent"), // Should go to initial (child1)
            }),
        }),
    });

    var context = hsm.Context.init(testing.allocator);
    var instance = try TestInstance.init(testing.allocator);
    defer instance.deinit();

    // Build and start
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var sm = try hsm.start(&context, &instance, model);
    defer sm.deinit();

    // Initial state: child1
    try testing.expectEqualStrings("/HistoryMachine/parent/child1", sm.state());

    // Move to child2
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expectEqualStrings("/HistoryMachine/parent/child2", sm.state());

    // Exit parent to outside (remembers child2 in history)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "exit_parent"));
    try testing.expectEqualStrings("/HistoryMachine/outside", sm.state());

    // Return via history -> should go to child2
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back_history"));
    try testing.expectEqualStrings("/HistoryMachine/parent/child2", sm.state());

    // Exit again
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "exit_parent"));

    // Return via default entry -> should go to child1 (initial)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back_default"));
    try testing.expectEqualStrings("/HistoryMachine/parent/child1", sm.state());
}

test "deep history restores the active nested leaf while shallow history follows initial" {
    const model = hsm.define("DeepHistoryMachine", .{
        hsm.initial(hsm.target("A")),
        hsm.state("A", .{
            hsm.initial(hsm.target("A1")),
            hsm.state("A1", .{
                hsm.initial(hsm.target("A1a")),
                hsm.state("A1a", .{}),
                hsm.state("A1b", .{}),
            }),
            hsm.state("A2", .{}),
            hsm.history("shallow", hsm.target("A1")),
            hsm.deepHistory("deep", hsm.target("A1")),
            hsm.transition(.{ hsm.source("A1/A1a"), hsm.on("to_leaf"), hsm.target("A1/A1b") }),
            hsm.transition(.{ hsm.source("A1/A1b"), hsm.on("to_b"), hsm.target("../B") }),
        }),
        hsm.state("B", .{
            hsm.transition(.{ hsm.on("back_deep"), hsm.target("../A/deep") }),
            hsm.transition(.{ hsm.on("back_shallow"), hsm.target("../A/shallow") }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = try TestInstance.init(testing.allocator);
    defer instance.deinit();
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    try testing.expectEqualStrings("/DeepHistoryMachine/A/A1/A1a", sm.state());
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_leaf"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_b"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back_deep"));
    try testing.expectEqualStrings("/DeepHistoryMachine/A/A1/A1b", sm.state());

    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_b"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back_shallow"));
    try testing.expectEqualStrings("/DeepHistoryMachine/A/A1/A1a", sm.state());
}
