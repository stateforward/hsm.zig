const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

test "canonical kind hierarchy and native structural element type" {
    const structural_type: hsm.ElementType = .state;
    const canonical_kinds = [_]u64{
        hsm.NullKind,
        hsm.ElementKind,
        hsm.PartialKind,
        hsm.VertexKind,
        hsm.ConstraintKind,
        hsm.BehaviorKind,
        hsm.NamespaceKind,
        hsm.ConcurrentKind,
        hsm.SequentialKind,
        hsm.StateMachineKind,
        hsm.AttributeKind,
        hsm.OperationKind,
        hsm.StateKind,
        hsm.SubmachineStateKind,
        hsm.ModelKind,
        hsm.TransitionKind,
        hsm.InternalKind,
        hsm.ExternalKind,
        hsm.LocalKind,
        hsm.SelfKind,
        hsm.EventKind,
        hsm.CompletionEventKind,
        hsm.ChangeEventKind,
        hsm.ErrorEventKind,
        hsm.TimeEventKind,
        hsm.CallEventKind,
        hsm.PseudostateKind,
        hsm.InitialKind,
        hsm.EntryPointKind,
        hsm.ExitPointKind,
        hsm.FinalStateKind,
        hsm.ChoiceKind,
        hsm.JunctionKind,
        hsm.DeepHistoryKind,
        hsm.ShallowHistoryKind,
        hsm.ObservationKind,
        hsm.RegionKind,
        hsm.CustomKind,
    };
    const canonical_ids = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 21, 22, 18, 19, 24, 20, 23, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37 };

    try testing.expectEqual(hsm.ElementType.state, structural_type);
    try testing.expectEqual(canonical_ids.len, canonical_kinds.len);
    for (canonical_kinds, canonical_ids) |kind, id| {
        try testing.expectEqual(id, @as(u8, @truncate(kind)));
    }
    try testing.expect(@TypeOf(hsm.ElementKind) == u64);
    try testing.expect(hsm.IsKind(hsm.NullKind, hsm.NullKind));
    try testing.expect(!hsm.IsKind(hsm.ElementKind, hsm.NullKind));
    try testing.expect(hsm.IsKind(hsm.ElementKind, hsm.ElementKind));
    try testing.expect(hsm.IsKind(hsm.StateKind, hsm.VertexKind));
    try testing.expect(hsm.IsKind(hsm.StateKind, hsm.NamespaceKind));
    try testing.expect(hsm.IsKind(hsm.StateKind, hsm.ElementKind));
    try testing.expect(hsm.IsKind(hsm.StateMachineKind, hsm.ConcurrentKind));
    try testing.expect(hsm.IsKind(hsm.StateMachineKind, hsm.NamespaceKind));
    try testing.expect(hsm.IsKind(hsm.StateMachineKind, hsm.BehaviorKind));
    try testing.expect(hsm.IsKind(hsm.StateMachineKind, hsm.ElementKind));
    try testing.expect(hsm.IsKind(hsm.ErrorEventKind, hsm.CompletionEventKind));
    try testing.expect(hsm.IsKind(hsm.ErrorEventKind, hsm.EventKind));
    try testing.expect(hsm.IsKind(hsm.ErrorEventKind, hsm.ElementKind));
    try testing.expect(hsm.IsKind(hsm.ChoiceKind, hsm.PseudostateKind));
    try testing.expect(hsm.IsKind(hsm.ChoiceKind, hsm.VertexKind));
    try testing.expect(hsm.IsKind(hsm.ChoiceKind, hsm.ElementKind));
    try testing.expect(!hsm.IsKind(hsm.ChoiceKind, hsm.StateKind));
    try testing.expect(hsm.IsKind(hsm.RegionKind, hsm.ElementKind));
    try testing.expect(hsm.IsKind(hsm.CustomKind, hsm.ElementKind));
    try testing.expectEqual(@as(u64, 274), hsm.EventKind);
    try testing.expectEqual(@as(u8, 18), @as(u8, @truncate(hsm.EventKind)));
    try testing.expectEqual(@as(u8, 23), @as(u8, @truncate(hsm.TimeEventKind)));
    try testing.expectEqual(@as(u8, 24), @as(u8, @truncate(hsm.ChangeEventKind)));
    try testing.expectEqual(@as(u8, 25), @as(u8, @truncate(hsm.CallEventKind)));
}

test "typed model lookup rejects mismatched member kinds" {
    var model = try hsm.createModel(testing.allocator, "TypedLookupParity");
    defer model.deinit();

    const state = try hsm.addState(&model, "/TypedLookupParity/state", .state);
    try testing.expectEqual(state, hsm.get(hsm.StateElement, &model, state.element.qualified_name));
    try testing.expectEqual(state, hsm.getState(&model, state.element.qualified_name));
    try testing.expect(hsm.get(hsm.TransitionElement, &model, state.element.qualified_name) == null);
    try testing.expect(hsm.get(hsm.BehaviorElement, &model, state.element.qualified_name) == null);

    const malformed_key = try testing.allocator.dupe(u8, "/TypedLookupParity/malformed");
    var malformed_key_owned = true;
    defer if (malformed_key_owned) testing.allocator.free(malformed_key);
    try model.members.put(malformed_key, @ptrCast(state));
    malformed_key_owned = false;
    try testing.expect(hsm.get(hsm.TransitionElement, &model, malformed_key) == null);
    try testing.expectEqual(state, hsm.getState(&model, malformed_key));
}

test "canonical runtime event helpers use shared names and kinds" {
    var initial = hsm.InitialEvent(testing.allocator);
    defer initial.deinit();
    var final = hsm.FinalEvent(testing.allocator);
    defer final.deinit();
    var error_event = hsm.ErrorEvent(testing.allocator);
    defer error_event.deinit();

    try testing.expectEqualStrings(hsm.InitialEventName, initial.name);
    try testing.expectEqual(hsm.CompletionEventKind, initial.kind);
    try testing.expectEqualStrings(hsm.FinalEventName, final.name);
    try testing.expectEqual(hsm.CompletionEventKind, final.kind);
    try testing.expectEqualStrings(hsm.ErrorEventName, error_event.name);
    try testing.expectEqual(hsm.ErrorEventKind, error_event.kind);
}

