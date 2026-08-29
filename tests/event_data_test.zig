const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for event data testing
const EventDataTestInstance = struct {
    base: hsm.Instance,
    received_values: std.ArrayList(i32),
    received_strings: std.ArrayList([]const u8),
    received_booleans: std.ArrayList(bool),
    data_access_count: i32,
    last_event_name: []const u8,
    complex_data: ?ComplexData,
    allocator: std.mem.Allocator,

    const Self = @This();

    const ComplexData = struct {
        id: u32,
        name: []const u8,
        active: bool,
        values: []f32,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .received_values = .{},
            .received_strings = .{},
            .received_booleans = .{},
            .data_access_count = 0,
            .last_event_name = "none",
            .complex_data = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.received_values.deinit(self.allocator);
        self.received_strings.deinit(self.allocator);
        self.received_booleans.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordValue(self: *Self, value: i32) void {
        self.received_values.append(self.allocator, value) catch unreachable;
        self.data_access_count += 1;
    }

    pub fn recordString(self: *Self, str: []const u8) void {
        self.received_strings.append(self.allocator, str) catch unreachable;
        self.data_access_count += 1;
    }

    pub fn recordBoolean(self: *Self, boolean: bool) void {
        self.received_booleans.append(self.allocator, boolean) catch unreachable;
        self.data_access_count += 1;
    }

    pub fn setLastEventName(self: *Self, name: []const u8) void {
        self.last_event_name = name;
    }

    pub fn setComplexData(self: *Self, data: ComplexData) void {
        self.complex_data = data;
    }
};

// Entry/Effect functions that access event data
fn integerDataEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setLastEventName(event.name);

    if (event.getData("value")) |data| {
        const value_ptr: *i32 = @ptrCast(@alignCast(data));
        test_inst.recordValue(value_ptr.*);
    }
}

fn stringDataEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setLastEventName(event.name);

    if (event.getData("message")) |data| {
        const str_ptr: *[]const u8 = @ptrCast(@alignCast(data));
        test_inst.recordString(str_ptr.*);
    }
}

fn booleanDataEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setLastEventName(event.name);

    if (event.getData("flag")) |data| {
        const bool_ptr: *bool = @ptrCast(@alignCast(data));
        test_inst.recordBoolean(bool_ptr.*);
    }
}

fn multiDataEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));

    if (event.getData("number")) |data| {
        const value_ptr: *i32 = @ptrCast(@alignCast(data));
        test_inst.recordValue(value_ptr.*);
    }

    if (event.getData("text")) |data| {
        const str_ptr: *[]const u8 = @ptrCast(@alignCast(data));
        test_inst.recordString(str_ptr.*);
    }

    if (event.getData("enabled")) |data| {
        const bool_ptr: *bool = @ptrCast(@alignCast(data));
        test_inst.recordBoolean(bool_ptr.*);
    }
}

fn complexDataEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));

    if (event.getData("complex")) |data| {
        const complex_ptr: *EventDataTestInstance.ComplexData = @ptrCast(@alignCast(data));
        test_inst.setComplexData(complex_ptr.*);
    }
}

// Guard functions that use event data
fn valueGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = inst;

    if (event.getData("threshold")) |data| {
        const threshold_ptr: *i32 = @ptrCast(@alignCast(data));
        if (event.getData("value")) |value_data| {
            const value_ptr: *i32 = @ptrCast(@alignCast(value_data));
            return value_ptr.* > threshold_ptr.*;
        }
    }

    return false;
}

fn stringLengthGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = inst;

    if (event.getData("text")) |data| {
        const str_ptr: *[]const u8 = @ptrCast(@alignCast(data));
        return str_ptr.*.len > 5;
    }

    return false;
}

