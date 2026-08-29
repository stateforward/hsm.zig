const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for tracking entry function calls
const EntryTestInstance = struct {
    base: hsm.Instance,
    entry_count: i32,
    entry_sequence: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .entry_count = 0,
            .entry_sequence = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entry_sequence.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordEntry(self: *Self, name: []const u8) void {
        self.entry_count += 1;
        self.entry_sequence.append(self.allocator, name) catch unreachable;
    }
};

// Single entry functions
fn firstEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("first");
}

fn secondEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("second");
}

fn thirdEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("third");
}

fn initializingEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("initializing");
}

fn setupEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("setup");
}

fn configureEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("configure");
}

test "Single entry function execution" {
    const model = comptime hsm.define("SingleEntryTest", .{ hsm.initial(hsm.target("state1")), hsm.state("state1", .{ hsm.entry(firstEntry), hsm.transition(.{ hsm.on("next"), hsm.target("state2") }) }), hsm.state("state2", .{hsm.entry(secondEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in state1 with firstEntry called
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state1"));
    try testing.expect(instance.entry_count == 1);
    try testing.expectEqualStrings("first", instance.entry_sequence.items[0]);

    // Transition to state2
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state2"));
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("second", instance.entry_sequence.items[1]);
}

test "Multiple entry functions execution order" {
    const model = comptime hsm.define("MultipleEntryTest", .{ hsm.initial(hsm.target("setup_state")), hsm.state("setup_state", .{ hsm.entry(.{ initializingEntry, setupEntry, configureEntry }), hsm.transition(.{ hsm.on("ready"), hsm.target("running_state") }) }), hsm.state("running_state", .{hsm.entry(.{ firstEntry, secondEntry })}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in setup_state with all three entry functions called in order
    try testing.expect(std.mem.endsWith(u8, sm.state(), "setup_state"));
    try testing.expect(instance.entry_count == 3);
    try testing.expectEqualStrings("initializing", instance.entry_sequence.items[0]);
    try testing.expectEqualStrings("setup", instance.entry_sequence.items[1]);
    try testing.expectEqualStrings("configure", instance.entry_sequence.items[2]);

    // Transition to running_state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "ready"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "running_state"));
    try testing.expect(instance.entry_count == 5); // 3 + 2 more
    try testing.expectEqualStrings("first", instance.entry_sequence.items[3]);
    try testing.expectEqualStrings("second", instance.entry_sequence.items[4]);
}

test "Entry functions with event data access" {
    var test_data: i32 = 42;

    const dataEntry = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordEntry("data_entry");

            // Try to access event data
            if (event.getData("test_value")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                if (value_ptr.* == 42) {
                    test_inst.recordEntry("data_correct");
                }
            }
        }
    }.func;

    const model = comptime hsm.define("EntryDataTest", .{ hsm.initial(hsm.target("start")), hsm.state("start", .{hsm.transition(.{ hsm.on("with_data"), hsm.target("data_state") })}), hsm.state("data_state", .{hsm.entry(dataEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Create event with data
    var event = hsm.Event.withData(testing.allocator, "with_data");
    defer event.deinit();
    try event.putData("test_value", &test_data);

    try sm.dispatch(&context, event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "data_state"));
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("data_entry", instance.entry_sequence.items[0]);
    try testing.expectEqualStrings("data_correct", instance.entry_sequence.items[1]);
}

test "Entry functions in hierarchical states" {
    const model = comptime hsm.define("HierarchicalEntryTest", .{ hsm.initial(hsm.target("parent")), hsm.state("parent", .{ hsm.entry(firstEntry), hsm.initial(hsm.target("child")), hsm.state("child", .{ hsm.entry(secondEntry), hsm.transition(.{ hsm.on("next"), hsm.target("../sibling") }) }), hsm.state("sibling", .{hsm.entry(thirdEntry)}) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child with both entry functions called
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("first", instance.entry_sequence.items[0]); // parent entry
    try testing.expectEqualStrings("second", instance.entry_sequence.items[1]); // child entry

    // Transition to sibling (within same parent)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "sibling"));
    try testing.expect(instance.entry_count == 3); // Only sibling entry called (parent already active)
    try testing.expectEqualStrings("third", instance.entry_sequence.items[2]);
}

test "Entry functions with context cancellation check" {
    const cancelCheckEntry = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));

            if (ctx.is_done()) {
                test_inst.recordEntry("cancelled");
            } else {
                test_inst.recordEntry("normal");
            }
        }
    }.func;

    const model = comptime hsm.define("EntryCancellationTest", .{ hsm.initial(hsm.target("start")), hsm.state("start", .{ hsm.entry(cancelCheckEntry), hsm.transition(.{ hsm.on("next"), hsm.target("next_state") }) }), hsm.state("next_state", .{hsm.entry(cancelCheckEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // First entry should be normal
    try testing.expect(instance.entry_count == 1);
    try testing.expectEqualStrings("normal", instance.entry_sequence.items[0]);

    // Cancel context and transition
    context.cancel();
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));

    // Second entry should detect cancellation
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("cancelled", instance.entry_sequence.items[1]);
}

test "Entry functions exception handling" {
    var should_fail = false;

    const failingEntry = struct {
        var fail_flag: *bool = undefined;

        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            const test_inst: *EntryTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordEntry("before_fail");

            if (fail_flag.*) {
                test_inst.recordEntry("failing");
                // Note: In real implementation, this might cause an error event to be dispatched
                // For this test, we just record the attempt
            } else {
                test_inst.recordEntry("success");
            }
        }
    };

    failingEntry.fail_flag = &should_fail;

    const model = comptime hsm.define("EntryExceptionTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.entry(failingEntry.func),
            hsm.transition(.{ hsm.on("retry"), hsm.target(".") }), // Self transition
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EntryTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // First entry should succeed
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("before_fail", instance.entry_sequence.items[0]);
    try testing.expectEqualStrings("success", instance.entry_sequence.items[1]);

    // Set failure flag and retry
    should_fail = true;
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "retry"));

    // Should record the failure attempt
    try testing.expect(instance.entry_count == 4);
    try testing.expectEqualStrings("before_fail", instance.entry_sequence.items[2]);
    try testing.expectEqualStrings("failing", instance.entry_sequence.items[3]);
}