test "transition subtype builders infer and preserve canonical kinds" {
    const model = comptime hsm.define("TransitionSubtypeParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on("internal"), hsm.effect(observedEffect) }),
            hsm.transition(.{ hsm.TransitionType(hsm.SelfKind), hsm.on("self"), hsm.target(".") }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    const internal_element = built_model.members.get("/TransitionSubtypeParity/idle/transition_0").?;
    const self_element = built_model.members.get("/TransitionSubtypeParity/idle/transition_1").?;
    const internal_transition: *const hsm.TransitionElement = @ptrCast(@alignCast(internal_element));
    const self_transition: *const hsm.TransitionElement = @ptrCast(@alignCast(self_element));
    try testing.expectEqual(hsm.InternalKind, internal_transition.kind);
    try testing.expectEqual(hsm.SelfKind, self_transition.kind);

    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    var snapshot = try machine.TakeSnapshot();
    defer snapshot.deinit();
    var saw_internal = false;
    var saw_self = false;
    for (snapshot.Transitions) |transition_snapshot| {
        saw_internal = saw_internal or transition_snapshot.Kind == hsm.InternalKind;
        saw_self = saw_self or transition_snapshot.Kind == hsm.SelfKind;
    }
    try testing.expect(saw_internal);
    try testing.expect(saw_self);
}

const TestInstance = struct {
    base: hsm.Instance,
    entries: usize = 0,
    exits: usize = 0,

    fn init() TestInstance {
        return .{ .base = hsm.Instance.init() };
    }

    fn deinit(self: *TestInstance) void {
        self.base.deinit();
    }
};

fn parityClockNow(context: ?*anyopaque) u64 {
    _ = context;
    return 123456;
}

var model_validator_calls: usize = 0;
var model_finalizer_calls: usize = 0;
var custom_validator_completed: bool = false;
var custom_finalizer_saw_unindexed_model: bool = false;
var custom_finalizer_saw_validated_model: bool = false;
var observed_behavior_calls: usize = 0;
var observed_event_calls: usize = 0;
var observed_effect_calls: usize = 0;
var last_behavior_source: []const u8 = "";
var last_event_source: []const u8 = "";
var initial_effect_calls: usize = 0;
var initial_effect_order: [2]u8 = .{ 0, 0 };
var initial_entry_event_calls: usize = 0;
var initial_entry_event_matches: bool = false;
var submachine_boundary_activity_runs = std.atomic.Value(u32).init(0);
var observation_validator_saw_generated_member: bool = false;
var last_validator_marker: u8 = 0;
var different_finalizer_model: hsm.Model = undefined;
var queued_attribute_machine: ?*hsm.StateMachine = null;
var queued_attribute_old_values: [5]i32 = .{ -1, -1, -1, -1, -1 };
var queued_attribute_new_values: [5]i32 = .{ -1, -1, -1, -1, -1 };
var queued_attribute_events: usize = 0;
var deferred_attribute_machine: ?*hsm.StateMachine = null;
var deferred_attribute_old_value: i32 = -1;
var deferred_attribute_new_value: i32 = -1;
var deferred_attribute_events: usize = 0;
var typed_payload_machine: ?*hsm.StateMachine = null;
var typed_payload_attribute_value: i32 = 7;
var typed_payload_call_args: i32 = 42;
var typed_attribute_change_seen: bool = false;
var typed_attribute_change_name: []const u8 = "";
var typed_attribute_change_old_value: i32 = -1;
var typed_attribute_change_new_value: i32 = -1;
var typed_attribute_change_value: i32 = -1;
var typed_call_data_seen: bool = false;
var typed_call_data_name: []const u8 = "";
var typed_call_data_args: i32 = -1;
var multi_call_data_seen: bool = false;
var multi_call_data_values: [2]i32 = .{ -1, -1 };
var owned_payload_drops: usize = 0;

const PoisonAllocator = struct {
    backing: std.mem.Allocator,

    const Self = @This();

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Self = @ptrCast(@alignCast(context));
        @memset(memory, 0xa5);
        self.backing.rawFree(memory, alignment, return_address);
    }
};

const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,

    const Self = @This();

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        const memory = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        self.live += 1;
        self.allocations += 1;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.live == 0) @panic("tracking allocator double free");
        self.live -= 1;
        self.frees += 1;
        self.backing.rawFree(memory, alignment, return_address);
    }
};

fn parityModelValidator(model: *hsm.Model) void {
    model_validator_calls += 1;
    if (model.members.get("/HookBase/idle") == null and model.members.get("/HookRedefined/idle") == null) {
        @panic("validator did not receive the populated model");
    }
    custom_validator_completed = true;
}

fn duplicateTolerantValidator(model: *hsm.Model) void {
    _ = model;
}

fn firstValidatorMarker(model: *hsm.Model) void {
    _ = model;
    last_validator_marker = 1;
}

fn secondValidatorMarker(model: *hsm.Model) void {
    _ = model;
    last_validator_marker = 2;
}

fn noOpObserver(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
}

fn observationVisibilityValidator(model: *hsm.Model) void {
    observation_validator_saw_generated_member = false;
    var members = model.members.iterator();
    while (members.next()) |entry| {
        if (std.mem.indexOf(u8, entry.value_ptr.*.qualified_name, "/observation_") != null) {
            observation_validator_saw_generated_member = true;
            return;
        }
    }
}

fn parityModelFinalizer(model: *hsm.Model) !void {
    model_finalizer_calls += 1;
    custom_finalizer_saw_validated_model = custom_validator_completed;
    custom_finalizer_saw_unindexed_model = model.transition_map.count() == 0 and model.deferred_map.count() == 0;
    try hsm.DefaultModelFinalizer.finalize(model);
}

fn pointerReturningFinalizer(model: *hsm.Model) *hsm.Model {
    hsm.DefaultModelFinalizer.finalize(model) catch unreachable;
    return model;
}

fn errorUnionPointerReturningFinalizer(model: *hsm.Model) !*hsm.Model {
    try hsm.DefaultModelFinalizer.finalize(model);
    return model;
}

fn differentPointerFinalizer(model: *hsm.Model) *hsm.Model {
    _ = model;
    return &different_finalizer_model;
}

fn queueAttributeChanges(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = instance;
    _ = event;
    const machine = queued_attribute_machine orelse @panic("queued attribute machine is not installed");
    machine.Set(ctx, "count", @as(i32, 7)) catch @panic("first queued Set failed");
    machine.Set(ctx, "count", @as(i32, 9)) catch @panic("second queued Set failed");
    machine.Set(ctx, "count", @as(i32, 11)) catch @panic("third queued Set failed");
    machine.Set(ctx, "count", @as(i32, 13)) catch @panic("fourth queued Set failed");
    machine.Set(ctx, "count", @as(i32, 15)) catch @panic("fifth queued Set failed");
}

fn captureQueuedAttributeChange(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    if (event.kind != hsm.ChangeEventKind) return;
    const index = queued_attribute_events;
    if (index >= queued_attribute_old_values.len) return;
    const old_value = event.getData("old") orelse @panic("queued change event is missing old value");
    const new_value = event.getData("new") orelse @panic("queued change event is missing new value");
    queued_attribute_old_values[index] = (@as(*const i32, @ptrCast(@alignCast(old_value)))).*;
    queued_attribute_new_values[index] = (@as(*const i32, @ptrCast(@alignCast(new_value)))).*;
    queued_attribute_events += 1;
}

fn setDeferredAttribute(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = instance;
    _ = event;
    const machine = deferred_attribute_machine orelse @panic("deferred attribute machine is not installed");
    machine.Set(ctx, "count", @as(i32, 7)) catch @panic("deferred Set failed");
}

fn queueTypedPayloads(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = instance;
    _ = event;
    const machine = typed_payload_machine orelse @panic("typed payload machine is not installed");
    machine.Set(ctx, "count", typed_payload_attribute_value) catch @panic("typed queued Set failed");
    machine.CallWithData(ctx, "record", @as(*anyopaque, @ptrCast(&typed_payload_call_args))) catch
        @panic("typed queued CallWithData failed");
}

fn captureDeferredAttributeChange(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    if (event.kind != hsm.ChangeEventKind) return;
    const old_value = event.getData("old") orelse @panic("deferred change event is missing old value");
    const new_value = event.getData("new") orelse @panic("deferred change event is missing new value");
    deferred_attribute_old_value = (@as(*const i32, @ptrCast(@alignCast(old_value)))).*;
    deferred_attribute_new_value = (@as(*const i32, @ptrCast(@alignCast(new_value)))).*;
    deferred_attribute_events += 1;
}

fn captureTypedAttributeChange(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    const change = event.getAttributeChange() orelse @panic("change event is missing typed payload");
    const old_value = change.Old orelse @panic("typed change event is missing old value");
    const old: *const i32 = @ptrCast(@alignCast(old_value));
    const new: *const i32 = @ptrCast(@alignCast(change.New));
    const value: *const i32 = @ptrCast(@alignCast(change.Value()));
    typed_attribute_change_seen = true;
    typed_attribute_change_name = change.Name;
    typed_attribute_change_old_value = old.*;
    typed_attribute_change_new_value = new.*;
    typed_attribute_change_value = value.*;
}