test "Basic event data types - integers, strings, booleans" {
    const model = comptime hsm.define("BasicDataTest", .{ hsm.initial(hsm.target("waiting")), hsm.state("waiting", .{ hsm.transition(.{ hsm.on("int_event"), hsm.target("int_state") }), hsm.transition(.{ hsm.on("string_event"), hsm.target("string_state") }), hsm.transition(.{ hsm.on("bool_event"), hsm.target("bool_state") }) }), hsm.state("int_state", .{hsm.entry(integerDataEntry)}), hsm.state("string_state", .{hsm.entry(stringDataEntry)}), hsm.state("bool_state", .{hsm.entry(booleanDataEntry)}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test integer data
    var int_value: i32 = 42;
    var int_event = hsm.Event.withData(testing.allocator, "int_event");
    defer int_event.deinit();
    try int_event.putData("value", &int_value);

    try sm.dispatch(&context, int_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "int_state"));
    try testing.expectEqualStrings("int_event", instance.last_event_name);
    try testing.expect(instance.received_values.items.len == 1);
    try testing.expect(instance.received_values.items[0] == 42);

    // Reset for string test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = EventDataTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Test string data
    var string_value: []const u8 = "Hello, World!";
    var string_event = hsm.Event.withData(testing.allocator, "string_event");
    defer string_event.deinit();
    try string_event.putData("message", @ptrCast(&string_value));

    try sm2.dispatch(&context, string_event);
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "string_state"));
    try testing.expectEqualStrings("string_event", instance2.last_event_name);
    try testing.expect(instance2.received_strings.items.len == 1);
    try testing.expectEqualStrings("Hello, World!", instance2.received_strings.items[0]);

    // Reset for boolean test
    var built_model3 = try model.build(testing.allocator);
    defer built_model3.deinit();
    var instance3 = EventDataTestInstance.init(testing.allocator);
    defer instance3.deinit();
    var sm3 = try hsm.start(&context, &instance3, &built_model3);
    defer sm3.deinit();

    // Test boolean data
    var bool_value: bool = true;
    var bool_event = hsm.Event.withData(testing.allocator, "bool_event");
    defer bool_event.deinit();
    try bool_event.putData("flag", &bool_value);

    try sm3.dispatch(&context, bool_event);
    try testing.expect(std.mem.endsWith(u8, sm3.state(), "bool_state"));
    try testing.expectEqualStrings("bool_event", instance3.last_event_name);
    try testing.expect(instance3.received_booleans.items.len == 1);
    try testing.expect(instance3.received_booleans.items[0] == true);
}