fn captureTypedCallData(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    const call = event.getCallData() orelse @panic("call event is missing typed payload");
    const typed_args = call.ArgsAs(i32) orelse @panic("typed call event is missing args");
    typed_call_data_seen = true;
    typed_call_data_name = call.Name;
    typed_call_data_args = typed_args.*;
}

fn captureMultiCallData(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    const call = event.getCallData() orelse @panic("multi-argument call event is missing typed payload");
    const first = call.ValueAs(0, i32) orelse @panic("multi-argument call event is missing first value");
    const second = call.ValueAs(1, i32) orelse @panic("multi-argument call event is missing second value");
    multi_call_data_seen = true;
    multi_call_data_values = .{ first.*, second.* };
}

fn dropOwnedPayload(allocator: std.mem.Allocator, value: *anyopaque) void {
    owned_payload_drops += 1;
    allocator.destroy(@as(*i32, @ptrCast(@alignCast(value))));
}

fn redefineCategoryOperation() void {}

fn observedEntry(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
    observed_behavior_calls += 1;
}

fn observedEffect(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
    observed_effect_calls += 1;
}

fn parityObserver(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    if (!std.mem.eql(u8, event.name, "hsm/observation")) return;
    const data = event.getData("").?;
    const payload: *const hsm.ObservationData = @ptrCast(@alignCast(data));
    if (std.mem.eql(u8, payload.occurrence, "behavior")) {
        last_behavior_source = payload.source;
        observed_behavior_calls += 100;
    } else if (std.mem.eql(u8, payload.occurrence, "event")) {
        last_event_source = payload.source;
        observed_event_calls += 1;
    }
}

fn enterIdle(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_instance: *TestInstance = @ptrCast(@alignCast(instance));
    test_instance.entries += 1;
}

fn exitIdle(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_instance: *TestInstance = @ptrCast(@alignCast(instance));
    test_instance.exits += 1;
}

fn initialEffectFirst(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
    initial_effect_order[initial_effect_calls] = 1;
    initial_effect_calls += 1;
}

fn initialEffectSecond(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
    initial_effect_order[initial_effect_calls] = 2;
    initial_effect_calls += 1;
}

fn initialEntryEvent(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    initial_entry_event_calls += 1;
    initial_entry_event_matches = std.mem.eql(u8, event.name, hsm.InitialEventName);
}

fn submachineBoundaryActivity(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
    _ = submachine_boundary_activity_runs.fetchAdd(1, .acq_rel);
}

test "path and glob helpers match sibling semantics" {
    try testing.expect(hsm.Match("/foo/bar/baz", "/foo/*/baz"));
    try testing.expect(hsm.Match("abcdef", .{ "a*f", "no-match" }));
    try testing.expect(hsm.Match("", "*"));
    try testing.expect(!hsm.Match("abc", "a*d"));

    try testing.expect(hsm.IsAncestor("/foo/bar", "/foo/bar/baz"));
    try testing.expect(hsm.IsAncestor("/foo/", "/foo/bar/baz"));
    try testing.expect(hsm.IsAncestor("/", "/foo/bar/baz"));
    try testing.expect(!hsm.IsAncestor("/foo/bar/baz", "/foo/bar/baz"));
    try testing.expect(!hsm.IsAncestor("/foo/bar/baz", "/foo/bar"));

    try testing.expectEqualStrings("/foo/bar/baz", hsm.LCA("/foo/bar/baz", "/foo/bar/baz/qux"));
    try testing.expectEqualStrings("/foo", hsm.LCA("/foo/bar/baz", "/foo/qux"));
    try testing.expectEqualStrings("/foo", hsm.LCA("/foo/bar", "/foo/bar"));
    try testing.expectEqualStrings("/foo/bar/baz", hsm.LCA("", "/foo/bar/baz"));
}

test "Started returns an owning pointer and Restart re-enters initial state" {
    const model = comptime hsm.define("ApiParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.entry(enterIdle),
            hsm.exit(exitIdle),
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") }),
        }),
        hsm.final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();

    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();

    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    try testing.expect(std.mem.endsWith(u8, machine.state(), "/idle"));
    try testing.expectEqual(@as(usize, 1), instance.entries);

    var finish = hsm.Event.init(testing.allocator, "finish");
    defer finish.deinit();
    try machine.Dispatch(&context, finish);
    try testing.expect(std.mem.endsWith(u8, machine.state(), "/done"));

    try hsm.Restart(machine);
    try testing.expect(std.mem.endsWith(u8, machine.state(), "/idle"));
    try testing.expectEqual(@as(usize, 2), instance.entries);
    try testing.expectEqual(@as(usize, 1), instance.exits);
}

test "stopped handles retain allocation-free QualifiedName" {
    const model = comptime hsm.define("QualifiedNameParity", .{
        hsm.initial(hsm.target("outer")),
        hsm.state("outer", .{
            hsm.initial(hsm.target("inner")),
            hsm.state("inner", .{}),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();

    var machine = try hsm.New(&context, &instance, &built_model);
    defer machine.deinit();
    const model_root = built_model.members.get("/QualifiedNameParity").?;
    const root_name = model_root.qualified_name;
    try testing.expectEqualStrings("", machine.state());
    try testing.expectEqualStrings("/QualifiedNameParity", machine.QualifiedName());
    try testing.expectEqual(@intFromPtr(root_name.ptr), @intFromPtr(machine.QualifiedName().ptr));

    try machine.start();
    try testing.expectEqualStrings("/QualifiedNameParity/outer/inner", machine.state());
    try testing.expectEqualStrings("/QualifiedNameParity", machine.QualifiedName());

    try machine.stop();
    try testing.expectEqualStrings("", machine.state());
    try testing.expectEqualStrings("/QualifiedNameParity", machine.QualifiedName());
    try testing.expectEqual(@intFromPtr(root_name.ptr), @intFromPtr(machine.QualifiedName().ptr));

    try machine.start();
    try testing.expectEqualStrings("/QualifiedNameParity/outer/inner", machine.state());
    try testing.expectEqualStrings("/QualifiedNameParity", machine.QualifiedName());

    try machine.restart();
    try testing.expectEqualStrings("/QualifiedNameParity/outer/inner", machine.state());
    try testing.expectEqualStrings("/QualifiedNameParity", machine.QualifiedName());
}

test "omitted runtime IDs are generated once and copied into snapshots" {
    const model = comptime hsm.define("AutoIDParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();

    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    const id = machine.ID() orelse return error.TestExpectedEqual;
    try testing.expect(id.len > 0);
    const id_copy = try testing.allocator.dupe(u8, id);
    defer testing.allocator.free(id_copy);

    var snapshot = try machine.TakeSnapshot();
    defer snapshot.deinit();
    try testing.expectEqualStrings(id_copy, machine.ID().?);
    try testing.expectEqualStrings(id_copy, snapshot.ID.?);
    try testing.expectEqualStrings(machine.QualifiedName(), snapshot.QualifiedName);
}

test "explicit runtime IDs remain unchanged in snapshots" {
    const model = comptime hsm.define("ExplicitIDParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();

    var machine = try hsm.StartedWithConfig(&context, &instance, &built_model, hsm.Config(.{ .ID = "explicit-runtime-id" }));
    defer machine.deinit();

    try testing.expectEqualStrings("explicit-runtime-id", machine.ID().?);
    var snapshot = try machine.TakeSnapshot();
    defer snapshot.deinit();
    try testing.expectEqualStrings("explicit-runtime-id", snapshot.ID.?);

    var empty_id_instance = TestInstance.init();
    defer empty_id_instance.deinit();
    var empty_id_machine = try hsm.StartedWithConfig(&context, &empty_id_instance, &built_model, hsm.Config(.{ .ID = "" }));
    defer empty_id_machine.deinit();
    try testing.expect(empty_id_machine.ID().?.len > 0);
}

test "runtime config name is retained after caller storage changes" {
    const model = comptime hsm.define("CopiedNameParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();

    var name_storage = [_]u8{ '/', 'C', 'o', 'p', 'i', 'e', 'd', 'A', 'l', 'i', 'a', 's' };
    const config = hsm.Config(.{ .ID = "copied-name-id", .Name = name_storage[0..] });
    var machine = try hsm.StartedWithConfig(&context, &instance, &built_model, config);
    defer machine.deinit();
    @memset(&name_storage, 'x');

    try testing.expectEqualStrings("CopiedAlias", machine.Name());
    try testing.expectEqualStrings("/CopiedAlias", machine.QualifiedName());
    var snapshot = try machine.TakeSnapshot();
    defer snapshot.deinit();
    try testing.expectEqualStrings("/CopiedAlias", snapshot.QualifiedName);
}

test "StateMachine and Group expose their configured clock" {
    const model = comptime hsm.define("ClockAccessorParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    const clock = hsm.Clock(.{ .Now = parityClockNow });
    var machine = try hsm.StartedWithConfig(&context, &instance, &built_model, hsm.Config(.{ .Clock = clock }));
    defer machine.deinit();

    try testing.expectEqual(@as(u64, 123456), machine.Clock().Now());
    var group = try hsm.MakeGroup(testing.allocator, .{machine});
    defer group.deinit();
    try testing.expectEqual(@as(u64, 123456), group.Clock().Now());
}

test "Initial effects preserve order and expose the canonical initial event" {
    initial_effect_calls = 0;
    initial_effect_order = .{ 0, 0 };
    initial_entry_event_calls = 0;
    initial_entry_event_matches = false;

    const model = comptime hsm.define("InitialEffectParity", .{
        hsm.initial(.{
            hsm.target("ready"),
            hsm.effect(initialEffectFirst),
            hsm.effect(initialEffectSecond),
        }),
        hsm.state("ready", .{hsm.entry(initialEntryEvent)}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    const initial_element = built_model.members.get("/InitialEffectParity/.initial").?;
    const initial_transition: *const hsm.TransitionElement = @ptrCast(@alignCast(initial_element));
    try testing.expectEqualStrings(hsm.InitialEventName, initial_transition.event_name.?);
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    try testing.expectEqual(@as(usize, 2), initial_effect_calls);
    try testing.expectEqual(@as(u8, 1), initial_effect_order[0]);
    try testing.expectEqual(@as(u8, 2), initial_effect_order[1]);
    try testing.expectEqual(@as(usize, 1), initial_entry_event_calls);
    try testing.expect(initial_entry_event_matches);
    var initial_event = hsm.InitialEvent(testing.allocator);
    defer initial_event.deinit();
    try testing.expectEqualStrings(hsm.InitialEventName, initial_event.name);
    try testing.expectEqual(hsm.CompletionEventKind, initial_event.kind);
    try testing.expect(initial_event.data == null);
}

test "Initial validation rejects targets outside the owning composite" {
    const model = comptime hsm.define("InitialLocalityParity", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target("../sibling")),
            hsm.state("child", .{}),
        }),
        hsm.state("sibling", .{}),
    });

    var built_model = try model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    try testing.expectError(hsm.ValidationError.InvalidTransitionTarget, hsm.validate(&built_model));
}

test "Initial validation rejects the owning composite itself" {
    const model = comptime hsm.define("InitialOwnerParity", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.initial(hsm.target(".")),
            hsm.state("child", .{}),
        }),
    });

    var built_model = try model.buildUnchecked(testing.allocator);
    defer built_model.deinit();

    try testing.expectError(hsm.ValidationError.InvalidTransitionTarget, hsm.validate(&built_model));
}

test "New wrappers and AnyEvent wildcard dispatch preserve low ceremony lifecycle" {
    const model = comptime hsm.define("WildcardParity", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on(hsm.AnyEvent), hsm.target("done") }),
        }),
        hsm.final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try testing.expect(built_model.transition_map.get("/WildcardParity/idle").?.get(hsm.AnyEvent) != null);

    var context = hsm.Context.init(testing.allocator);
    var first_instance = TestInstance.init();
    defer first_instance.deinit();
    var second_instance = TestInstance.init();
    defer second_instance.deinit();

    var first = try hsm.New(&context, &first_instance, model);
    defer first.deinit();
    var second = try hsm.NewWithConfig(&context, &second_instance, model, hsm.Config(.{ .ID = "second" }));
    defer second.deinit();
    try testing.expect(first.IsStopped());
    try testing.expect(second.IsStopped());
    try first.start();
    try second.start();

    var group = try hsm.NewGroup(testing.allocator, .{ first, second });
    defer group.deinit();
    try testing.expectEqual(@as(usize, 2), group.Instances().len);
    try testing.expect(group.Context() == &context);

    var event = hsm.Event.init(testing.allocator, "anything");
    defer event.deinit();
    try group.Dispatch(&context, event);
    try testing.expectEqualStrings("/WildcardParity/done", first.state());
    try testing.expectEqualStrings("/WildcardParity/done", second.state());

    const states = try group.States();
    defer testing.allocator.free(states);
    try testing.expectEqualStrings("/WildcardParity/done", states[0]);
    try testing.expectEqualStrings("/WildcardParity/done", states[1]);
    const joined = try group.State();
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("/WildcardParity/done\n/WildcardParity/done", joined);

    const snapshots = try group.Snapshots();
    defer {
        for (snapshots) |*snapshot| snapshot.deinit();
        testing.allocator.free(snapshots);
    }
    try testing.expectEqual(@as(usize, 2), snapshots.len);
    try testing.expectEqualStrings("/WildcardParity/done", snapshots[0].State);
    try testing.expectEqualStrings("/WildcardParity/done", snapshots[1].State);

    try hsm.Stop(first);
    try hsm.Restart(first);
    try testing.expectEqualStrings("/WildcardParity/idle", first.state());
}

test "exact event dispatch takes precedence over wildcard dispatch" {
    const model = comptime hsm.define("WildcardOrder", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on(hsm.AnyEvent), hsm.target("wildcard") }),
            hsm.transition(.{ hsm.on("specific"), hsm.target("exact") }),
        }),
        hsm.final("wildcard"),
        hsm.final("exact"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();

    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    var event = hsm.Event.init(testing.allocator, "specific");
    defer event.deinit();
    try machine.Dispatch(&context, event);
    try testing.expectEqualStrings("/WildcardOrder/exact", machine.state());
}

test "SubmachineState flattens reusable child models under a stable boundary" {
    const child = comptime hsm.define("Child", .{
        hsm.Attribute("child_value", @as(i32, 7)),
        hsm.Operation("child_operation", noOpObserver),
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") }),
        }),
        hsm.final("done"),
    });
    const parent = comptime hsm.define("Parent", .{
        hsm.initial(hsm.target("drive")),
        hsm.SubmachineState("drive", child),
    });

    var model = try parent.build(testing.allocator);
    defer model.deinit();
    try testing.expect(model.attributes.contains("/Parent/child_value"));
    try testing.expect(hsm.getOperation(&model, "/Parent/child_operation") != null);
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &model);
    defer machine.deinit();

    try testing.expectEqualStrings("/Parent/drive/idle", machine.state());
    var finish = hsm.Event.init(testing.allocator, "finish");
    defer finish.deinit();
    try machine.Dispatch(&context, finish);
    try testing.expectEqualStrings("/Parent/drive/done", machine.state());
}