test "Multiple data fields in single event" {
    const model = comptime hsm.define("MultiDataTest", .{ hsm.initial(hsm.target("processor")), hsm.state("processor", .{hsm.transition(.{ hsm.on("multi_data"), hsm.effect(multiDataEffect), hsm.target("result") })}), hsm.state("result", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Event with multiple data fields
    var number_value: i32 = 123;
    var text_value: []const u8 = "Multi-field event";
    var enabled_value: bool = false;

    var multi_event = hsm.Event.withData(testing.allocator, "multi_data");
    defer multi_event.deinit();
    try multi_event.putData("number", &number_value);
    try multi_event.putData("text", @ptrCast(&text_value));
    try multi_event.putData("enabled", &enabled_value);

    try sm.dispatch(&context, multi_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "result"));

    // All data should be accessed
    try testing.expect(instance.received_values.items.len == 1);
    try testing.expect(instance.received_strings.items.len == 1);
    try testing.expect(instance.received_booleans.items.len == 1);
    try testing.expect(instance.received_values.items[0] == 123);
    try testing.expectEqualStrings("Multi-field event", instance.received_strings.items[0]);
    try testing.expect(instance.received_booleans.items[0] == false);
    try testing.expect(instance.data_access_count == 3);
}

test "Complex structured data in events" {
    const model = comptime hsm.define("ComplexDataTest", .{ hsm.initial(hsm.target("waiting")), hsm.state("waiting", .{hsm.transition(.{ hsm.on("complex_event"), hsm.effect(complexDataEffect), hsm.target("processed") })}), hsm.state("processed", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Create complex data structure
    var values = [_]f32{ 1.1, 2.2, 3.3, 4.4 };
    var complex_data = EventDataTestInstance.ComplexData{
        .id = 12345,
        .name = "Complex Object",
        .active = true,
        .values = &values,
    };

    var complex_event = hsm.Event.withData(testing.allocator, "complex_event");
    defer complex_event.deinit();
    try complex_event.putData("complex", &complex_data);

    try sm.dispatch(&context, complex_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "processed"));

    // Verify complex data was received correctly
    try testing.expect(instance.complex_data != null);
    const received = instance.complex_data.?;
    try testing.expect(received.id == 12345);
    try testing.expectEqualStrings("Complex Object", received.name);
    try testing.expect(received.active == true);
    try testing.expect(received.values.len == 4);
    try testing.expect(received.values[0] == 1.1);
    try testing.expect(received.values[3] == 4.4);
}

test "Event data in guard conditions" {
    const model = comptime hsm.define("GuardDataTest", .{ hsm.initial(hsm.target("evaluator")), hsm.state("evaluator", .{ hsm.transition(.{ hsm.on("check_value"), hsm.guard(valueGuard), hsm.target("above_threshold") }), hsm.transition(.{ hsm.on("check_value"), hsm.target("below_threshold") }), hsm.transition(.{ hsm.on("check_string"), hsm.guard(stringLengthGuard), hsm.target("long_string") }), hsm.transition(.{ hsm.on("check_string"), hsm.target("short_string") }) }), hsm.state("above_threshold", .{}), hsm.state("below_threshold", .{}), hsm.state("long_string", .{}), hsm.state("short_string", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);

    // Test value guard - above threshold
    {
        var instance = EventDataTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var value: i32 = 15;
        var threshold: i32 = 10;
        var event = hsm.Event.withData(testing.allocator, "check_value");
        defer event.deinit();
        try event.putData("value", &value);
        try event.putData("threshold", &threshold);

        try sm.dispatch(&context, event);
        try testing.expect(std.mem.endsWith(u8, sm.state(), "above_threshold"));
    }

    // Test value guard - below threshold
    {
        var instance = EventDataTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var value: i32 = 5;
        var threshold: i32 = 10;
        var event = hsm.Event.withData(testing.allocator, "check_value");
        defer event.deinit();
        try event.putData("value", &value);
        try event.putData("threshold", &threshold);

        try sm.dispatch(&context, event);
        try testing.expect(std.mem.endsWith(u8, sm.state(), "below_threshold"));
    }

    // Test string length guard - long string
    {
        var instance = EventDataTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var text: []const u8 = "This is a long string";
        var event = hsm.Event.withData(testing.allocator, "check_string");
        defer event.deinit();
        try event.putData("text", @ptrCast(&text));

        try sm.dispatch(&context, event);
        try testing.expect(std.mem.endsWith(u8, sm.state(), "long_string"));
    }

    // Test string length guard - short string
    {
        var instance = EventDataTestInstance.init(testing.allocator);
        defer instance.deinit();
        var sm = try hsm.start(&context, &instance, &built_model);
        defer sm.deinit();

        var text: []const u8 = "Hi";
        var event = hsm.Event.withData(testing.allocator, "check_string");
        defer event.deinit();
        try event.putData("text", @ptrCast(&text));

        try sm.dispatch(&context, event);
        try testing.expect(std.mem.endsWith(u8, sm.state(), "short_string"));
    }
}

test "Event data propagation through state hierarchy" {
    const hierarchyDataEntry = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));

            if (event.getData("level")) |data| {
                const level_ptr: *i32 = @ptrCast(@alignCast(data));
                test_inst.recordValue(level_ptr.*);
            }
        }
    }.func;

    const model = comptime hsm.define("HierarchyDataTest", .{ hsm.initial(hsm.target("parent")), hsm.state("parent", .{ hsm.entry(hierarchyDataEntry), hsm.initial(hsm.target("child")), hsm.state("child", .{ hsm.entry(hierarchyDataEntry), hsm.initial(hsm.target("grandchild")), hsm.state("grandchild", .{ hsm.entry(hierarchyDataEntry), hsm.transition(.{ hsm.on("data_event"), hsm.effect(hierarchyDataEntry), hsm.target("../../other_child") }) }) }), hsm.state("other_child", .{hsm.entry(hierarchyDataEntry)}) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    // Start with initial event data (simulated)
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should be in parent/child/grandchild but no data received yet (no initial event)
    try testing.expect(std.mem.endsWith(u8, sm.state(), "grandchild"));
    try testing.expect(instance.received_values.items.len == 0);

    // Dispatch event with data - should be available to effect function
    var level_value: i32 = 99;
    var data_event = hsm.Event.withData(testing.allocator, "data_event");
    defer data_event.deinit();
    try data_event.putData("level", &level_value);

    try sm.dispatch(&context, data_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "other_child"));

    // Effect function should have accessed the data, plus entry function
    try testing.expect(instance.received_values.items.len == 2);
    try testing.expect(instance.received_values.items[0] == 99); // Effect
    try testing.expect(instance.received_values.items[1] == 99); // Entry
}

test "Event data modification and chaining" {
    var counter: i32 = 0;

    const ChainEffect = struct {
        var count: *i32 = undefined;

        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));

            if (event.getData("chain_value")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                const new_value = value_ptr.* + count.*;
                test_inst.recordValue(new_value);
                count.* += 1;
            }
        }
    };

    ChainEffect.count = &counter;

    const model = comptime hsm.define("ChainDataTest", .{ hsm.initial(hsm.target("chain_start")), hsm.state("chain_start", .{hsm.transition(.{ hsm.on("chain"), hsm.effect(.{ ChainEffect.func, ChainEffect.func, ChainEffect.func }), hsm.target("chain_end") })}), hsm.state("chain_end", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    var chain_value: i32 = 10;
    var chain_event = hsm.Event.withData(testing.allocator, "chain");
    defer chain_event.deinit();
    try chain_event.putData("chain_value", &chain_value);

    try sm.dispatch(&context, chain_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "chain_end"));

    // Should have recorded: 10+0=10, 10+1=11, 10+2=12
    try testing.expect(instance.received_values.items.len == 3);
    try testing.expect(instance.received_values.items[0] == 10);
    try testing.expect(instance.received_values.items[1] == 11);
    try testing.expect(instance.received_values.items[2] == 12);
    try testing.expect(counter == 3);
}

test "Event data with null and missing fields" {
    const SafeDataAccess = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *EventDataTestInstance = @ptrCast(@alignCast(inst));

            // Try to access non-existent field
            if (event.getData("missing_field")) |_| {
                test_inst.recordValue(999); // Should not happen
            } else {
                test_inst.recordValue(-1); // Default value
            }

            // Try to access existing field
            if (event.getData("present_field")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                test_inst.recordValue(value_ptr.*);
            } else {
                test_inst.recordValue(-2); // Should not happen
            }
        }
    }.func;

    const model = comptime hsm.define("SafeDataTest", .{ hsm.initial(hsm.target("safe_state")), hsm.state("safe_state", .{hsm.transition(.{ hsm.on("safe_event"), hsm.effect(SafeDataAccess), hsm.target("result") })}), hsm.state("result", .{}) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = EventDataTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Event with only one field present
    var present_value: i32 = 42;
    var safe_event = hsm.Event.withData(testing.allocator, "safe_event");
    defer safe_event.deinit();
    try safe_event.putData("present_field", &present_value);

    try sm.dispatch(&context, safe_event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "result"));

    // Should have recorded -1 (missing field) and 42 (present field)
    try testing.expect(instance.received_values.items.len == 2);
    try testing.expect(instance.received_values.items[0] == -1);
    try testing.expect(instance.received_values.items[1] == 42);
}