test "SubmachineState accepts boundary behavior and transition partials" {
    submachine_boundary_activity_runs.store(0, .release);
    const child = comptime hsm.define("PartialChild", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
        hsm.final("done"),
    });
    const parent = comptime hsm.define("PartialParent", .{
        hsm.initial(hsm.target("drive")),
        hsm.SubmachineStateWithPartials("drive", child, .{
            hsm.entry(enterIdle),
            hsm.exit(exitIdle),
            hsm.activity(submachineBoundaryActivity),
            hsm.Defer(.{"held"}),
            hsm.transition(.{ hsm.on("finish"), hsm.target("../done") }),
        }),
        hsm.state("done", .{}),
    });

    var model = try parent.build(testing.allocator);
    defer model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &model);
    defer machine.deinit();

    try testing.expectEqualStrings("/PartialParent/drive/idle", machine.state());
    try testing.expectEqual(@as(usize, 1), instance.entries);
    var attempts: usize = 0;
    while (submachine_boundary_activity_runs.load(.acquire) == 0 and attempts < 200) : (attempts += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 1), submachine_boundary_activity_runs.load(.acquire));

    var held = hsm.Event.init(testing.allocator, "held");
    defer held.deinit();
    try machine.Dispatch(&context, held);
    try testing.expectEqualStrings("/PartialParent/drive/idle", machine.state());

    var finish = hsm.Event.init(testing.allocator, "finish");
    defer finish.deinit();
    try machine.Dispatch(&context, finish);
    try testing.expectEqualStrings("/PartialParent/done", machine.state());
    try testing.expectEqual(@as(usize, 1), instance.exits);
}

test "EntryPoint and ExitPoint cross a flattened submachine boundary" {
    const child = comptime hsm.define("ConnectionChild", .{
        hsm.initial(hsm.target("off")),
        hsm.EntryPoint("warm", .{hsm.target("running")}),
        hsm.ExitPoint("faulted", .{}),
        hsm.state("off", .{
            hsm.transition(.{ hsm.on("start"), hsm.target("running") }),
        }),
        hsm.state("running", .{
            hsm.transition(.{ hsm.on("fault"), hsm.target("faulted") }),
        }),
    });
    const parent = comptime hsm.define("ConnectionParent", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on("enable"), hsm.target("drive"), hsm.EntryPoint("warm", .{}) }),
        }),
        hsm.SubmachineState("drive", child),
        hsm.transition(.{ hsm.source("drive"), hsm.ExitPoint("faulted", .{}), hsm.target("fault") }),
        hsm.state("fault", .{}),
    });

    var model = try parent.build(testing.allocator);
    defer model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &model);
    defer machine.deinit();

    try testing.expectEqualStrings("/ConnectionParent/idle", machine.state());
    var enable = hsm.Event.init(testing.allocator, "enable");
    defer enable.deinit();
    try machine.Dispatch(&context, enable);
    try testing.expectEqualStrings("/ConnectionParent/drive/running", machine.state());

    var fault = hsm.Event.init(testing.allocator, "fault");
    defer fault.deinit();
    try machine.Dispatch(&context, fault);
    try testing.expectEqualStrings("/ConnectionParent/fault", machine.state());
}

test "Context registry supports O(1)-indexed multi-dispatch" {
    const model = comptime hsm.define("ContextDispatch", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on("finish"), hsm.target("done") }),
        }),
        hsm.final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var first_instance = TestInstance.init();
    defer first_instance.deinit();
    var second_instance = TestInstance.init();
    defer second_instance.deinit();
    var first = try hsm.NewWithConfig(&context, &first_instance, model, hsm.Config(.{ .ID = "first" }));
    defer first.deinit();
    var second = try hsm.NewWithConfig(&context, &second_instance, model, hsm.Config(.{ .ID = "second" }));
    defer second.deinit();
    try testing.expect(hsm.FromContext(&context) == null);
    try first.start();
    try second.start();

    try testing.expect(hsm.FromContext(&context) != null);
    try testing.expectEqualStrings("second", hsm.FromContext(&context).?.ID().?);
    const instances = try hsm.InstancesFromContext(testing.allocator, &context);
    defer testing.allocator.free(instances);
    try testing.expectEqual(@as(usize, 2), instances.len);

    var finish = hsm.Event.init(testing.allocator, "finish");
    defer finish.deinit();
    try hsm.DispatchTo(&context, finish, .{"second"});
    try testing.expectEqualStrings("/ContextDispatch/idle", first.state());
    try testing.expectEqualStrings("/ContextDispatch/done", second.state());
    try first.stop();
    try testing.expect(hsm.FromContext(&context) == second);
    try first.start();
    try testing.expect(hsm.FromContext(&context) == first);
    try hsm.DispatchAll(&context, finish);
    try testing.expectEqualStrings("/ContextDispatch/done", first.state());
}

test "Context lookup leases expose lifetime-safe machine access" {
    const model = comptime hsm.define("ContextLease", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    var lease = (try hsm.FromContextLease(&context)).?;
    defer lease.release();
    try testing.expect(lease.ID() != null);
    try testing.expectEqualStrings("ContextLease", lease.Name());
    try testing.expectEqualStrings("/ContextLease", lease.QualifiedName());
    try testing.expect(!lease.IsStopped());
    try testing.expect(lease.Machine() == machine);

    var leases = try hsm.InstancesFromContextLease(testing.allocator, &context);
    defer {
        for (leases) |*context_lease| context_lease.release();
        testing.allocator.free(leases);
    }
    try testing.expectEqual(@as(usize, 1), leases.len);
    try testing.expect(leases[0].Machine() == machine);
}

test "Redefine replays elements and applies inherited model hooks" {
    model_validator_calls = 0;
    model_finalizer_calls = 0;
    custom_validator_completed = false;
    custom_finalizer_saw_unindexed_model = false;
    custom_finalizer_saw_validated_model = false;

    const base = comptime hsm.Define("HookBase", .{
        hsm.Validator(parityModelValidator),
        hsm.Finalizer(parityModelFinalizer),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });
    const redefined = comptime hsm.Redefine(base, .{
        "HookRedefined",
        hsm.State("extra", .{}),
    });

    var base_model = try base.build(testing.allocator);
    defer base_model.deinit();
    try testing.expectEqual(@as(usize, 1), model_validator_calls);
    try testing.expectEqual(@as(usize, 1), model_finalizer_calls);
    try testing.expect(custom_finalizer_saw_validated_model);
    try testing.expect(custom_finalizer_saw_unindexed_model);

    var redefined_model = try redefined.build(testing.allocator);
    defer redefined_model.deinit();
    try testing.expectEqual(@as(usize, 2), model_validator_calls);
    try testing.expectEqual(@as(usize, 2), model_finalizer_calls);
    try testing.expect(custom_finalizer_saw_validated_model);
    try testing.expect(custom_finalizer_saw_unindexed_model);
    try testing.expect(redefined_model.members.get("/HookRedefined/idle") != null);
    try testing.expect(redefined_model.members.get("/HookRedefined/extra") != null);
    try testing.expect(redefined_model.members.get("/HookBase/idle") == null);
}

test "Default model hooks validate and finalize models" {
    const invalid = comptime hsm.Define("DefaultHookInvalid", .{
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{hsm.Transition(.{hsm.On("hit")})}),
    });
    try testing.expectError(hsm.ValidationError.TransitionWithoutTargetOrEffect, invalid.build(testing.allocator));

    const valid = comptime hsm.Define("DefaultHookValid", .{
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{hsm.Transition(.{ hsm.On("finish"), hsm.Target("done") })}),
        hsm.Final("done"),
    });
    var model = try valid.build(testing.allocator);
    defer model.deinit();
    try testing.expect(model.transition_map.get("/DefaultHookValid/idle") != null);
}

test "Finalizers may return the in-place model pointer" {
    const direct = comptime hsm.Define("DirectPointerFinalizer", .{
        hsm.Finalizer(pointerReturningFinalizer),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });
    var direct_model = try direct.build(testing.allocator);
    defer direct_model.deinit();
    try testing.expect(direct_model.transition_map.get("/DirectPointerFinalizer") != null);

    const error_union = comptime hsm.Define("ErrorUnionPointerFinalizer", .{
        hsm.Finalizer(errorUnionPointerReturningFinalizer),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });
    var error_union_model = try error_union.build(testing.allocator);
    defer error_union_model.deinit();
    try testing.expect(error_union_model.transition_map.get("/ErrorUnionPointerFinalizer") != null);
}

test "Finalizers reject a different model pointer without leaking" {
    const definition = comptime hsm.Define("DifferentPointerFinalizer", .{
        hsm.Finalizer(differentPointerFinalizer),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });

    try testing.expectError(
        hsm.ValidationError.FinalizerReturnedDifferentModel,
        definition.build(testing.allocator),
    );
}

test "Explicit validators cannot bypass duplicate-member validation" {
    const duplicate = comptime hsm.Define("ExplicitDuplicate", .{
        hsm.Validator(duplicateTolerantValidator),
        hsm.Initial(hsm.Target("same")),
        hsm.State("same", .{}),
        hsm.State("same", .{}),
    });

    try testing.expectError(hsm.ValidationError.DuplicateMemberName, duplicate.build(testing.allocator));

    var unchecked = try duplicate.buildUnchecked(testing.allocator);
    defer unchecked.deinit();
    try testing.expectError(hsm.ValidationError.DuplicateMemberName, hsm.validate(&unchecked));
}

test "Validators see generated observation members" {
    observation_validator_saw_generated_member = false;

    const definition = comptime hsm.Define("ObservationValidation", .{
        hsm.Observe(noOpObserver, .{}),
        hsm.Validator(observationVisibilityValidator),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{hsm.Entry(noOpObserver)}),
    });

    var model = try definition.build(testing.allocator);
    defer model.deinit();
    try testing.expect(observation_validator_saw_generated_member);
}

test "Only the last validator marker runs" {
    last_validator_marker = 0;

    const definition = comptime hsm.Define("LastValidator", .{
        hsm.Validator(firstValidatorMarker),
        hsm.Validator(secondValidatorMarker),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });

    var model = try definition.build(testing.allocator);
    defer model.deinit();
    try testing.expectEqual(@as(u8, 2), last_validator_marker);
}

test "buildUnchecked defers invalid transition validation" {
    const definition = comptime hsm.Define("UncheckedInvalidTransition", .{
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{hsm.Transition(.{hsm.On("hit")})}),
    });

    var model = try definition.buildUnchecked(testing.allocator);
    defer model.deinit();
    try testing.expectError(hsm.ValidationError.TransitionWithoutTargetOrEffect, hsm.validate(&model));
}

test "Redefine replaces same-name top-level elements" {
    const base = comptime hsm.Define("ReplaceBase", .{
        hsm.Initial(hsm.Target("work")),
        hsm.State("work", .{}),
        hsm.State("stale", .{}),
    });
    const redefined = comptime hsm.Redefine(base, .{
        hsm.Final("work"),
    });

    var model = try redefined.build(testing.allocator);
    defer model.deinit();
    const work = model.members.get("/ReplaceBase/work") orelse return error.TestExpectedEqual;
    try testing.expectEqual(hsm.ElementType.final, work.kind);

    var qualified_work_count: usize = 0;
    var members = model.members.iterator();
    while (members.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*.qualified_name, "/ReplaceBase/work")) {
            qualified_work_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), qualified_work_count);
}

test "Redefine replaces the inherited root initial transition" {
    const base = comptime hsm.Define("InitialReplace", .{
        hsm.Initial(hsm.Target("work")),
        hsm.State("work", .{}),
        hsm.State("ready", .{}),
    });
    const redefined = comptime hsm.Redefine(base, .{
        hsm.Initial(hsm.Target("ready")),
    });

    var model = try redefined.build(testing.allocator);
    defer model.deinit();

    const root = hsm.getState(&model, "/InitialReplace") orelse return error.TestExpectedEqual;
    const initial_name = root.initial_transition orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("/InitialReplace/.initial", initial_name);

    const initial = hsm.getTransition(&model, initial_name) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("/InitialReplace/ready", initial.target orelse return error.TestExpectedEqual);

    var root_initial_count: usize = 0;
    var members = model.members.iterator();
    while (members.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*.qualified_name, "/InitialReplace/.initial")) {
            root_initial_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), root_initial_count);
}

test "Redefine removes inherited root transitions under a replaced vertex" {
    const base = comptime hsm.Define("TransitionReplace", .{
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
        hsm.State("work", .{
            hsm.State("child", .{}),
        }),
        hsm.Transition(.{
            hsm.Source("work/child"),
            hsm.On("leave"),
            hsm.Target("idle"),
        }),
    });
    const redefined = comptime hsm.Redefine(base, .{
        hsm.State("work", .{
            hsm.State("child", .{}),
        }),
    });

    var model = try redefined.build(testing.allocator);
    defer model.deinit();
    try testing.expect(model.members.get("/TransitionReplace/transition_0") == null);
}

test "Redefine merges a nested child replacement without dropping siblings" {
    const base = comptime hsm.Define("NestedReplace", .{
        hsm.Initial(hsm.Target("parent")),
        hsm.State("parent", .{
            hsm.Initial(hsm.Target("child")),
            hsm.State("child", .{}),
            hsm.State("sibling", .{}),
        }),
    });
    const redefined = comptime hsm.Redefine(base, .{
        hsm.State("parent", .{
            hsm.Final("child"),
        }),
    });

    var model = try redefined.build(testing.allocator);
    defer model.deinit();
    const child = model.members.get("/NestedReplace/parent/child") orelse return error.TestExpectedEqual;
    try testing.expectEqual(hsm.ElementType.final, child.kind);
    try testing.expect(model.members.get("/NestedReplace/parent/sibling") != null);

    var base_model = try base.build(testing.allocator);
    defer base_model.deinit();
    const base_child = base_model.members.get("/NestedReplace/parent/child") orelse return error.TestExpectedEqual;
    try testing.expectEqual(hsm.ElementType.state, base_child.kind);
}

test "Redefine preserves same-category attributes, operations, and connection points" {
    const base = comptime hsm.Define("CategoryReplace", .{
        hsm.Attribute("flag", false),
        hsm.Operation("label", redefineCategoryOperation),
        hsm.Initial(hsm.Target("ready")),
        hsm.State("ready", .{}),
        hsm.EntryPoint("resume", .{hsm.Target("ready")}),
    });
    const redefined = comptime hsm.Redefine(base, .{
        hsm.Attribute("flag", true),
        hsm.Operation("label", redefineCategoryOperation),
        hsm.EntryPoint("resume", .{hsm.Target("ready")}),
    });

    var model = try redefined.build(testing.allocator);
    defer model.deinit();
    try testing.expect(model.attributes.get("/CategoryReplace/flag") != null);
    try testing.expect(model.members.get("/CategoryReplace/label") != null);
    try testing.expect(model.members.get("/CategoryReplace/resume") != null);
}

test "Observe wraps behavior execution and transition events" {
    observed_behavior_calls = 0;
    observed_event_calls = 0;
    observed_effect_calls = 0;
    last_behavior_source = "";
    last_event_source = "";

    const model = comptime hsm.Define("ObserveBase", .{
        hsm.Observe(parityObserver, .{}),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Entry(observedEntry),
            hsm.Transition(.{
                hsm.On("go"),
                hsm.Target("done"),
                hsm.Effect(observedEffect),
            }),
        }),
        hsm.Final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    try testing.expectEqual(@as(usize, 101), observed_behavior_calls);
    try testing.expectEqualStrings("/ObserveBase/idle/entry_0", last_behavior_source);
    observed_event_calls = 0;
    var go = hsm.Event.init(testing.allocator, "go");
    defer go.deinit();
    try machine.Dispatch(&context, go);
    try testing.expectEqual(@as(usize, 1), observed_event_calls);
    try testing.expectEqualStrings("/ObserveBase/idle/transition_0", last_event_source);
    try testing.expectEqual(@as(usize, 1), observed_effect_calls);
    try testing.expectEqualStrings("/ObserveBase/done", machine.state());
}

test "queued runtime AttributeChange payloads outlive the originating Set" {
    queued_attribute_machine = null;
    queued_attribute_old_values = .{ -1, -1, -1, -1, -1 };
    queued_attribute_new_values = .{ -1, -1, -1, -1, -1 };
    queued_attribute_events = 0;

    const model = comptime hsm.Define("QueuedAttributePayload", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Transition(.{
                hsm.On("go"),
                hsm.Effect(queueAttributeChanges),
                hsm.Target("done"),
            }),
        }),
        hsm.State("done", .{
            hsm.Transition(.{
                hsm.OnSet("count"),
                hsm.Effect(captureQueuedAttributeChange),
            }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var poison_allocator = PoisonAllocator{ .backing = testing.allocator };
    var context = hsm.Context.init(poison_allocator.allocator());
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    queued_attribute_machine = machine;
    defer queued_attribute_machine = null;

    var go = hsm.Event.init(testing.allocator, "go");
    defer go.deinit();
    try machine.Dispatch(&context, go);

    try testing.expectEqual(@as(usize, 5), queued_attribute_events);
    try testing.expectEqual(@as(i32, 0), queued_attribute_old_values[0]);
    try testing.expectEqual(@as(i32, 7), queued_attribute_new_values[0]);
    try testing.expectEqual(@as(i32, 7), queued_attribute_old_values[1]);
    try testing.expectEqual(@as(i32, 9), queued_attribute_new_values[1]);
    try testing.expectEqual(@as(i32, 9), queued_attribute_old_values[2]);
    try testing.expectEqual(@as(i32, 11), queued_attribute_new_values[2]);
    try testing.expectEqual(@as(i32, 11), queued_attribute_old_values[3]);
    try testing.expectEqual(@as(i32, 13), queued_attribute_new_values[3]);
    try testing.expectEqual(@as(i32, 13), queued_attribute_old_values[4]);
    try testing.expectEqual(@as(i32, 15), queued_attribute_new_values[4]);
}

test "deferred runtime AttributeChange payloads retain ownership through replay" {
    deferred_attribute_machine = null;
    deferred_attribute_old_value = -1;
    deferred_attribute_new_value = -1;
    deferred_attribute_events = 0;

    const model = comptime hsm.Define("DeferredAttributePayload", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Initial(hsm.Target("waiting")),
        hsm.State("waiting", .{
            hsm.Transition(.{
                hsm.On("mutate"),
                hsm.Effect(setDeferredAttribute),
                hsm.Target("../holding"),
            }),
        }),
        hsm.State("holding", .{
            hsm.DeferEvents(.{"/DeferredAttributePayload/count"}),
            hsm.Transition(.{ hsm.On("release"), hsm.Target("../ready") }),
        }),
        hsm.State("ready", .{
            hsm.Transition(.{
                hsm.OnSet("count"),
                hsm.Effect(captureDeferredAttributeChange),
            }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var poison_allocator = PoisonAllocator{ .backing = testing.allocator };
    var context = hsm.Context.init(poison_allocator.allocator());
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    deferred_attribute_machine = machine;
    defer deferred_attribute_machine = null;

    var mutate = hsm.Event.init(testing.allocator, "mutate");
    defer mutate.deinit();
    try machine.Dispatch(&context, mutate);
    try testing.expectEqualStrings("/DeferredAttributePayload/holding", machine.state());
    try testing.expectEqual(@as(usize, 0), deferred_attribute_events);
    var deferred_snapshot = try machine.TakeSnapshot();
    try testing.expectEqual(@as(usize, 1), deferred_snapshot.QueueLen);
    deferred_snapshot.deinit();

    var release = hsm.Event.init(testing.allocator, "release");
    defer release.deinit();
    try machine.Dispatch(&context, release);
    try testing.expectEqualStrings("/DeferredAttributePayload/ready", machine.state());
    try testing.expectEqual(@as(usize, 1), deferred_attribute_events);
    try testing.expectEqual(@as(i32, 0), deferred_attribute_old_value);
    try testing.expectEqual(@as(i32, 7), deferred_attribute_new_value);
}

test "queued typed event payloads retain AttributeChange and CallData accessors" {
    typed_payload_machine = null;
    typed_payload_attribute_value = 7;
    typed_payload_call_args = 42;
    typed_attribute_change_seen = false;
    typed_attribute_change_name = "";
    typed_attribute_change_old_value = -1;
    typed_attribute_change_new_value = -1;
    typed_attribute_change_value = -1;
    typed_call_data_seen = false;
    typed_call_data_name = "";
    typed_call_data_args = -1;

    const model = comptime hsm.Define("QueuedTypedPayload", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Operation("record", noOpObserver),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Transition(.{
                hsm.On("go"),
                hsm.Effect(queueTypedPayloads),
                hsm.Target("../ready"),
            }),
        }),
        hsm.State("ready", .{
            hsm.Transition(.{ hsm.OnSet("count"), hsm.Effect(captureTypedAttributeChange) }),
            hsm.Transition(.{ hsm.OnCall("record"), hsm.Effect(captureTypedCallData) }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    typed_payload_machine = machine;
    defer typed_payload_machine = null;

    var go = hsm.Event.init(testing.allocator, "go");
    defer go.deinit();
    try machine.Dispatch(&context, go);

    try testing.expect(typed_attribute_change_seen);
    try testing.expectEqualStrings("/QueuedTypedPayload/count", typed_attribute_change_name);
    try testing.expectEqual(@as(i32, 0), typed_attribute_change_old_value);
    try testing.expectEqual(typed_payload_attribute_value, typed_attribute_change_new_value);
    try testing.expectEqual(typed_payload_attribute_value, typed_attribute_change_value);
    try testing.expect(typed_call_data_seen);
    try testing.expectEqualStrings("/QueuedTypedPayload/record", typed_call_data_name);
    try testing.expectEqual(typed_payload_call_args, typed_call_data_args);
}

test "deferred typed event payloads retain AttributeChange and CallData accessors through replay" {
    typed_payload_machine = null;
    typed_payload_attribute_value = 7;
    typed_payload_call_args = 42;
    typed_attribute_change_seen = false;
    typed_attribute_change_name = "";
    typed_attribute_change_old_value = -1;
    typed_attribute_change_new_value = -1;
    typed_attribute_change_value = -1;
    typed_call_data_seen = false;
    typed_call_data_name = "";
    typed_call_data_args = -1;

    const model = comptime hsm.Define("DeferredTypedPayload", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Operation("record", noOpObserver),
        hsm.Initial(hsm.Target("waiting")),
        hsm.State("waiting", .{
            hsm.Transition(.{
                hsm.On("mutate"),
                hsm.Effect(queueTypedPayloads),
                hsm.Target("../holding"),
            }),
        }),
        hsm.State("holding", .{
            hsm.DeferEvents(.{
                "/DeferredTypedPayload/count",
                "hsm_call:/DeferredTypedPayload/record",
            }),
            hsm.Transition(.{ hsm.On("release"), hsm.Target("../ready") }),
        }),
        hsm.State("ready", .{
            hsm.Transition(.{ hsm.OnSet("count"), hsm.Effect(captureTypedAttributeChange) }),
            hsm.Transition(.{ hsm.OnCall("record"), hsm.Effect(captureTypedCallData) }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();
    typed_payload_machine = machine;
    defer typed_payload_machine = null;

    var mutate = hsm.Event.init(testing.allocator, "mutate");
    defer mutate.deinit();
    try machine.Dispatch(&context, mutate);
    try testing.expectEqualStrings("/DeferredTypedPayload/holding", machine.state());
    try testing.expect(!typed_attribute_change_seen);
    try testing.expect(!typed_call_data_seen);
    var deferred_snapshot = try machine.TakeSnapshot();
    try testing.expectEqual(@as(usize, 2), deferred_snapshot.QueueLen);
    deferred_snapshot.deinit();

    var release = hsm.Event.init(testing.allocator, "release");
    defer release.deinit();
    try machine.Dispatch(&context, release);

    try testing.expect(typed_attribute_change_seen);
    try testing.expectEqualStrings("/DeferredTypedPayload/count", typed_attribute_change_name);
    try testing.expectEqual(@as(i32, 0), typed_attribute_change_old_value);
    try testing.expectEqual(typed_payload_attribute_value, typed_attribute_change_new_value);
    try testing.expectEqual(typed_payload_attribute_value, typed_attribute_change_value);
    try testing.expect(typed_call_data_seen);
    try testing.expectEqualStrings("/DeferredTypedPayload/record", typed_call_data_name);
    try testing.expectEqual(typed_payload_call_args, typed_call_data_args);
}

test "typed AttributeChange accessor exposes OnSet payload" {
    typed_attribute_change_seen = false;
    typed_attribute_change_name = "";
    typed_attribute_change_old_value = -1;
    typed_attribute_change_new_value = -1;
    typed_attribute_change_value = -1;

    const model = comptime hsm.Define("TypedAttributeChangePayload", .{
        hsm.Attribute("count", @as(i32, 1)),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Transition(.{
                hsm.OnSet("count"),
                hsm.Effect(captureTypedAttributeChange),
                hsm.Target("../done"),
            }),
        }),
        hsm.Final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    try machine.Set(&context, "count", @as(i32, 7));

    try testing.expect(typed_attribute_change_seen);
    try testing.expectEqualStrings("/TypedAttributeChangePayload/count", typed_attribute_change_name);
    try testing.expectEqual(@as(i32, 1), typed_attribute_change_old_value);
    try testing.expectEqual(@as(i32, 7), typed_attribute_change_new_value);
    try testing.expectEqual(@as(i32, 7), typed_attribute_change_value);
}

test "typed CallData accessor exposes OnCall payload" {
    typed_call_data_seen = false;
    typed_call_data_name = "";
    typed_call_data_args = -1;

    const model = comptime hsm.Define("TypedCallDataPayload", .{
        hsm.Operation("record", captureTypedCallData),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Transition(.{ hsm.OnCall("record"), hsm.Target("../done") }),
        }),
        hsm.Final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    var args: i32 = 42;
    try machine.CallWithData(&context, "record", @as(*anyopaque, @ptrCast(&args)));

    try testing.expect(typed_call_data_seen);
    try testing.expectEqualStrings("/TypedCallDataPayload/record", typed_call_data_name);
    try testing.expectEqual(@as(i32, 42), typed_call_data_args);
}

test "CallWithArgs exposes ordered typed pointer values through CallData" {
    multi_call_data_seen = false;
    multi_call_data_values = .{ -1, -1 };

    const model = comptime hsm.Define("MultiCallDataPayload", .{
        hsm.Operation("record", noOpObserver),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{
            hsm.Transition(.{ hsm.OnCall("record"), hsm.Effect(captureMultiCallData), hsm.Target("../done") }),
        }),
        hsm.Final("done"),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var context = hsm.Context.init(testing.allocator);
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    var first: i32 = 1;
    var second: i32 = 2;
    try machine.CallWithArgs(&context, "record", .{ &first, &second });

    try testing.expect(multi_call_data_seen);
    try testing.expectEqual(@as(i32, 1), multi_call_data_values[0]);
    try testing.expectEqual(@as(i32, 2), multi_call_data_values[1]);
}

test "borrowed event payload replacement never frees caller storage" {
    var tracking = TrackingAllocator{ .backing = testing.allocator };
    const allocator = tracking.allocator();
    const first = try allocator.create(i32);
    const second = try allocator.create(i32);
    first.* = 1;
    second.* = 2;

    {
        var event = hsm.Event.withData(allocator, "borrowed");
        try event.putData("value", @ptrCast(first));
        try event.putMetadata("value", @ptrCast(first));
        try event.putData("value", @ptrCast(second));
        try event.putMetadata("value", @ptrCast(second));
        event.deinit();
    }

    try testing.expectEqual(@as(i32, 1), first.*);
    try testing.expectEqual(@as(i32, 2), second.*);
    try testing.expectEqual(@as(usize, 2), tracking.live);
    allocator.destroy(first);
    allocator.destroy(second);
    try testing.expectEqual(@as(usize, 0), tracking.live);
    try testing.expectEqual(tracking.allocations, tracking.frees);
}

test "owned event payloads use explicit destruction through replacement and deinit" {
    owned_payload_drops = 0;
    var event = hsm.Event.withData(testing.allocator, "owned");
    const first = try testing.allocator.create(i32);
    first.* = 1;
    try event.putOwnedData("value", @ptrCast(first), dropOwnedPayload);

    const second = try testing.allocator.create(i32);
    second.* = 2;
    try event.putOwnedData("value", @ptrCast(second), dropOwnedPayload);

    const metadata = try testing.allocator.create(i32);
    metadata.* = 3;
    try event.putOwnedMetadata("value", @ptrCast(metadata), dropOwnedPayload);
    event.deinit();

    try testing.expectEqual(@as(usize, 3), owned_payload_drops);
}

test "registered payload replacement retains before releasing the old mapping" {
    const model = comptime hsm.Define("RegisteredPayloadReplacement", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var poison_allocator = PoisonAllocator{ .backing = testing.allocator };
    var context = hsm.Context.init(poison_allocator.allocator());
    var instance = TestInstance.init();
    defer instance.deinit();
    var machine = try hsm.Started(&context, &instance, &built_model);
    defer machine.deinit();

    const first = (try machine.Get("count")).?;
    var data_event = hsm.Event.withData(context.allocator, "same-data");
    defer data_event.deinit();
    try data_event.putData("value", first);
    try machine.Set(&context, "count", @as(i32, 1));
    try data_event.putData("value", first);
    try testing.expectEqual(@as(i32, 0), (@as(*const i32, @ptrCast(@alignCast(data_event.getData("value").?)))).*);

    const second = (try machine.Get("count")).?;
    var metadata_event = hsm.Event.withData(context.allocator, "same-metadata");
    defer metadata_event.deinit();
    try metadata_event.putMetadata("value", second);
    try machine.Set(&context, "count", @as(i32, 2));
    try metadata_event.putMetadata("value", second);
    try testing.expectEqual(@as(i32, 1), (@as(*const i32, @ptrCast(@alignCast(metadata_event.getMetadata("value").?)))).*);
}

test "generated attribute payload leases balance across replacement and snapshot" {
    const model = comptime hsm.Define("TrackedAttributePayload", .{
        hsm.Attribute("count", @as(i32, 0)),
        hsm.Initial(hsm.Target("idle")),
        hsm.State("idle", .{}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    var tracking = TrackingAllocator{ .backing = testing.allocator };
    var context = hsm.Context.init(tracking.allocator());
    var instance = TestInstance.init();

    {
        var machine = try hsm.Started(&context, &instance, &built_model);
        try machine.Set(&context, "count", @as(i32, 1));
        var snapshot = try machine.TakeSnapshot();
        snapshot.deinit();
        try machine.Set(&context, "count", @as(i32, 2));
        machine.deinit();
    }

    try testing.expectEqual(@as(usize, 0), tracking.live);
    try testing.expectEqual(tracking.allocations, tracking.frees);
}
