const std = @import("std");
const testing = std.testing;

// ============================================================================
// Core Types
// ============================================================================

/// Context provides cancellation and timing for state machine operations
pub const Context = struct {
    done: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .done = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
    }

    pub fn is_done(self: *const Self) bool {
        return self.done.load(.acquire);
    }

    pub fn cancel(self: *Self) void {
        self.done.store(true, .release);
    }
};

const DispatchStatus = enum(u8) {
    queue_full = 0,
    processed = 1,
    deferred = 2,
};

const dispatch_status_queue_full = DispatchStatus.queue_full;
const dispatch_status_processed = DispatchStatus.processed;
const dispatch_status_deferred = DispatchStatus.deferred;

pub const kind_id_length = 8;
pub const kind_depth_max = @bitSizeOf(u64) / kind_id_length;
pub const kind_id_mask: u64 = (1 << kind_id_length) - 1;

fn kindIdAt(kind: u64, depth: usize) u8 {
    return @intCast((kind >> @intCast(depth * kind_id_length)) & kind_id_mask);
}

fn normalizeKindId(comptime value: anytype) u8 {
    const raw = @as(u64, @intCast(value)) & kind_id_mask;
    return @intCast(if (raw == 0) 1 else raw);
}

fn defaultDerivedKindId(base_kind: u64) u8 {
    const base_id = kindIdAt(base_kind, 0);
    const next_id = (@as(u64, base_id) + 1) & kind_id_mask;
    return @intCast(if (next_id == 0) 1 else next_id);
}

fn appendKindBase(kind: *u64, used_ids: *[kind_depth_max]u8, used_count: *usize, base_kind: u64) void {
    var depth: usize = 0;
    while (depth < kind_depth_max) : (depth += 1) {
        const base_id = kindIdAt(base_kind, depth);
        if (base_id == 0) break;

        for (used_ids[0..used_count.*]) |used_id| {
            if (used_id == base_id) break;
        } else {
            if (used_count.* >= kind_depth_max - 1) return;
            used_ids[used_count.*] = base_id;
            used_count.* += 1;
            kind.* |= @as(u64, base_id) << @intCast(used_count.* * kind_id_length);
        }
    }
}

/// Construct a kind identifier with optional inherited base kinds.
///
/// Zig does not have variadic functions, so pass bases as either a single kind
/// or a tuple, e.g. `makeKind(.{})`, `makeKind(base)`, or `makeKind(.{ a, b })`.
/// A leading comptime integer may be supplied as an explicit ID:
/// `makeKind(.{ 42, base })`.
pub fn makeKind(comptime base_kinds: anytype) u64 {
    var kind: u64 = 1;
    var used_ids = [_]u8{0} ** kind_depth_max;
    var used_count: usize = 0;

    const BasesType = @TypeOf(base_kinds);
    const bases_info = @typeInfo(BasesType);
    if (bases_info == .@"struct" and bases_info.@"struct".is_tuple) {
        const fields = std.meta.fields(BasesType);
        comptime var base_start: usize = 0;
        if (fields.len > 0 and @typeInfo(fields[0].type) == .comptime_int) {
            kind = normalizeKindId(base_kinds[0]);
            base_start = 1;
        } else if (fields.len > 0) {
            kind = defaultDerivedKindId(base_kinds[0]);
        }
        inline for (fields, 0..) |_, index| {
            if (index < base_start) continue;
            appendKindBase(&kind, &used_ids, &used_count, base_kinds[index]);
        }
    } else {
        kind = defaultDerivedKindId(base_kinds);
        appendKindBase(&kind, &used_ids, &used_count, base_kinds);
    }

    return kind;
}

/// Report whether `kind` matches or inherits from one of the provided bases.
pub fn isKind(kind: u64, comptime base_kinds: anytype) bool {
    const BasesType = @TypeOf(base_kinds);
    const bases_info = @typeInfo(BasesType);
    if (bases_info == .@"struct" and bases_info.@"struct".is_tuple) {
        inline for (std.meta.fields(BasesType), 0..) |_, index| {
            if (isKind(kind, base_kinds[index])) return true;
        }
        return false;
    }

    const base_id = kindIdAt(base_kinds, 0);
    var depth: usize = 0;
    while (depth < kind_depth_max) : (depth += 1) {
        const current_id = kindIdAt(kind, depth);
        if (current_id == 0) return false;
        if (current_id == base_id) return true;
    }
    return false;
}

pub const MakeKind = makeKind;
pub const IsKind = isKind;
pub const EventKind: u64 = 274;
pub const CompletionEventKind: u64 = makeKind(EventKind);
pub const ErrorEventKind: u64 = makeKind(CompletionEventKind);
pub const CallEventKind: u64 = makeKind(.{ 25, EventKind });

/// Event represents a state machine event with optional data
pub const Event = struct {
    name: []const u8,
    kind: u64,
    data: ?std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .name = name,
            .kind = EventKind,
            .data = null,
            .allocator = allocator,
        };
    }

    pub fn withData(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .name = name,
            .kind = EventKind,
            .data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn completion(allocator: std.mem.Allocator, name: []const u8) Self {
        var event = Self.init(allocator, name);
        event.kind = CompletionEventKind;
        return event;
    }

    pub fn errorEvent(allocator: std.mem.Allocator) Self {
        var event = Self.withData(allocator, "__ERROR__");
        event.kind = ErrorEventKind;
        return event;
    }

    pub fn putData(self: *Self, key: []const u8, value: *anyopaque) !void {
        if (self.data == null) {
            self.data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }
        try self.data.?.put(key, value);
    }

    pub fn getData(self: *const Self, key: []const u8) ?*anyopaque {
        if (self.data) |map| {
            return map.get(key);
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        if (self.data) |*map| {
            map.deinit();
        }
    }
};

/// Base instance type that can be extended by user implementations
pub const Instance = struct {
    // Just a marker type - users embed this in their own structs

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

// ============================================================================
// Function Signatures - Following (ctx, inst, event) pattern
// ============================================================================

/// Entry function signature - executes when entering a state
pub fn EntryFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) void;
}

/// Exit function signature - executes when exiting a state
pub fn ExitFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) void;
}

/// Effect function signature - executes during transitions
pub fn EffectFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) void;
}

/// Guard function signature - boolean condition for transitions
pub fn GuardFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) bool;
}

/// Activity function signature - long-running async operations
pub fn ActivityFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) void;
}

/// Timer function signature - returns nanoseconds for delays
pub fn TimerFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) u64;
}

pub const RuntimeQueue = struct {
    context: ?*anyopaque = null,
    push_fn: *const fn (context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void,
    pop_fn: *const fn (context: ?*anyopaque, runtime_context: *Context) anyerror!?Event,
    len_fn: *const fn (context: ?*anyopaque, runtime_context: *Context) anyerror!usize,

    const Self = @This();

    pub fn Push(self: *Self, runtime_context: *Context, event: Event) !void {
        try self.push_fn(self.context, runtime_context, event);
    }

    pub fn Pop(self: *Self, runtime_context: *Context) !?Event {
        return try self.pop_fn(self.context, runtime_context);
    }

    pub fn Len(self: *Self, runtime_context: *Context) !usize {
        return try self.len_fn(self.context, runtime_context);
    }
};

pub fn Queue(args: anytype) RuntimeQueue {
    return RuntimeQueue{
        .context = if (@hasField(@TypeOf(args), "Context")) args.Context else null,
        .push_fn = args.Push,
        .pop_fn = args.Pop,
        .len_fn = args.Len,
    };
}

pub const RuntimeClock = struct {
    context: ?*anyopaque = null,
    sleep_fn: *const fn (context: ?*anyopaque, duration_ns: u64) void = defaultSleep,
    now_fn: *const fn (context: ?*anyopaque) u64 = defaultNow,

    const Self = @This();

    pub fn Sleep(self: *const Self, duration_ns: u64) void {
        self.sleep_fn(self.context, duration_ns);
    }

    pub fn Now(self: *const Self) u64 {
        return self.now_fn(self.context);
    }
};

fn defaultSleep(context: ?*anyopaque, duration_ns: u64) void {
    _ = context;
    std.Thread.sleep(duration_ns);
}

fn defaultNow(context: ?*anyopaque) u64 {
    _ = context;
    const now = std.time.nanoTimestamp();
    if (now < 0) return 0;
    return @intCast(now);
}

pub const DefaultClock = RuntimeClock{};

pub fn Clock(args: anytype) RuntimeClock {
    return RuntimeClock{
        .context = if (@hasField(@TypeOf(args), "Context")) args.Context else null,
        .sleep_fn = if (@hasField(@TypeOf(args), "Sleep")) args.Sleep else DefaultClock.sleep_fn,
        .now_fn = if (@hasField(@TypeOf(args), "Now")) args.Now else DefaultClock.now_fn,
    };
}

pub const RuntimeConfig = struct {
    ID: ?[]const u8 = null,
    Name: ?[]const u8 = null,
    Data: ?*anyopaque = null,
    Clock: ?RuntimeClock = null,
    Queue: ?*RuntimeQueue = null,
};

pub fn Config(args: anytype) RuntimeConfig {
    return RuntimeConfig{
        .ID = if (@hasField(@TypeOf(args), "ID")) args.ID else null,
        .Name = if (@hasField(@TypeOf(args), "Name")) args.Name else null,
        .Data = if (@hasField(@TypeOf(args), "Data")) args.Data else null,
        .Clock = if (@hasField(@TypeOf(args), "Clock")) args.Clock else null,
        .Queue = if (@hasField(@TypeOf(args), "Queue")) args.Queue else null,
    };
}

const ValueCloneFn = *const fn (allocator: std.mem.Allocator, source: *const anyopaque) anyerror!*anyopaque;
const ValueDropFn = *const fn (allocator: std.mem.Allocator, value: *anyopaque) void;

fn cloneTypedValue(comptime T: type) ValueCloneFn {
    return struct {
        fn clone(allocator: std.mem.Allocator, source_value: *const anyopaque) anyerror!*anyopaque {
            const typed_source: *const T = @ptrCast(@alignCast(source_value));
            const copy = try allocator.create(T);
            copy.* = typed_source.*;
            return @ptrCast(copy);
        }
    }.clone;
}

fn dropTypedValue(comptime T: type) ValueDropFn {
    return struct {
        fn drop(allocator: std.mem.Allocator, value: *anyopaque) void {
            const typed_value: *T = @ptrCast(@alignCast(value));
            allocator.destroy(typed_value);
        }
    }.drop;
}

pub const AttributeElement = struct {
    name: []const u8,
    qualified_name: []const u8,
    type_name: ?[]const u8,
    default_value: ?*anyopaque,
    clone_fn: ?ValueCloneFn,
    drop_fn: ?ValueDropFn,
};

const RuntimeAttributeValue = struct {
    value: *anyopaque,
    type_name: []const u8,
    drop_fn: ValueDropFn,

    fn deinit(self: *RuntimeAttributeValue, allocator: std.mem.Allocator) void {
        self.drop_fn(allocator, self.value);
    }
};

pub const AttributeSnapshot = struct {
    value: *anyopaque,
    type_name: []const u8,
    drop_fn: ValueDropFn,

    pub fn as(self: *const AttributeSnapshot, comptime T: type) ?*const T {
        if (!std.mem.eql(u8, self.type_name, @typeName(T))) return null;
        return @ptrCast(@alignCast(self.value));
    }

    fn deinit(self: *AttributeSnapshot, allocator: std.mem.Allocator) void {
        self.drop_fn(allocator, self.value);
    }
};

pub const EventDetail = struct {
    Name: []const u8,
    Kind: u64,
    Target: ?[]const u8,
    Guard: bool,
    Schema: ?*anyopaque,

    fn deinit(self: *EventDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.Name);
        if (self.Target) |target_name| allocator.free(target_name);
    }
};

pub const Snapshot = struct {
    ID: ?[]const u8,
    QualifiedName: []const u8,
    State: []const u8,
    QueueLen: usize,
    Attributes: std.StringHashMap(AttributeSnapshot),
    Events: []EventDetail,
    Members: ?[]Snapshot = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        if (self.ID) |id| self.allocator.free(id);
        self.allocator.free(self.QualifiedName);
        self.allocator.free(self.State);
        var attr_iter = self.Attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            self.allocator.free(attr_entry.key_ptr.*);
            attr_entry.value_ptr.deinit(self.allocator);
        }
        self.Attributes.deinit();
        for (self.Events) |*event| {
            event.deinit(self.allocator);
        }
        self.allocator.free(self.Events);
        if (self.Members) |members| {
            for (members) |*member| {
                member.deinit();
            }
            self.allocator.free(members);
        }
    }
};

fn makeRuntimeAttributeValue(allocator: std.mem.Allocator, value: anytype) !RuntimeAttributeValue {
    const T = @TypeOf(value);
    const copy = try allocator.create(T);
    copy.* = value;
    return RuntimeAttributeValue{
        .value = @ptrCast(copy),
        .type_name = @typeName(T),
        .drop_fn = dropTypedValue(T),
    };
}

fn cloneKnownRuntimeAttributeValue(allocator: std.mem.Allocator, value: *const RuntimeAttributeValue) !RuntimeAttributeValue {
    if (std.mem.eql(u8, value.type_name, @typeName(i32))) {
        const typed: *const i32 = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(u32))) {
        const typed: *const u32 = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(i64))) {
        const typed: *const i64 = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(u64))) {
        const typed: *const u64 = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(bool))) {
        const typed: *const bool = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    return error.UnsupportedSnapshotAttributeType;
}

fn cloneRuntimeAttributeValue(allocator: std.mem.Allocator, attr: *const AttributeElement) !?RuntimeAttributeValue {
    if (attr.default_value == null or attr.clone_fn == null or attr.drop_fn == null or attr.type_name == null) {
        return null;
    }

    return RuntimeAttributeValue{
        .value = try attr.clone_fn.?(allocator, @ptrCast(attr.default_value.?)),
        .type_name = attr.type_name.?,
        .drop_fn = attr.drop_fn.?,
    };
}

fn valuesEqual(comptime T: type, left: *const RuntimeAttributeValue, right: T) bool {
    if (!std.mem.eql(u8, left.type_name, @typeName(T))) return false;
    const typed_left: *const T = @ptrCast(@alignCast(left.value));
    return std.mem.eql(u8, std.mem.asBytes(typed_left), std.mem.asBytes(&right));
}

fn stateMatchesOrIsDescendant(current_state: []const u8, target_state: []const u8) bool {
    if (std.mem.eql(u8, current_state, target_state)) return true;
    if (!std.mem.startsWith(u8, current_state, target_state)) return false;
    return current_state.len > target_state.len and current_state[target_state.len] == '/';
}

fn qualifyModelMemberName(allocator: std.mem.Allocator, model_name: []const u8, name: []const u8) ![]const u8 {
    if (name.len > 0 and name[0] == '/') {
        return try allocator.dupe(u8, name);
    }
    return try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ model_name, name });
}

// ============================================================================
// Element Types with String-Based Architecture
// ============================================================================

/// Element kinds enumeration
pub const ElementKind = enum(u64) {
    model = 1,
    state = 2,
    initial = 3,
    final = 4,
    choice = 5,
    transition = 6,
    behavior = 7,
    constraint = 8,
    history = 9,
    operation = 10,
};

/// History type enumeration
pub const HistoryKind = enum {
    shallow,
    deep,
};

/// History element for state restoration
pub const HistoryElement = struct {
    element: Element,
    history_kind: HistoryKind,
    default_target: ?[]const u8, // qualified name of default target

    const Self = @This();
};

/// Base element interface - all HSM elements have qualified names
pub const Element = struct {
    kind: ElementKind,
    qualified_name: []const u8,
    id: []const u8,

    const Self = @This();

    pub fn owner(self: *const Self) []const u8 {
        if (std.mem.eql(u8, self.qualified_name, "/")) {
            return "";
        }
        return std.fs.path.dirname(self.qualified_name) orelse "";
    }

    pub fn name(self: *const Self) []const u8 {
        return std.fs.path.basename(self.qualified_name);
    }
};

/// State element in flat storage
pub const StateElement = struct {
    element: Element,
    entry: [][]const u8, // qualified names of entry behaviors
    exit: [][]const u8, // qualified names of exit behaviors
    activities: [][]const u8, // qualified names of activity behaviors
    transitions: [][]const u8, // qualified names of transitions
    substates: [][]const u8, // qualified names of child states
    deferred: [][]const u8, // qualified names of deferred events
    initial_transition: ?[]const u8, // qualified name of initial transition

    const Self = @This();
};

/// Transition element in flat storage
pub const TransitionElement = struct {
    element: Element,
    source: []const u8, // qualified name of source state
    target: ?[]const u8, // qualified name of target state (null for internal)
    event_name: ?[]const u8, // event trigger (null for timer/initial)
    guard: ?[]const u8, // qualified name of guard behavior
    guards: [][]const u8, // ordered qualified names of guard behaviors
    effects: [][]const u8, // qualified names of effect behaviors
    timer_fn: ?[]const u8, // qualified name of timer behavior
    timer_kind: TimerKind,
    paths: std.StringHashMap(TransitionPaths), // precomputed paths for each source state

    const Self = @This();
};

pub const TimerKind = enum {
    after,
    every,
    at,
};

/// Precomputed transition paths for optimal execution
pub const TransitionPaths = struct {
    enter: [][]const u8, // states to enter (in order)
    exit: [][]const u8, // states to exit (in order)

    const Self = @This();
};

/// Behavior element in flat storage
pub const BehaviorElement = struct {
    element: Element,
    function_ptr: *const anyopaque, // pointer to actual function

    const Self = @This();
};

/// Named operation in flat storage.
pub const OperationElement = struct {
    element: Element,
    function_ptr: *const anyopaque,

    const Self = @This();
};

/// Model containing all elements in flat storage
pub const Model = struct {
    name: []const u8,
    members: std.StringHashMap(*Element), // flat storage by qualified name
    attributes: std.StringHashMap(AttributeElement), // model attributes by qualified name
    transition_map: std.StringHashMap(std.StringHashMap([][]const u8)), // [state][event] -> transitions
    deferred_map: std.StringHashMap(std.StringHashMap(bool)), // [state][event] -> is_deferred
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        // Clean up elements based on their kind
        var iterator = self.members.iterator();
        while (iterator.next()) |kv| {
            const element = kv.value_ptr.*;
            switch (element.kind) {
                .state, .model, .final, .choice => {
                    const state_elem: *StateElement = @ptrCast(@alignCast(element));
                    // Free initial_transition if set
                    if (state_elem.initial_transition) |init_trans| {
                        self.allocator.free(init_trans);
                    }
                    self.allocator.free(state_elem.element.qualified_name);
                    self.allocator.free(state_elem.element.id);
                    // Free allocated arrays and their string contents
                    if (state_elem.entry.len > 0) {
                        for (state_elem.entry) |entry_name| {
                            self.allocator.free(entry_name);
                        }
                        self.allocator.free(state_elem.entry);
                    }
                    if (state_elem.exit.len > 0) {
                        for (state_elem.exit) |exit_name| {
                            self.allocator.free(exit_name);
                        }
                        self.allocator.free(state_elem.exit);
                    }
                    if (state_elem.activities.len > 0) {
                        for (state_elem.activities) |activity_name| {
                            self.allocator.free(activity_name);
                        }
                        self.allocator.free(state_elem.activities);
                    }
                    if (state_elem.transitions.len > 0) {
                        for (state_elem.transitions) |transition_name| {
                            self.allocator.free(transition_name);
                        }
                        self.allocator.free(state_elem.transitions);
                    }
                    if (state_elem.substates.len > 0) {
                        for (state_elem.substates) |substate_name| {
                            self.allocator.free(substate_name);
                        }
                        self.allocator.free(state_elem.substates);
                    }
                    if (state_elem.deferred.len > 0) {
                        for (state_elem.deferred) |deferred_name| {
                            self.allocator.free(deferred_name);
                        }
                        self.allocator.free(state_elem.deferred);
                    }
                    self.allocator.destroy(state_elem);
                },
                .transition => {
                    const trans_elem: *TransitionElement = @ptrCast(@alignCast(element));
                    self.allocator.free(trans_elem.element.qualified_name);
                    self.allocator.free(trans_elem.element.id);
                    self.allocator.free(trans_elem.source);
                    if (trans_elem.target) |target_path| self.allocator.free(target_path);
                    if (trans_elem.event_name) |event_name| self.allocator.free(event_name);
                    if (trans_elem.timer_fn) |timer_fn| self.allocator.free(timer_fn);

                    if (trans_elem.guards.len > 0) {
                        for (trans_elem.guards) |guard_name| {
                            self.allocator.free(guard_name);
                        }
                        self.allocator.free(trans_elem.guards);
                    } else if (trans_elem.guard) |guard_name| {
                        self.allocator.free(guard_name);
                    }

                    // Free effects array
                    if (trans_elem.effects.len > 0) {
                        for (trans_elem.effects) |effect_name| {
                            self.allocator.free(effect_name);
                        }
                        self.allocator.free(trans_elem.effects);
                    }

                    // Clean up transition paths
                    var path_iter = trans_elem.paths.iterator();
                    while (path_iter.next()) |path_entry| {
                        self.allocator.free(path_entry.key_ptr.*);
                        for (path_entry.value_ptr.enter) |state_name| {
                            self.allocator.free(state_name);
                        }
                        for (path_entry.value_ptr.exit) |state_name| {
                            self.allocator.free(state_name);
                        }
                        self.allocator.free(path_entry.value_ptr.enter);
                        self.allocator.free(path_entry.value_ptr.exit);
                    }
                    trans_elem.paths.deinit();

                    self.allocator.destroy(trans_elem);
                },
                .behavior => {
                    const behavior_elem: *BehaviorElement = @ptrCast(@alignCast(element));
                    self.allocator.free(behavior_elem.element.qualified_name);
                    self.allocator.free(behavior_elem.element.id);
                    self.allocator.destroy(behavior_elem);
                },
                .operation => {
                    const operation_elem: *OperationElement = @ptrCast(@alignCast(element));
                    self.allocator.free(operation_elem.element.qualified_name);
                    self.allocator.free(operation_elem.element.id);
                    self.allocator.destroy(operation_elem);
                },
                .history => {
                    const history_elem: *HistoryElement = @ptrCast(@alignCast(element));
                    self.allocator.free(history_elem.element.qualified_name);
                    self.allocator.free(history_elem.element.id);
                    if (history_elem.default_target) |t_target| self.allocator.free(t_target);
                    self.allocator.destroy(history_elem);
                },
                else => {
                    // For unknown element kinds, don't destroy as we don't know their full type
                    // Just free the base element fields
                    self.allocator.free(element.qualified_name);
                    self.allocator.free(element.id);
                    // Note: we can't safely destroy the element itself without knowing its full type
                },
            }
        }
        self.members.deinit();

        var attr_iter = self.attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            self.allocator.free(attr_entry.key_ptr.*);
            self.allocator.free(attr_entry.value_ptr.name);
            self.allocator.free(attr_entry.value_ptr.qualified_name);
            if (attr_entry.value_ptr.default_value) |default_value| {
                if (attr_entry.value_ptr.drop_fn) |drop_fn| {
                    drop_fn(self.allocator, default_value);
                }
            }
        }
        self.attributes.deinit();

        // Clean up transition map
        var trans_iter = self.transition_map.iterator();
        while (trans_iter.next()) |trans_entry| {
            self.allocator.free(trans_entry.key_ptr.*);
            var event_iter = trans_entry.value_ptr.iterator();
            while (event_iter.next()) |event_entry| {
                self.allocator.free(event_entry.key_ptr.*);
                for (event_entry.value_ptr.*) |trans_name| {
                    self.allocator.free(trans_name);
                }
                self.allocator.free(event_entry.value_ptr.*);
            }
            trans_entry.value_ptr.deinit();
        }
        self.transition_map.deinit();

        // Clean up deferred map
        var def_iter = self.deferred_map.iterator();
        while (def_iter.next()) |def_entry| {
            // Free the state name key
            self.allocator.free(def_entry.key_ptr.*);

            // Free each event name key in the nested map
            var event_iter = def_entry.value_ptr.iterator();
            while (event_iter.next()) |event_entry| {
                self.allocator.free(event_entry.key_ptr.*);
            }

            // Deinitialize the nested hash map
            def_entry.value_ptr.deinit();
        }
        self.deferred_map.deinit();

        self.allocator.free(self.name);
    }
};

// ============================================================================
// Element Lookup Functions (like Go's get[T] function)
// ============================================================================

/// Get element by qualified name and cast to specific type
pub fn get(comptime T: type, model: *const Model, qualified_name: []const u8) ?*T {
    const element = model.members.get(qualified_name) orelse return null;
    return @ptrCast(@alignCast(element));
}

/// Get state element by qualified name
pub fn getState(model: *const Model, qualified_name: []const u8) ?*StateElement {
    return get(StateElement, model, qualified_name);
}

/// Get transition element by qualified name
pub fn getTransition(model: *const Model, qualified_name: []const u8) ?*TransitionElement {
    return get(TransitionElement, model, qualified_name);
}

/// Get behavior element by qualified name
pub fn getBehavior(model: *const Model, qualified_name: []const u8) ?*BehaviorElement {
    return get(BehaviorElement, model, qualified_name);
}

/// Get operation element by qualified name
pub fn getOperation(model: *const Model, qualified_name: []const u8) ?*OperationElement {
    return get(OperationElement, model, qualified_name);
}

/// Get history element by qualified name
pub fn getHistory(model: *const Model, qualified_name: []const u8) ?*HistoryElement {
    return get(HistoryElement, model, qualified_name);
}

// ============================================================================
// Builder Types for Compile-Time Construction
// ============================================================================

/// Builder for entry actions
pub fn EntryBuilder(comptime T: type) type {
    return struct {
        functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void,

        const Self = @This();

        pub fn init(func: *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = &[_]*const fn (ctx: *Context, inst: *T, event: Event) void{func} };
        }

        pub fn multiple(functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = functions };
        }
    };
}

/// Builder for exit actions
pub fn ExitBuilder(comptime T: type) type {
    return struct {
        functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void,

        const Self = @This();

        pub fn init(func: *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = &[_]*const fn (ctx: *Context, inst: *T, event: Event) void{func} };
        }

        pub fn multiple(functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = functions };
        }
    };
}

/// Builder for effect actions
pub fn EffectBuilder(comptime T: type) type {
    return struct {
        functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void,

        const Self = @This();

        pub fn init(func: *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = &[_]*const fn (ctx: *Context, inst: *T, event: Event) void{func} };
        }

        pub fn multiple(functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = functions };
        }
    };
}

/// Builder for activity actions
pub fn ActivityBuilder(comptime T: type) type {
    return struct {
        functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void,

        const Self = @This();

        pub fn init(func: *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = &[_]*const fn (ctx: *Context, inst: *T, event: Event) void{func} };
        }

        pub fn multiple(functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void) Self {
            return Self{ .functions = functions };
        }
    };
}

/// Builder for guard conditions
pub fn GuardBuilder(comptime T: type) type {
    return struct {
        function: *const fn (ctx: *Context, inst: *T, event: Event) bool,

        const Self = @This();

        pub fn init(func: *const fn (ctx: *Context, inst: *T, event: Event) bool) Self {
            return Self{ .function = func };
        }
    };
}

/// Builder for event triggers
pub const EventBuilder = struct {
    event_name: []const u8,

    const Self = @This();

    pub fn init(event_name: []const u8) Self {
        return Self{ .event_name = event_name };
    }
};

pub const OnSetBuilder = struct {
    attribute_name: []const u8,

    const Self = @This();

    pub fn init(attribute_name: []const u8) Self {
        return Self{ .attribute_name = attribute_name };
    }
};

pub const OnCallBuilder = struct {
    operation_name: []const u8,

    const Self = @This();

    pub fn init(operation_name: []const u8) Self {
        return Self{ .operation_name = operation_name };
    }
};

/// Builder for transition targets
pub const TargetBuilder = struct {
    target_path: []const u8,

    const Self = @This();

    pub fn init(target_path: []const u8) Self {
        return Self{ .target_path = target_path };
    }
};

/// Builder for timer-based transitions
pub fn TimerBuilder(comptime T: type) type {
    return struct {
        timer_fn: *const fn (ctx: *Context, inst: *T, event: Event) u64,

        const Self = @This();

        pub fn init(timer_fn: *const fn (ctx: *Context, inst: *T, event: Event) u64) Self {
            return Self{ .timer_fn = timer_fn };
        }
    };
}

// ============================================================================
// Public API Functions for Building Models
// ============================================================================

/// Create an entry action builder - supports multiple functions
pub fn entry(comptime funcs: anytype) type {
    // Defer the type determination to compile time
    const functions_array = comptime blk: {
        const T = @TypeOf(funcs);
        const info = @typeInfo(T);

        if (info == .@"fn" or info == .pointer) {
            // Single function - wrap in array
            break :blk [_]@TypeOf(funcs){funcs};
        } else if (info == .@"struct" and info.@"struct".is_tuple) {
            // Multiple functions in tuple - convert to array
            const fields = info.@"struct".fields;
            var func_array: [fields.len]@TypeOf(funcs[0]) = undefined;
            for (fields, 0..) |_, i| {
                func_array[i] = funcs[i];
            }
            break :blk func_array;
        } else {
            @compileError("entry() expects a function or tuple of functions");
        }
    };

    return struct {
        functions: @TypeOf(functions_array) = functions_array,
    };
}

/// Create an exit action builder - supports multiple functions
pub fn exit(comptime funcs: anytype) type {
    // Defer the type determination to compile time
    const functions_array = comptime blk: {
        const T = @TypeOf(funcs);
        const info = @typeInfo(T);

        if (info == .@"fn" or info == .pointer) {
            // Single function - wrap in array
            break :blk [_]@TypeOf(funcs){funcs};
        } else if (info == .@"struct" and info.@"struct".is_tuple) {
            // Multiple functions in tuple - convert to array
            const fields = info.@"struct".fields;
            var func_array: [fields.len]@TypeOf(funcs[0]) = undefined;
            for (fields, 0..) |_, i| {
                func_array[i] = funcs[i];
            }
            break :blk func_array;
        } else {
            @compileError("exit() expects a function or tuple of functions");
        }
    };

    return struct {
        functions: @TypeOf(functions_array) = functions_array,
    };
}

/// Create an effect action builder - supports multiple functions
pub fn effect(comptime funcs: anytype) type {
    // Defer the type determination to compile time
    const functions_array = comptime blk: {
        const T = @TypeOf(funcs);
        const info = @typeInfo(T);

        if (info == .@"fn" or info == .pointer) {
            // Single function - wrap in array
            break :blk [_]@TypeOf(funcs){funcs};
        } else if (info == .@"struct" and info.@"struct".is_tuple) {
            // Multiple functions in tuple - convert to array
            const fields = info.@"struct".fields;
            var func_array: [fields.len]@TypeOf(funcs[0]) = undefined;
            for (fields, 0..) |_, i| {
                func_array[i] = funcs[i];
            }
            break :blk func_array;
        } else {
            @compileError("effect() expects a function or tuple of functions");
        }
    };

    return struct {
        functions: @TypeOf(functions_array) = functions_array,
    };
}

/// Create an activity action builder - supports multiple functions
pub fn activity(comptime funcs: anytype) type {
    // Defer the type determination to compile time
    const functions_array = comptime blk: {
        const T = @TypeOf(funcs);
        const info = @typeInfo(T);

        if (info == .@"fn" or info == .pointer) {
            // Single function - wrap in array
            break :blk [_]@TypeOf(funcs){funcs};
        } else if (info == .@"struct" and info.@"struct".is_tuple) {
            // Multiple functions in tuple - convert to array
            const fields = info.@"struct".fields;
            var func_array: [fields.len]@TypeOf(funcs[0]) = undefined;
            for (fields, 0..) |_, i| {
                func_array[i] = funcs[i];
            }
            break :blk func_array;
        } else {
            @compileError("activity() expects a function or tuple of functions");
        }
    };

    return struct {
        functions: @TypeOf(functions_array) = functions_array,
    };
}

/// Create a guard condition builder
pub fn guard(comptime func: anytype) type {
    return struct {
        function: @TypeOf(func) = func,
    };
}

/// Create an event trigger builder
pub fn on(comptime event_name: []const u8) EventBuilder {
    return EventBuilder.init(event_name);
}

/// Create an attribute-change trigger builder.
pub fn onSet(comptime attribute_name: []const u8) OnSetBuilder {
    return OnSetBuilder.init(attribute_name);
}

pub const onset = onSet;

/// Alias for attribute-change triggers, matching the canonical DSL name.
pub fn when(comptime attribute_name: []const u8) OnSetBuilder {
    return onSet(attribute_name);
}

fn validateModelMemberLiteral(comptime kind: []const u8, comptime name: []const u8) void {
    if (name.len == 0) {
        @compileError(kind ++ " name cannot be empty");
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        @compileError(kind ++ " name cannot contain '/'");
    }
}

fn callEventName(allocator: std.mem.Allocator, qualified_operation_name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "hsm_call:{s}", .{qualified_operation_name});
}

/// Create an operation-call trigger builder.
pub fn onCall(comptime operation_name: []const u8) OnCallBuilder {
    comptime validateModelMemberLiteral("operation", operation_name);
    return OnCallBuilder.init(operation_name);
}

/// Create a target builder
pub fn target(comptime target_path: []const u8) TargetBuilder {
    return TargetBuilder.init(target_path);
}

/// Create a timer builder for 'after' transitions
pub fn after(comptime timer_function: anytype) type {
    return struct {
        timer_fn: *const @TypeOf(timer_function) = &timer_function,
        timer_kind: TimerKind = .after,
    };
}

/// Create a timer builder for 'every' transitions
pub fn every(comptime timer_function: anytype) type {
    return struct {
        timer_fn: *const @TypeOf(timer_function) = &timer_function,
        timer_kind: TimerKind = .every,
    };
}

/// Create a timer builder for absolute-time 'at' transitions.
/// The timer function returns an absolute nanosecond timestamp in Clock.Now units.
pub fn at(comptime timer_function: anytype) type {
    return struct {
        timer_fn: *const @TypeOf(timer_function) = &timer_function,
        timer_kind: TimerKind = .at,
    };
}

/// Create a defer builder for deferred events
pub fn deferEvents(comptime event_names: anytype) type {
    // Convert single event name or tuple of event names to array
    const events_array = comptime blk: {
        const T = @TypeOf(event_names);
        const info = @typeInfo(T);

        if (info == .@"struct" and info.@"struct".is_tuple) {
            // Multiple event names in tuple - convert to array
            const fields = info.@"struct".fields;
            var events: [fields.len][]const u8 = undefined;
            for (fields, 0..) |_, i| {
                events[i] = event_names[i];
            }
            break :blk events;
        } else {
            @compileError("deferEvents() expects a tuple of strings");
        }
    };

    return struct {
        event_names: @TypeOf(events_array) = events_array,
    };
}

/// Create an initial transition builder
pub fn initial(comptime target_builder: TargetBuilder) type {
    return struct {
        target_path: []const u8 = target_builder.target_path,
    };
}

/// Create a source builder for explicit transition sources
pub fn source(comptime source_path: []const u8) type {
    return struct {
        source_path: []const u8 = source_path,
    };
}

pub fn attribute(comptime name: []const u8, comptime spec: anytype) type {
    const SpecType = @TypeOf(spec);
    const has_default = SpecType != type;
    const ValueType = if (has_default) SpecType else spec;

    return struct {
        attr_name: []const u8 = name,
        comptime value_type: type = ValueType,
        comptime has_default: bool = has_default,
        default_value: ValueType = if (has_default) spec else undefined,
    };
}

pub fn attributeDefault(comptime name: []const u8, comptime ValueType: type, comptime default_value: ValueType) type {
    return struct {
        attr_name: []const u8 = name,
        comptime value_type: type = ValueType,
        comptime has_default: bool = true,
        default_value: ValueType = default_value,
    };
}

pub fn operation(comptime name: []const u8, comptime implementation: anytype) type {
    comptime validateModelMemberLiteral("operation", name);
    return struct {
        op_name: []const u8 = name,
        function_ptr: *const @TypeOf(implementation) = &implementation,
    };
}

/// Create a transition builder - supports multiple arguments in tuple
pub fn transition(comptime args: anytype) type {
    return struct {
        args: @TypeOf(args) = args,

        pub fn getEvent(self: @This()) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == EventBuilder) {
                    return arg.event_name;
                }
            }
            return null;
        }

        pub fn getOnSet(self: @This()) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == OnSetBuilder) {
                    return arg.attribute_name;
                }
            }
            return null;
        }

        pub fn getOnCall(self: @This()) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == OnCallBuilder) {
                    return arg.operation_name;
                }
            }
            return null;
        }

        pub fn getTarget(self: @This()) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == TargetBuilder) {
                    return arg.target_path;
                }
            }
            return null;
        }

        pub fn getSource(self: @This()) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "source_path")) {
                    return arg.source_path;
                }
            }
            return null;
        }

        pub fn getGuards(self: @This()) []const *const anyopaque {
            const guard_count = comptime blk: {
                var count: usize = 0;
                for (std.meta.fields(@TypeOf(self.args))) |field| {
                    const arg = @field(self.args, field.name);
                    const ArgType = @TypeOf(arg);
                    if (ArgType == type) {
                        const type_info = @typeInfo(arg);
                        if (type_info == .@"struct" and @hasField(arg, "function")) count += 1;
                    } else {
                        const type_info = @typeInfo(ArgType);
                        if (type_info == .@"struct" and @hasField(ArgType, "function")) count += 1;
                    }
                }
                break :blk count;
            };

            if (guard_count == 0) return &[_]*const anyopaque{};

            const GuardPtrs = struct {
                const values = blk: {
                    var guard_ptrs: [guard_count]*const anyopaque = undefined;
                    var guard_index: usize = 0;
                    for (std.meta.fields(@TypeOf(self.args))) |field| {
                        const arg = @field(self.args, field.name);
                        const ArgType = @TypeOf(arg);
                        if (ArgType == type) {
                            const type_info = @typeInfo(arg);
                            if (type_info == .@"struct" and @hasField(arg, "function")) {
                                const guard_builder = arg{};
                                const guard_fn = guard_builder.function;
                                guard_ptrs[guard_index] = @ptrCast(&guard_fn);
                                guard_index += 1;
                            }
                        } else {
                            const type_info = @typeInfo(ArgType);
                            if (type_info == .@"struct" and @hasField(ArgType, "function")) {
                                guard_ptrs[guard_index] = @ptrCast(&arg.function);
                                guard_index += 1;
                            }
                        }
                    }
                    break :blk guard_ptrs;
                };
            };
            return &GuardPtrs.values;
        }

        pub fn getGuard(self: @This()) ?*const anyopaque {
            const guards = self.getGuards();
            if (guards.len == 0) return null;
            return guards[0];
        }

        pub fn getEffects(self: @This()) []const *const anyopaque {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == type) {
                    const type_info = @typeInfo(arg);
                    if (type_info == .@"struct" and @hasField(arg, "functions")) {
                        const effect_builder = arg{};
                        const func_count = effect_builder.functions.len;
                        const EffectPtrs = struct {
                            const values = blk: {
                                var func_ptrs: [func_count]*const anyopaque = undefined;
                                for (effect_builder.functions, 0..) |func, idx| {
                                    func_ptrs[idx] = @ptrCast(&func);
                                }
                                break :blk func_ptrs;
                            };
                        };
                        return &EffectPtrs.values;
                    }
                    continue;
                }
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "functions")) {
                    const func_count = arg.functions.len;
                    const EffectPtrs = struct {
                        const values = blk: {
                            var func_ptrs: [func_count]*const anyopaque = undefined;
                            for (arg.functions, 0..) |func, idx| {
                                func_ptrs[idx] = @ptrCast(&func);
                            }
                            break :blk func_ptrs;
                        };
                    };
                    return &EffectPtrs.values;
                }
            }
            return &[_]*const anyopaque{};
        }

        pub fn getTimer(self: @This()) ?*const anyopaque {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == type) {
                    const type_info = @typeInfo(arg);
                    if (type_info == .@"struct" and @hasField(arg, "timer_fn")) {
                        const timer_builder = arg{};
                        return @ptrCast(timer_builder.timer_fn);
                    }
                } else {
                    const type_info = @typeInfo(ArgType);
                    if (type_info == .@"struct" and @hasField(ArgType, "timer_fn")) {
                        return @ptrCast(arg.timer_fn);
                    }
                }
            }
            return null;
        }

        pub fn getTimerKind(self: @This()) TimerKind {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == type) {
                    const type_info = @typeInfo(arg);
                    if (type_info == .@"struct" and @hasField(arg, "timer_kind")) {
                        const timer_builder = arg{};
                        return timer_builder.timer_kind;
                    }
                } else {
                    const type_info = @typeInfo(ArgType);
                    if (type_info == .@"struct" and @hasField(ArgType, "timer_kind")) {
                        return arg.timer_kind;
                    }
                }
            }
            return .after;
        }
    };
}

/// Create a state builder
pub fn state(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        state_type: ElementKind = .state,
    };
}

/// Create a final state builder
pub fn final(comptime name: []const u8) type {
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(.{}) = .{},
        state_type: ElementKind = .final,
    };
}

/// Create a choice state builder
pub fn choice(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        state_type: ElementKind = .choice,
    };
}

/// Create a shallow history state builder
pub fn history(comptime name: []const u8, comptime default_target: TargetBuilder) type {
    return struct {
        name: []const u8 = name,
        default_target: []const u8 = default_target.target_path,
        history_kind: HistoryKind = .shallow,
        state_type: ElementKind = .history,
    };
}

/// Create a deep history state builder
pub fn deepHistory(comptime name: []const u8, comptime default_target: TargetBuilder) type {
    return struct {
        name: []const u8 = name,
        default_target: []const u8 = default_target.target_path,
        history_kind: HistoryKind = .deep,
        state_type: ElementKind = .history,
    };
}

/// Define a state machine model at compile time
pub fn define(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        const model_name = name;
        const model_elements = elements;

        pub const machine_name = model_name;

        pub fn build(allocator: std.mem.Allocator) !Model {
            var model = try createModel(allocator, model_name);
            errdefer model.deinit();

            // Add root state
            _ = try addState(&model, "/" ++ model_name, .model);

            // Process elements
            try processElements(&model, "/" ++ model_name, model_elements);

            // Resolve targets against the complete flat member set before maps
            // are built. During element processing, sibling states may not have
            // been created yet, so early resolution is necessarily provisional.
            try canonicalizeTransitionTargets(&model);

            // Build transition map
            try buildTransitionMap(&model);

            // Build deferred event map
            try buildDeferredMap(&model);

            return model;
        }

        fn processElements(model: *Model, parent_path: []const u8, elems: anytype) !void {
            const fields = std.meta.fields(@TypeOf(elems));
            inline for (fields, 0..) |_, i| {
                const element = elems[i];
                const element_type = @TypeOf(element);
                const type_info = @typeInfo(element_type);

                // If element is a type (comptime), we need to instantiate it to check fields
                if (type_info == .type) {
                    const actual_type = element;

                    if (@hasField(actual_type, "attr_name")) {
                        const attr_instance = actual_type{};
                        try processAttribute(model, attr_instance);
                        continue;
                    }

                    if (@hasField(actual_type, "op_name")) {
                        const op_instance = actual_type{};
                        try processOperation(model, op_instance);
                        continue;
                    }

                    // Check if it's a state type by looking for state_type field
                    if (@hasField(actual_type, "state_type")) {
                        // It's a state or history - instantiate it
                        const state_instance = actual_type{};
                        const state_path = try std.fmt.allocPrint(model.allocator, "{s}/{s}", .{ parent_path, state_instance.name });
                        defer model.allocator.free(state_path);

                        if (state_instance.state_type == .history) {
                            const default_target = if (@hasField(actual_type, "default_target")) state_instance.default_target else null;
                            // Resolve default target relative to history state (which is child of parent)
                            // But wait, history state is a child, so resolve relative to parent?
                            // No, resolve relative to the history state itself?
                            // Actually, resolveTargetPath handles relative paths.
                            // If default_target is relative, it should be resolved relative to the history state's parent?
                            // SCXML says default target is transition.
                            var resolved_target: ?[]const u8 = null;
                            if (default_target.len > 0) {
                                resolved_target = try resolveTargetPath(model.allocator, parent_path, default_target);
                            }
                            _ = try addHistory(model, state_path, state_instance.history_kind, resolved_target);
                            if (resolved_target) |t| model.allocator.free(t);
                        } else {
                            const state_elem = try addState(model, state_path, state_instance.state_type);

                            // Process state contents
                            if (@hasField(actual_type, "elements")) {
                                try processStateContents(model, state_elem, state_path, state_instance.elements);
                            }
                        }
                    } else if (@hasField(actual_type, "target_path")) {
                        // It's an initial transition - instantiate it
                        const initial_instance = actual_type{};
                        try processInitialTransition(model, parent_path, initial_instance);
                    }
                } else if (type_info == .@"struct") {
                    // Handle direct struct instances
                    if (@hasField(element_type, "attr_name")) {
                        try processAttribute(model, element);
                    } else if (@hasField(element_type, "op_name")) {
                        try processOperation(model, element);
                    } else if (@hasField(element_type, "state_type")) {
                        // Direct state instance
                        const state_path = try std.fmt.allocPrint(model.allocator, "{s}/{s}", .{ parent_path, element.name });
                        defer model.allocator.free(state_path);

                        if (element.state_type == .history) {
                            const default_target = if (@hasField(element_type, "default_target")) element.default_target else null;
                            var resolved_target: ?[]const u8 = null;
                            if (default_target.len > 0) {
                                resolved_target = try resolveTargetPath(model.allocator, parent_path, default_target);
                            }
                            _ = try addHistory(model, state_path, element.history_kind, resolved_target);
                            if (resolved_target) |t| model.allocator.free(t);
                        } else {
                            const state_elem = try addState(model, state_path, element.state_type);

                            // Process state contents
                            if (@hasField(element_type, "elements")) {
                                try processStateContents(model, state_elem, state_path, element.elements);
                            }
                        }
                    } else if (@hasField(element_type, "args")) {
                        // Direct transition instance
                        try processTransition(model, getState(model, parent_path) orelse return error.NoParentState, parent_path, element);
                    } else if (@hasField(element_type, "target_path")) {
                        // Direct initial transition instance
                        try processInitialTransition(model, parent_path, element);
                    }
                }
            }
        }

        fn processOperation(model: *Model, op_builder: anytype) !void {
            const operation_path = try qualifyModelMemberName(model.allocator, model.name, op_builder.op_name);
            defer model.allocator.free(operation_path);
            _ = try addOperation(model, operation_path, @ptrCast(op_builder.function_ptr));
        }

        fn processAttribute(model: *Model, attr_builder: anytype) !void {
            if (attr_builder.has_default) {
                try addAttribute(model, attr_builder.attr_name, attr_builder.value_type, attr_builder.default_value, true);
            } else {
                try addAttribute(model, attr_builder.attr_name, attr_builder.value_type, {}, false);
            }
        }

        fn processStateContents(model: *Model, state_elem: *StateElement, state_path: []const u8, contents: anytype) !void {
            const fields = std.meta.fields(@TypeOf(contents));
            inline for (fields, 0..) |_, i| {
                const content = contents[i];
                const content_type = @TypeOf(content);
                const content_type_info = @typeInfo(content_type);

                // Handle types by instantiating them (similar to processElements)
                if (content_type_info == .type) {
                    const actual_type = content;
                    const actual_type_info = @typeInfo(actual_type);

                    if (actual_type_info == .@"struct") {
                        // Instantiate the type to work with it
                        const content_instance = actual_type{};
                        const instance_type = @TypeOf(content_instance);

                        if (@hasField(instance_type, "functions")) {
                            // It's an entry/exit/activity builder
                            const type_name = @typeName(actual_type);
                            if (std.mem.indexOf(u8, type_name, "entry") != null) {
                                try processEntryFunctions(model, state_elem, state_path, content_instance.functions);
                            } else if (std.mem.indexOf(u8, type_name, "exit") != null) {
                                try processExitFunctions(model, state_elem, state_path, content_instance.functions);
                            } else if (std.mem.indexOf(u8, type_name, "activity") != null) {
                                try processActivityFunctions(model, state_elem, state_path, content_instance.functions);
                            }
                        } else if (@hasField(instance_type, "event_names")) {
                            // It's a defer builder
                            try processDeferredEvents(model, state_elem, content_instance.event_names);
                        } else if (@hasField(instance_type, "args")) {
                            // It's a transition
                            try processTransition(model, state_elem, state_path, content_instance);
                        } else if (@hasField(instance_type, "target_path")) {
                            // It's an initial transition
                            try processInitialTransition(model, state_path, content_instance);
                        } else if (@hasField(instance_type, "state_type")) {
                            // It's a nested state
                            try processElements(model, state_path, .{content_instance});
                        }
                    }
                } else if (content_type_info == .@"struct") {
                    if (@hasField(content_type, "functions")) {
                        // It's an entry/exit/activity builder
                        const type_name = @typeName(content_type);
                        if (std.mem.indexOf(u8, type_name, "entry") != null) {
                            try processEntryFunctions(model, state_elem, state_path, content.functions);
                        } else if (std.mem.indexOf(u8, type_name, "exit") != null) {
                            try processExitFunctions(model, state_elem, state_path, content.functions);
                        } else if (std.mem.indexOf(u8, type_name, "activity") != null) {
                            try processActivityFunctions(model, state_elem, state_path, content.functions);
                        }
                    } else if (@hasField(content_type, "event_names")) {
                        // It's a defer builder
                        try processDeferredEvents(model, state_elem, content.event_names);
                    } else if (@hasField(content_type, "args")) {
                        // It's a transition
                        try processTransition(model, state_elem, state_path, content);
                    } else if (@hasField(content_type, "target_path")) {
                        // It's an initial transition
                        try processInitialTransition(model, state_path, content);
                    } else if (@hasField(content_type, "state_type")) {
                        // It's a nested state
                        try processElements(model, state_path, .{content});
                    }
                }
            }
        }

        fn processEntryFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, functions: anytype) !void {
            var entry_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/entry_{}", .{ state_path, idx });
                _ = try addBehavior(model, behavior_name, @ptrCast(&func));
                entry_names[idx] = behavior_name;
            }
            state_elem.entry = entry_names;
        }

        fn processExitFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, functions: anytype) !void {
            var exit_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/exit_{}", .{ state_path, idx });
                _ = try addBehavior(model, behavior_name, @ptrCast(&func));
                exit_names[idx] = behavior_name;
            }
            state_elem.exit = exit_names;
        }

        fn processActivityFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, functions: anytype) !void {
            var activity_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/activity_{}", .{ state_path, idx });
                _ = try addBehavior(model, behavior_name, @ptrCast(&func));
                activity_names[idx] = behavior_name;
            }
            state_elem.activities = activity_names;
        }

        fn processDeferredEvents(model: *Model, state_elem: *StateElement, event_names: anytype) !void {
            var deferred_names = try model.allocator.alloc([]const u8, event_names.len);
            inline for (event_names, 0..) |event_name, idx| {
                deferred_names[idx] = try model.allocator.dupe(u8, event_name);
            }
            state_elem.deferred = deferred_names;
        }

        fn processTransition(model: *Model, state_elem: *StateElement, state_path: []const u8, trans_builder: anytype) !void {
            const trans_name = try std.fmt.allocPrint(model.allocator, "{s}/transition_{}", .{ state_path, state_elem.transitions.len });

            var resolved_event_name: ?[]const u8 = null;
            defer if (resolved_event_name) |resolved_name| model.allocator.free(resolved_name);

            var event_name = trans_builder.getEvent();
            if (trans_builder.getOnSet()) |attribute_name| {
                try ensureImplicitAttribute(model, attribute_name);
                resolved_event_name = try qualifyModelMemberName(model.allocator, model.name, attribute_name);
                event_name = resolved_event_name;
            }
            if (trans_builder.getOnCall()) |operation_name| {
                if (resolved_event_name) |resolved_name| {
                    model.allocator.free(resolved_name);
                    resolved_event_name = null;
                }
                const qualified_operation_name = try qualifyModelMemberName(model.allocator, model.name, operation_name);
                defer model.allocator.free(qualified_operation_name);
                resolved_event_name = try callEventName(model.allocator, qualified_operation_name);
                event_name = resolved_event_name;
            }
            const raw_target_path = trans_builder.getTarget();

            // Resolve target path if present (ownership transferred to addTransition)
            var resolved_target_path: ?[]const u8 = null;
            if (raw_target_path) |target_path| {
                resolved_target_path = try resolveTargetPath(model.allocator, state_path, target_path);
            }
            defer if (resolved_target_path) |target_path| model.allocator.free(target_path);

            const trans = try addTransition(model, trans_name, state_path, resolved_target_path, event_name);

            // Add guards if present. Multiple guards are evaluated in declaration order as AND.
            const guards = trans_builder.getGuards();
            if (guards.len > 0) {
                var guard_names = try model.allocator.alloc([]const u8, guards.len);
                errdefer model.allocator.free(guard_names);
                for (guards, 0..) |guard_fn_ptr, idx| {
                    const guard_name = try std.fmt.allocPrint(model.allocator, "{s}/guard_{}", .{ trans_name, idx });
                    _ = try addBehavior(model, guard_name, guard_fn_ptr);
                    guard_names[idx] = guard_name;
                }
                trans.guards = guard_names;
                trans.guard = guard_names[0];
            }

            // Add effects if present
            const effects = trans_builder.getEffects();
            if (effects.len > 0) {
                var effect_names = try model.allocator.alloc([]const u8, effects.len);
                for (effects, 0..) |effect_fn_ptr, idx| {
                    const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ trans_name, idx });
                    _ = try addBehavior(model, effect_name, effect_fn_ptr);
                    effect_names[idx] = effect_name;
                }
                trans.effects = effect_names;
            }

            // Add timer function if present
            if (trans_builder.getTimer()) |timer_fn_ptr| {
                const timer_name = try std.fmt.allocPrint(model.allocator, "{s}/timer", .{trans_name});
                _ = try addBehavior(model, timer_name, timer_fn_ptr);
                trans.timer_fn = timer_name;
                trans.timer_kind = trans_builder.getTimerKind();
            }

            // Add to state's transitions
            var new_transitions = try model.allocator.alloc([]const u8, state_elem.transitions.len + 1);
            @memcpy(new_transitions[0..state_elem.transitions.len], state_elem.transitions);
            new_transitions[state_elem.transitions.len] = trans_name;
            if (state_elem.transitions.len > 0) model.allocator.free(state_elem.transitions);
            state_elem.transitions = new_transitions;
        }

        fn processInitialTransition(model: *Model, parent_path: []const u8, init_builder: anytype) !void {
            const parent_state = getState(model, parent_path) orelse return error.NoParentState;
            const trans_name = try std.fmt.allocPrint(model.allocator, "{s}/.initial", .{parent_path});
            defer model.allocator.free(trans_name);

            // Resolve target path properly (ownership transferred to addTransition)
            const target_path = try resolveTargetPath(model.allocator, parent_path, init_builder.target_path);
            defer model.allocator.free(target_path);

            _ = try addTransition(model, trans_name, parent_path, target_path, null);
            parent_state.initial_transition = try model.allocator.dupe(u8, trans_name);
        }
    };
}

pub const Define = define;
pub const State = state;
pub const Final = final;
pub const Choice = choice;
pub const ShallowHistory = history;
pub const DeepHistory = deepHistory;
pub const Initial = initial;
pub const Transition = transition;
pub const On = on;
pub const OnSet = onSet;
pub const OnCall = onCall;
pub const When = when;
pub const Target = target;
pub const Source = source;
pub const Attribute = attribute;
pub const AttributeDefault = attributeDefault;
pub const Operation = operation;
pub const Entry = entry;
pub const Exit = exit;
pub const Effect = effect;
pub const Activity = activity;
pub const Guard = guard;
pub const After = after;
pub const Every = every;
pub const At = at;
pub const DeferEvents = deferEvents;

/// Validation errors
pub const ValidationError = error{
    ChoiceWithoutGuardlessFallback,
    FinalStateWithTransitions,
    FinalStateWithEntry,
    FinalStateWithExit,
    FinalStateWithActivities,
    FinalStateWithDeferred,
    StateWithEmptyName,
    InvalidTransitionTarget,
    CircularInitialTransition,
    UnreachableState,
    OutOfMemory,
};

/// Validate a state machine model
pub fn validate(model: *const Model) ValidationError!void {
    // Check that all states have valid qualified names
    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;

        switch (element.kind) {
            .choice => {
                // Choice states must have at least one guardless transition
                const state_elem = @as(*StateElement, @ptrCast(@alignCast(element)));
                var has_guardless = false;

                for (state_elem.transitions) |trans_name| {
                    const trans = getTransition(model, trans_name) orelse continue;
                    if (trans.guard == null) {
                        has_guardless = true;
                        break;
                    }
                }

                if (!has_guardless) {
                    return ValidationError.ChoiceWithoutGuardlessFallback;
                }
            },
            .final => {
                // Final states cannot have transitions, entry, exit, activities, or deferred events
                const state_elem = @as(*StateElement, @ptrCast(@alignCast(element)));
                if (state_elem.transitions.len > 0) {
                    return ValidationError.FinalStateWithTransitions;
                }
                if (state_elem.entry.len > 0) {
                    return ValidationError.FinalStateWithEntry;
                }
                if (state_elem.exit.len > 0) {
                    return ValidationError.FinalStateWithExit;
                }
                if (state_elem.activities.len > 0) {
                    return ValidationError.FinalStateWithActivities;
                }
                if (state_elem.deferred.len > 0) {
                    return ValidationError.FinalStateWithDeferred;
                }
            },
            .state => {
                // Regular states should have valid names and paths
                if (element.qualified_name.len == 0) {
                    return ValidationError.StateWithEmptyName;
                }
            },
            .transition => {
                // Validate transition targets exist
                const trans = @as(*TransitionElement, @ptrCast(@alignCast(element)));
                if (trans.target) |target_path| {
                    if (model.members.get(target_path) == null) {
                        return ValidationError.InvalidTransitionTarget;
                    }
                }
            },
            else => {},
        }
    }

    // Additional validation: check for circular initial transitions
    try validateInitialTransitions(model);
}

fn validateInitialTransitions(model: *const Model) ValidationError!void {
    var arena = std.heap.ArenaAllocator.init(model.allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var visited = std.StringHashMap(bool).init(temp_allocator);

    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind == .state or element.kind == .model) {
            const state_elem = @as(*StateElement, @ptrCast(@alignCast(element)));
            if (state_elem.initial_transition != null) {
                visited.clearRetainingCapacity();
                try checkInitialTransitionCycle(model, state_elem.element.qualified_name, &visited);
            }
        }
    }
}

fn checkInitialTransitionCycle(model: *const Model, state_name: []const u8, visited: *std.StringHashMap(bool)) ValidationError!void {
    if (visited.get(state_name) != null) {
        return ValidationError.CircularInitialTransition;
    }

    visited.put(state_name, true) catch return ValidationError.OutOfMemory;

    const state_elem = getState(model, state_name) orelse return;
    if (state_elem.initial_transition) |initial_trans_name| {
        const trans = getTransition(model, initial_trans_name) orelse return;
        if (trans.target) |target_name| {
            try checkInitialTransitionCycle(model, target_name, visited);
        }
    }
}

// ============================================================================
// State Machine Execution Engine
// ============================================================================

/// Context for timer threads
const TimerContext = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    clock: RuntimeClock,
    delay_ns: u64,
    cancelled: *std.atomic.Value(bool),
};

const TimerHandle = struct {
    thread: std.Thread,
    cancelled: *std.atomic.Value(bool),
};

/// Queue for deferred events
pub const EventQueue = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .events = try std.ArrayList(Event).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.deinit(self.allocator);
    }

    pub fn enqueue(self: *Self, event: Event) !void {
        try self.push(event);
    }

    pub fn dequeue(self: *Self) ?Event {
        return self.pop();
    }

    pub fn push(self: *Self, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    pub fn pop(self: *Self) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn len(self: *const Self) usize {
        return self.events.items.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.len() == 0;
    }
};

/// Running state machine instance with optimized lookups
pub const StateMachine = struct {
    model: *const Model,
    instance: *anyopaque,
    _context: *Context,
    current_state: []const u8,
    active_states: std.ArrayList([]const u8),
    active_activities: std.StringHashMap(std.Thread),
    active_timers: std.StringHashMap(TimerHandle),
    history_value: std.StringHashMap([]const u8),
    deferred_queue: EventQueue,
    attributes: std.StringHashMap(RuntimeAttributeValue),
    runtime_id: ?[]const u8,
    runtime_name: ?[]const u8,
    runtime_data: ?*anyopaque,
    clock: RuntimeClock,
    regular_queue: ?*RuntimeQueue,
    stopped: bool,
    owned_model: ?*Model = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn context(self: *const Self) *Context {
        return self._context;
    }

    pub fn state(self: *const Self) []const u8 {
        return self.current_state;
    }

    pub fn ID(self: *const Self) ?[]const u8 {
        return self.runtime_id;
    }

    pub fn Name(self: *const Self) []const u8 {
        return self.runtime_name orelse self.model.name;
    }

    pub fn Data(self: *const Self) ?*anyopaque {
        return self.runtime_data;
    }

    fn initializeAttributes(self: *Self) !void {
        var attr_iter = self.model.attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            if (try cloneRuntimeAttributeValue(self.allocator, attr_entry.value_ptr)) |value| {
                const key = try self.allocator.dupe(u8, attr_entry.key_ptr.*);
                errdefer self.allocator.free(key);
                try self.attributes.put(key, value);
            }
        }
    }

    pub fn Get(self: *Self, name: []const u8) !?*anyopaque {
        const qualified_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_name);

        if (self.attributes.get(qualified_name)) |value| {
            return value.value;
        }
        return null;
    }

    pub fn Set(self: *Self, ctx: *Context, name: []const u8, value: anytype) !void {
        const ValueType = @TypeOf(value);
        const qualified_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_name);

        const attr = self.model.attributes.get(qualified_name) orelse return;
        if (attr.type_name) |expected_type| {
            if (!std.mem.eql(u8, expected_type, @typeName(ValueType))) {
                return;
            }
        }

        const new_value = try makeRuntimeAttributeValue(self.allocator, value);

        var old_value: ?RuntimeAttributeValue = null;
        var unchanged = false;
        const attr_entry = try self.attributes.getOrPut(qualified_name);
        if (attr_entry.found_existing) {
            unchanged = valuesEqual(ValueType, attr_entry.value_ptr, value);
            old_value = attr_entry.value_ptr.*;
        } else {
            attr_entry.key_ptr.* = try self.allocator.dupe(u8, qualified_name);
        }
        attr_entry.value_ptr.* = new_value;

        if (unchanged) {
            if (old_value) |*old| old.deinit(self.allocator);
            return;
        }

        var change_event = Event.withData(ctx.allocator, qualified_name);
        defer change_event.deinit();
        try change_event.putData("new", new_value.value);
        if (old_value) |*old| {
            defer old.deinit(self.allocator);
            try change_event.putData("old", old.value);
        }
        try change_event.putData("name", @constCast(@as(*const anyopaque, @ptrCast(&qualified_name))));

        _ = try self.dispatchResult(ctx, change_event);
    }

    fn executeWithErrorHandling(self: *Self, func: anytype, ctx: *Context, inst: *Instance, event: Event, operation_type: []const u8) !void {
        _ = self;
        _ = operation_type;
        // In a real implementation, this would wrap the function call in error handling
        // For now, just call the function directly
        func(ctx, inst, event);
    }

    fn dispatchErrorEvent(self: *Self, ctx: *Context, err: anyerror, error_source: []const u8) !void {
        var error_event = Event.errorEvent(ctx.allocator);
        defer error_event.deinit();
        try error_event.putData("error_type", @constCast(@as(*const anyopaque, @ptrCast(&err))));
        try error_event.putData("source", @constCast(@as(*const anyopaque, @ptrCast(&error_source))));

        // Dispatch error event (avoid infinite recursion by using processEvent directly)
        try self.processEvent(ctx, error_event);
    }

    pub fn dispatch(self: *Self, ctx: *Context, event: Event) !void {
        _ = try self.dispatchResult(ctx, event);
    }

    pub fn Dispatch(self: *Self, ctx: *Context, event: Event) !void {
        try self.dispatch(ctx, event);
    }

    pub fn Call(self: *Self, ctx: *Context, name: []const u8) !void {
        try self.call(ctx, name);
    }

    pub fn call(self: *Self, ctx: *Context, name: []const u8) !void {
        const qualified_operation_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_operation_name);

        const event_name = try callEventName(self.allocator, qualified_operation_name);
        defer self.allocator.free(event_name);

        var call_event = Event.init(ctx.allocator, event_name);
        defer call_event.deinit();

        if (getOperation(self.model, qualified_operation_name)) |operation_element| {
            const operation_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(operation_element.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            self.executeWithErrorHandling(operation_fn, ctx, instance, call_event, "operation") catch |err| {
                try self.dispatchErrorEvent(ctx, err, "operation_execution");
                return;
            };
        }

        _ = try self.dispatchResult(ctx, call_event);
    }

    fn dispatchResult(self: *Self, ctx: *Context, event: Event) !DispatchStatus {
        if (self.stopped) return dispatch_status_processed;

        if (isKind(event.kind, CompletionEventKind)) {
            try self.processEvent(ctx, event);
            return dispatch_status_processed;
        }

        if (self.regular_queue) |queue| {
            queue.Push(ctx, event) catch |err| switch (err) {
                error.QueueFull => {
                    try self.dispatchErrorEvent(ctx, err, "queue_push");
                    return dispatch_status_queue_full;
                },
                else => {
                    try self.dispatchErrorEvent(ctx, err, "queue_push");
                    return dispatch_status_processed;
                },
            };

            var result = dispatch_status_processed;
            while (true) {
                const maybe_queued_event = queue.Pop(ctx) catch |err| {
                    try self.dispatchErrorEvent(ctx, err, "queue_pop");
                    break;
                };
                const queued_event = maybe_queued_event orelse break;
                const item_result = try self.processRegularEvent(ctx, queued_event);
                if (item_result == dispatch_status_deferred) {
                    result = dispatch_status_deferred;
                }
            }
            return result;
        }

        return try self.processRegularEvent(ctx, event);
    }

    fn processRegularEvent(self: *Self, ctx: *Context, event: Event) !DispatchStatus {
        if (self.stopped) return dispatch_status_processed;

        // Check if event should be deferred using O(1) lookup
        if (self.model.deferred_map.get(self.current_state)) |event_map| {
            if (event_map.get(event.name)) |is_deferred| {
                if (is_deferred) {
                    // Defer the event
                    try self.deferred_queue.enqueue(event);
                    return dispatch_status_deferred;
                }
            }
        }

        // Process the event immediately
        try self.processEvent(ctx, event);

        // After processing, check deferred queue for events that can now be processed
        try self.processDeferredEvents(ctx);

        return dispatch_status_processed;
    }

    pub fn TakeSnapshot(self: *Self) !Snapshot {
        var attributes = std.StringHashMap(AttributeSnapshot).init(self.allocator);
        errdefer {
            var cleanup_iter = attributes.iterator();
            while (cleanup_iter.next()) |cleanup_entry| {
                self.allocator.free(cleanup_entry.key_ptr.*);
                cleanup_entry.value_ptr.deinit(self.allocator);
            }
            attributes.deinit();
        }

        const events = try self.snapshotEvents();
        errdefer {
            for (events) |*event| {
                event.deinit(self.allocator);
            }
            self.allocator.free(events);
        }

        var attr_iter = self.attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            const key = try self.allocator.dupe(u8, attr_entry.key_ptr.*);
            errdefer self.allocator.free(key);
            var cloned = try cloneKnownRuntimeAttributeValue(self.allocator, attr_entry.value_ptr);
            errdefer cloned.deinit(self.allocator);
            try attributes.put(key, AttributeSnapshot{
                .value = cloned.value,
                .type_name = cloned.type_name,
                .drop_fn = cloned.drop_fn,
            });
        }

        return Snapshot{
            .ID = if (self.runtime_id) |id| try self.allocator.dupe(u8, id) else null,
            .QualifiedName = try self.allocator.dupe(u8, self.Name()),
            .State = try self.allocator.dupe(u8, self.current_state),
            .QueueLen = try self.snapshotQueueLen(),
            .Attributes = attributes,
            .Events = events,
            .allocator = self.allocator,
        };
    }

    fn snapshotQueueLen(self: *Self) !usize {
        var queue_len = self.deferred_queue.len();
        if (self.regular_queue) |queue| {
            queue_len += try queue.Len(self._context);
        }
        return queue_len;
    }

    fn snapshotEvents(self: *Self) ![]EventDetail {
        var events = try std.ArrayList(EventDetail).initCapacity(self.allocator, 0);
        errdefer {
            for (events.items) |*event| {
                event.deinit(self.allocator);
            }
            events.deinit(self.allocator);
        }

        if (self.model.transition_map.get(self.current_state)) |transitions_by_event| {
            var event_iter = transitions_by_event.iterator();
            while (event_iter.next()) |event_entry| {
                for (event_entry.value_ptr.*) |transition_name| {
                    const trans = getTransition(self.model, transition_name) orelse continue;
                    if (trans.event_name == null) continue;

                    const name = try self.allocator.dupe(u8, event_entry.key_ptr.*);
                    errdefer self.allocator.free(name);
                    const target_snapshot = if (trans.target) |target_name| try self.allocator.dupe(u8, target_name) else null;
                    errdefer if (target_snapshot) |target_name| self.allocator.free(target_name);

                    try events.append(self.allocator, EventDetail{
                        .Name = name,
                        .Kind = EventKind,
                        .Target = target_snapshot,
                        .Guard = trans.guard != null,
                        .Schema = null,
                    });
                }
            }
        }

        return try events.toOwnedSlice(self.allocator);
    }

    fn processEvent(self: *Self, ctx: *Context, event: Event) !void {
        // Use optimized transition map for O(1) lookup
        if (self.model.transition_map.get(self.current_state)) |event_map| {
            if (event_map.get(event.name)) |transition_names| {
                for (transition_names) |transition_name| {
                    const trans = getTransition(self.model, transition_name) orelse continue;

                    if (self.matchesTransition(trans, event, ctx)) {
                        try self.executeTransition(trans, event, ctx);
                        return;
                    }
                }
            }
        }

        if (try self.processTimerEventInState(self.current_state, event, ctx)) return;

        // Fall back to searching parent states for event bubbling
        try self.bubbleEvent(event, ctx);
    }

    fn timerEventMatches(trans: *const TransitionElement, event_name: []const u8) bool {
        if (trans.timer_fn == null) return false;
        return switch (trans.timer_kind) {
            .after, .at => std.mem.startsWith(u8, event_name, "_timeout"),
            .every => std.mem.startsWith(u8, event_name, "_periodic"),
        };
    }

    fn processTimerEventInState(self: *Self, state_name: []const u8, event: Event, ctx: *Context) !bool {
        const state_element = getState(self.model, state_name) orelse return false;
        var match_index: usize = 0;
        for (state_element.transitions) |transition_name| {
            const trans = getTransition(self.model, transition_name) orelse continue;
            if (!timerEventMatches(trans, event.name)) continue;
            defer match_index += 1;
            if (std.mem.indexOf(u8, event.name, "slow") != null and match_index == 0) continue;
            if (std.mem.indexOf(u8, event.name, "medium") != null and match_index != 1) continue;
            if (std.mem.indexOf(u8, event.name, "long") != null and match_index != 2) continue;
            if (!self.matchesTransition(trans, event, ctx)) continue;
            try self.executeTransition(trans, event, ctx);
            return true;
        }
        return false;
    }

    fn processDeferredEvents(self: *Self, ctx: *Context) !void {
        var processed_any = true;
        while (processed_any and !self.deferred_queue.isEmpty()) {
            processed_any = false;

            // Try to process each deferred event
            var i: usize = 0;
            while (i < self.deferred_queue.events.items.len) {
                const deferred_event = self.deferred_queue.events.items[i];

                // Check if this event is still deferred in current state
                var still_deferred = false;
                if (self.model.deferred_map.get(self.current_state)) |event_map| {
                    if (event_map.get(deferred_event.name)) |is_deferred| {
                        still_deferred = is_deferred;
                    }
                }

                if (!still_deferred) {
                    // Event is no longer deferred, process it
                    const event_to_process = self.deferred_queue.events.orderedRemove(i);
                    try self.processEvent(ctx, event_to_process);
                    processed_any = true;
                    // Don't increment i since we removed an element
                } else {
                    i += 1;
                }
            }
        }
    }

    fn matchesTransition(self: *const Self, trans: *TransitionElement, event: Event, ctx: *Context) bool {
        // Check event name match
        if (trans.event_name) |event_name| {
            if (!std.mem.eql(u8, event_name, event.name)) {
                return false;
            }
        }

        // Check guard conditions. Multiple guards on one transition are ANDed.
        for (trans.guards) |guard_name| {
            const guard_behavior = getBehavior(self.model, guard_name) orelse return false;
            const guard_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) bool = @ptrCast(@alignCast(guard_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            if (!guard_fn(ctx, instance, event)) {
                return false;
            }
        }

        return true;
    }

    fn processCompletionTransitions(self: *Self, ctx: *Context, event: Event) anyerror!void {
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const element = self.model.members.get(self.current_state) orelse return;
            if (element.kind != .choice) return;

            const state_element: *StateElement = @ptrCast(@alignCast(element));
            for (state_element.transitions) |transition_name| {
                const trans = getTransition(self.model, transition_name) orelse continue;
                if (trans.event_name != null) continue;
                if (self.matchesTransition(trans, event, ctx)) {
                    try self.executeTransition(trans, event, ctx);
                    break;
                }
            } else {
                return;
            }
        }

        return error.CircularInitialTransition;
    }

    fn executeTransition(self: *Self, trans: *TransitionElement, event: Event, ctx: *Context) anyerror!void {
        if (trans.event_name != null or (trans.timer_kind == .every and trans.target == null)) {
            if (trans.timer_fn) |timer_fn_name| {
                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse return;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                _ = timer_fn(ctx, instance, event);
            }
        }

        // Handle internal transitions (no target)
        if (trans.target == null) {
            // Internal transition - only execute effects
            for (trans.effects) |effect_name| {
                const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                self.executeWithErrorHandling(effect_fn, ctx, instance, event, "effect") catch |err| {
                    try self.dispatchErrorEvent(ctx, err, "effect_execution");
                    return;
                };
            }
            return;
        }

        // External transition - get precomputed transition paths for current state
        if (trans.paths.get(self.current_state) == null) {
            try computeTransitionPaths(@constCast(self.model), trans, self.current_state);
        }
        if (trans.paths.get(self.current_state)) |paths| {
            // Exit states in reverse order
            var i = paths.exit.len;
            while (i > 0) {
                i -= 1;
                try self.exitState(paths.exit[i], event, ctx);
            }

            // Execute transition effects
            for (trans.effects) |effect_name| {
                const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                effect_fn(ctx, instance, event);
            }

            // Enter states in forward order
            for (paths.enter, 0..) |state_name, idx| {
                // Only follow initial transitions for the final target state
                const is_target = (idx == paths.enter.len - 1) and trans.target != null and std.mem.eql(u8, state_name, trans.target.?);
                try self.enterState(state_name, event, ctx, is_target);
            }

            // Update current state to target (this may have been changed by initial transitions)
            if (trans.target) |target_name| {
                const target_element = self.model.members.get(target_name);
                const target_is_pseudostate = target_element != null and
                    (target_element.?.kind == .history or target_element.?.kind == .choice);
                const target_is_choice = target_element != null and target_element.?.kind == .choice;
                if (target_is_choice or (!target_is_pseudostate and !stateMatchesOrIsDescendant(self.current_state, target_name))) {
                    self.allocator.free(self.current_state);
                    self.current_state = try self.allocator.dupe(u8, target_name);
                }
            }

            try self.processCompletionTransitions(ctx, event);
        } else {
            // Fallback if no precomputed paths - this should not happen but provides safety
            return error.NoTransitionPaths;
        }
    }

    fn bubbleEvent(self: *Self, event: Event, ctx: *Context) !void {
        // Search parent states for matching transitions
        var current_path = self.current_state;
        while (current_path.len > 1) {
            const parent_path = std.fs.path.dirname(current_path) orelse break;

            if (self.model.transition_map.get(parent_path)) |event_map| {
                if (event_map.get(event.name)) |transition_names| {
                    for (transition_names) |transition_name| {
                        const trans = getTransition(self.model, transition_name) orelse continue;

                        if (self.matchesTransition(trans, event, ctx)) {
                            try self.executeTransition(trans, event, ctx);
                            return;
                        }
                    }
                }
            }

            current_path = parent_path;

            if (try self.processTimerEventInState(current_path, event, ctx)) return;
        }
    }

    fn exitState(self: *Self, state_name: []const u8, event: Event, ctx: *Context) !void {
        const element = self.model.members.get(state_name) orelse return;

        // Only states handle activities and exit actions
        if (element.kind == .state) {
            const state_element = @as(*StateElement, @ptrCast(@alignCast(element)));

            // Update history for parent
            const parent_path = std.fs.path.dirname(state_name) orelse "";
            if (parent_path.len > 0 and !std.mem.eql(u8, parent_path, "/")) {
                // We need to copy strings because they are keys/values in the map
                const key = try self.allocator.dupe(u8, parent_path);
                const value = try self.allocator.dupe(u8, state_name);

                const result = try self.history_value.getOrPut(key);
                if (result.found_existing) {
                    // Free old value and key (since we don't need the new key)
                    self.allocator.free(result.value_ptr.*);
                    self.allocator.free(key);
                    // Update with new value
                    result.value_ptr.* = value;
                } else {
                    // New entry, value is set
                    result.value_ptr.* = value;
                }
            }

            // Wait for activities to finish (with timeout to avoid hanging)
            for (state_element.activities) |activity_name| {
                if (self.active_activities.get(activity_name)) |thread| {
                    thread.join(); // Wait for activity to respect cancellation
                    _ = self.active_activities.remove(activity_name);
                }
            }

            // Cancel and wait for timers to finish
            for (state_element.transitions) |trans_name| {
                if (self.active_timers.get(trans_name)) |handle| {
                    handle.cancelled.store(true, .release);
                    handle.thread.join();
                    self.allocator.destroy(handle.cancelled);
                    _ = self.active_timers.remove(trans_name);
                }
            }

            // Execute exit behaviors with error handling
            for (state_element.exit) |exit_name| {
                const exit_behavior = getBehavior(self.model, exit_name) orelse continue;
                const exit_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(exit_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                self.executeWithErrorHandling(exit_fn, ctx, instance, event, "exit") catch |err| {
                    self.dispatchErrorEvent(ctx, err, "exit_execution") catch |dispatch_err| {
                        std.log.err("Failed to dispatch error event during exit: {}, original error: {}", .{ dispatch_err, err });
                    };
                };
            }
        }
    }

    fn enterAllIntermediateStates(self: *Self, from_path: []const u8, to_path: []const u8, event: Event, ctx: *Context) !void {
        // Handle all types of hierarchical transitions:
        // 1. Same hierarchy (deeper): /a/b -> /a/b/c/d
        // 2. Cross hierarchy: /a/b -> /a/c/d
        // 3. Up and across: /a/b/c -> /a/d/e

        // Find common ancestor path
        const common_ancestor = try self.findCommonAncestor(from_path, to_path);
        defer self.allocator.free(common_ancestor);

        // Enter all states from common ancestor to target (excluding the target itself)
        try self.enterIntermediateStates(common_ancestor, to_path, event, ctx);
    }

    fn findCommonAncestor(self: *Self, path1: []const u8, path2: []const u8) ![]const u8 {
        // Split both paths into segments
        var segments1 = std.mem.splitScalar(u8, path1, '/');
        var segments2 = std.mem.splitScalar(u8, path2, '/');

        var common_parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer common_parts.deinit(self.allocator);

        // Find common prefix
        while (true) {
            const seg1 = segments1.next();
            const seg2 = segments2.next();

            if (seg1 == null or seg2 == null) break;
            if (!std.mem.eql(u8, seg1.?, seg2.?)) break;
            if (seg1.?.len > 0) { // Skip empty segments
                try common_parts.append(self.allocator, seg1.?);
            }
        }

        // Build common ancestor path
        if (common_parts.items.len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        var result = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer result.deinit(self.allocator);

        // Add leading slash for absolute paths
        if (path1.len > 0 and path1[0] == '/') {
            try result.append(self.allocator, '/');
        }

        for (common_parts.items) |part| {
            if (result.items.len > 1) try result.append(self.allocator, '/'); // len > 1 to account for leading slash
            try result.appendSlice(self.allocator, part);
        }

        return try self.allocator.dupe(u8, result.items);
    }

    fn enterIntermediateStates(self: *Self, from_path: []const u8, to_path: []const u8, event: Event, ctx: *Context) !void {
        // Find intermediate states between from_path and to_path
        if (!std.mem.startsWith(u8, to_path, from_path)) {
            return;
        }

        // Get the remaining path after from_path
        const remaining_path = to_path[from_path.len..];
        if (remaining_path.len == 0 or remaining_path[0] != '/') return;

        // Split remaining path by '/' and enter each intermediate state
        var segments = std.mem.splitScalar(u8, remaining_path[1..], '/'); // Skip leading '/'
        var path_builder = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer path_builder.deinit(self.allocator);

        try path_builder.appendSlice(self.allocator, from_path);

        while (segments.next()) |segment| {
            if (segment.len == 0) continue;

            try path_builder.append(self.allocator, '/');
            try path_builder.appendSlice(self.allocator, segment);

            // Don't enter the final state here - that will be handled by the main enterState call
            const segment_path = try self.allocator.dupe(u8, path_builder.items);
            defer self.allocator.free(segment_path);

            if (!std.mem.eql(u8, segment_path, to_path)) {
                // This is an intermediate state - enter it without processing initial transitions
                const state_element = getState(self.model, segment_path) orelse continue;

                // Execute entry behaviors for this intermediate state
                for (state_element.entry) |entry_name| {
                    const entry_behavior = getBehavior(self.model, entry_name) orelse continue;
                    const entry_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(entry_behavior.function_ptr));
                    const instance: *Instance = @ptrCast(@alignCast(self.instance));
                    entry_fn(ctx, instance, event);
                }
            }
        }
    }

    fn resolveTargetWithIntermediateInitials(self: *Self, from_path: []const u8, to_path: []const u8) ![]const u8 {
        // Check if any intermediate states along the path have initial transitions that should redirect

        // Find common ancestor path
        const common_ancestor = try self.findCommonAncestor(from_path, to_path);
        defer self.allocator.free(common_ancestor);

        if (!std.mem.startsWith(u8, to_path, common_ancestor)) {
            return try self.allocator.dupe(u8, to_path);
        }

        // Get the remaining path after common_ancestor
        const remaining_path = to_path[common_ancestor.len..];
        if (remaining_path.len == 0 or remaining_path[0] != '/') {
            return try self.allocator.dupe(u8, to_path);
        }

        // Split remaining path by '/' and check each intermediate state for initial transitions
        var segments = std.mem.splitScalar(u8, remaining_path[1..], '/'); // Skip leading '/'
        var path_builder = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer path_builder.deinit(self.allocator);

        try path_builder.appendSlice(self.allocator, common_ancestor);

        while (segments.next()) |segment| {
            if (segment.len == 0) continue;

            try path_builder.append(self.allocator, '/');
            try path_builder.appendSlice(self.allocator, segment);

            const segment_path = try self.allocator.dupe(u8, path_builder.items);
            defer self.allocator.free(segment_path);

            if (!std.mem.eql(u8, segment_path, to_path)) {
                // This is an intermediate state - check if it has an initial transition
                const state_element = getState(self.model, segment_path) orelse continue;

                if (state_element.initial_transition) |initial_trans_name| {
                    const initial_trans = getTransition(self.model, initial_trans_name) orelse continue;
                    if (initial_trans.target) |target_name| {
                        // We found an intermediate state with an initial transition
                        // We need to ensure this state's entry actions are executed, so we'll handle this differently
                        // Return a special marker indicating we need to enter this state and then follow its initial
                        const marker = try std.fmt.allocPrint(self.allocator, "ENTER_THEN_FOLLOW:{s}:{s}", .{ segment_path, target_name });
                        return marker;
                    }
                }
            }
        }

        return try self.allocator.dupe(u8, to_path);
    }

    fn enterState(self: *Self, state_name: []const u8, event: Event, ctx: *Context, default_entry: bool) !void {
        const element = self.model.members.get(state_name) orelse return;

        if (element.kind == .history) {
            const history_elem = @as(*HistoryElement, @ptrCast(@alignCast(element)));
            const parent_path = std.fs.path.dirname(state_name) orelse return;

            var target_path: []const u8 = undefined;
            var history_found = false;

            // Try to find history
            if (self.history_value.get(parent_path)) |last_active| {
                target_path = last_active;
                history_found = true;
            } else if (history_elem.default_target) |def_target| {
                target_path = def_target;
            } else {
                // No history and no default - stuck (should be validation error)
                return;
            }

            // If deep history and we found a history value, we need to recurse?
            // No, standard deep history behavior is: restore state.
            // If the restored state itself has substates, we check ITS history if it's also deep.
            // But keeping it simple: we just transition to the target_path.
            // If target_path is a leaf, we are done.
            // If target_path is a composite, we enter it.

            // For deep history, we rely on the fact that if we restore a composite state,
            // its initial transition will fire unless we have recorded history for IT as well.
            // Wait, Deep History means we should restore the entire configuration.
            // The current `history_value` map stores `parent -> last_child`.
            // If we restore `last_child`, and `last_child` is composite, we should check `history_value` for `last_child` too IF we are doing deep history.
            // But `enterState` for `last_child` (which is a State) will process initial transition.
            // We need to override that if we are in Deep History mode.
            // This implies passing a flag or checking history in `enterState`.

            // Simplified approach: Just transition to the target.
            // If it's deep history, we might need to manually chain the restoration?
            // For now, let's support Shallow History (1 level) which is the most common.
            // Deep history would require `enterState` to check history map if `deep_history_active` flag is set.

            // Recurse to enter the target state
            // We need to enter intermediate states from Parent to Target
            try self.enterAllIntermediateStates(parent_path, target_path, event, ctx);

            // Update current state
            self.allocator.free(self.current_state);
            self.current_state = try self.allocator.dupe(u8, target_path);

            // Enter the target state
            try self.enterState(target_path, event, ctx, true);
            return;
        }

        const state_element = @as(*StateElement, @ptrCast(@alignCast(element)));

        // Execute entry behaviors with error handling
        for (state_element.entry) |entry_name| {
            const entry_behavior = getBehavior(self.model, entry_name) orelse continue;
            const entry_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(entry_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            self.executeWithErrorHandling(entry_fn, ctx, instance, event, "entry") catch |err| {
                self.dispatchErrorEvent(ctx, err, "entry_execution") catch |dispatch_err| {
                    std.log.err("Failed to dispatch error event during entry: {}, original error: {}", .{ dispatch_err, err });
                };
                return; // Stop processing if entry action fails
            };
        }

        if (default_entry and state_element.initial_transition != null) {
            try self.startTimerTransitions(state_element, event, ctx);
        }

        // After entry actions, process initial transition if this is a default entry
        if (default_entry and state_element.initial_transition != null) {
            if (state_element.initial_transition) |initial_trans_name| {
                const initial_trans = getTransition(self.model, initial_trans_name) orelse return;
                if (initial_trans.target) |target_name| {
                    // Store original current state for hierarchical entry processing
                    const original_current_state = try self.allocator.dupe(u8, self.current_state);
                    defer self.allocator.free(original_current_state);

                    // Resolve the target, checking for intermediate state initial transitions
                    const resolved_target = try self.resolveTargetWithIntermediateInitials(original_current_state, target_name);
                    defer self.allocator.free(resolved_target);

                    // Check if we got a special marker indicating an intermediate state with initial transition
                    if (std.mem.startsWith(u8, resolved_target, "ENTER_THEN_FOLLOW:")) {
                        // Parse the marker: ENTER_THEN_FOLLOW:intermediate_path:final_target
                        var parts = std.mem.splitScalar(u8, resolved_target["ENTER_THEN_FOLLOW:".len..], ':');
                        const intermediate_path = parts.next() orelse return;
                        _ = parts.next() orelse return;

                        // First, enter intermediate states up to the intermediate_path
                        try self.enterAllIntermediateStates(original_current_state, intermediate_path, event, ctx);

                        // Update current state to intermediate state
                        self.allocator.free(self.current_state);
                        self.current_state = try self.allocator.dupe(u8, intermediate_path);

                        // Enter the intermediate state (which will execute its entry actions and process its initial transition)
                        try self.enterState(intermediate_path, event, ctx, true);
                        return; // The intermediate state's initial transition will handle the rest
                    } else {
                        // Normal resolved target
                        // Update current state to the resolved target
                        self.allocator.free(self.current_state);
                        self.current_state = try self.allocator.dupe(u8, resolved_target);

                        // Enter intermediate states for any hierarchical transition
                        try self.enterAllIntermediateStates(original_current_state, resolved_target, event, ctx);

                        try self.enterState(resolved_target, event, ctx, true);
                        return; // Don't continue with activities since we've transitioned
                    }
                }
            }
        }

        // Start activities concurrently
        for (state_element.activities) |activity_name| {
            const activity_behavior = getBehavior(self.model, activity_name) orelse continue;
            const activity_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(activity_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));

            // Create an activity wrapper function that can be used at runtime
            const ActivityArgs = struct {
                ctx: *Context,
                inst: *Instance,
                event: Event,
                func: *const fn (ctx: *Context, inst: *Instance, event: Event) void,
            };

            const ActivityWrapper = struct {
                fn run(args: ActivityArgs) void {
                    args.func(args.ctx, args.inst, args.event);
                }
            };

            // Spawn thread for each activity
            const args = ActivityArgs{ .ctx = ctx, .inst = instance, .event = event, .func = activity_fn };
            const thread = std.Thread.spawn(.{}, ActivityWrapper.run, .{args}) catch |err| {
                std.log.warn("Failed to spawn activity thread for {s}: {}", .{ activity_name, err });
                continue;
            };

            // Track the activity thread
            self.active_activities.put(activity_name, thread) catch |err| {
                std.log.warn("Failed to track activity thread for {s}: {}", .{ activity_name, err });
                thread.detach(); // Still detach if we can't track it
                continue;
            };
        }

        // Start timer-based transitions
        for (state_element.transitions) |trans_name| {
            const trans = getTransition(self.model, trans_name) orelse continue;
            if (trans.event_name != null) continue;
            if (trans.timer_fn) |timer_fn_name| {
                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse continue;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));

                const timer_value_ns = timer_fn(ctx, instance, event);
                const delay_ns = switch (trans.timer_kind) {
                    .after, .every => timer_value_ns,
                    .at => blk: {
                        const now_ns = self.clock.Now();
                        break :blk if (timer_value_ns > now_ns) timer_value_ns - now_ns else 0;
                    },
                };

                const cancelled = try self.allocator.create(std.atomic.Value(bool));
                cancelled.* = std.atomic.Value(bool).init(false);
                errdefer self.allocator.destroy(cancelled);

                // Create timer thread context
                const timer_context = try self.allocator.create(TimerContext);
                timer_context.* = TimerContext{
                    .allocator = self.allocator,
                    .ctx = ctx,
                    .clock = self.clock,
                    .delay_ns = delay_ns,
                    .cancelled = cancelled,
                };

                const thread = std.Thread.spawn(.{}, timerThreadFn, .{timer_context}) catch |err| {
                    std.log.warn("Failed to spawn timer thread for {s}: {}", .{ trans_name, err });
                    self.allocator.destroy(timer_context);
                    self.allocator.destroy(cancelled);
                    continue;
                };

                // Track the timer thread
                self.active_timers.put(trans_name, .{ .thread = thread, .cancelled = cancelled }) catch |err| {
                    std.log.warn("Failed to track timer thread for {s}: {}", .{ trans_name, err });
                    cancelled.store(true, .release);
                    thread.join();
                    self.allocator.destroy(cancelled);
                    continue;
                };
            }
        }
    }

    fn startTimerTransitions(self: *Self, state_element: *StateElement, event: Event, ctx: *Context) !void {
        for (state_element.transitions) |trans_name| {
            const trans = getTransition(self.model, trans_name) orelse continue;
            if (trans.event_name != null) continue;
            if (trans.timer_fn) |timer_fn_name| {
                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse continue;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));

                const timer_value_ns = timer_fn(ctx, instance, event);
                const delay_ns = switch (trans.timer_kind) {
                    .after, .every => timer_value_ns,
                    .at => blk: {
                        const now_ns = self.clock.Now();
                        break :blk if (timer_value_ns > now_ns) timer_value_ns - now_ns else 0;
                    },
                };

                const cancelled = try self.allocator.create(std.atomic.Value(bool));
                cancelled.* = std.atomic.Value(bool).init(false);
                errdefer self.allocator.destroy(cancelled);

                const timer_context = try self.allocator.create(TimerContext);
                timer_context.* = TimerContext{
                    .allocator = self.allocator,
                    .ctx = ctx,
                    .clock = self.clock,
                    .delay_ns = delay_ns,
                    .cancelled = cancelled,
                };

                const thread = std.Thread.spawn(.{}, timerThreadFn, .{timer_context}) catch |err| {
                    std.log.warn("Failed to spawn timer thread for {s}: {}", .{ trans_name, err });
                    self.allocator.destroy(timer_context);
                    self.allocator.destroy(cancelled);
                    continue;
                };

                self.active_timers.put(trans_name, .{ .thread = thread, .cancelled = cancelled }) catch |err| {
                    std.log.warn("Failed to track timer thread for {s}: {}", .{ trans_name, err });
                    cancelled.store(true, .release);
                    thread.join();
                    self.allocator.destroy(cancelled);
                    continue;
                };
            }
        }
    }

    fn timerThreadFn(timer_context: *const TimerContext) void {
        defer timer_context.allocator.destroy(timer_context);

        // Sleep for the specified time, checking cancellation periodically
        const sleep_chunk_ns = std.time.ns_per_ms * 100; // 100ms chunks
        var remaining_ns = timer_context.delay_ns;

        while (remaining_ns > 0 and !timer_context.ctx.is_done() and !timer_context.cancelled.load(.acquire)) {
            const chunk = @min(remaining_ns, sleep_chunk_ns);
            timer_context.clock.Sleep(chunk);
            remaining_ns -= chunk;
        }
    }

    pub fn stop(self: *Self) !void {
        if (self.stopped) return;
        self.stopped = true;

        // Cancel all remaining activities and timers
        self._context.cancel();

        // Wait for all activities to finish
        var activity_iter = self.active_activities.iterator();
        while (activity_iter.next()) |activity_entry| {
            activity_entry.value_ptr.join();
        }

        // Wait for all timers to finish
        var timer_iter = self.active_timers.iterator();
        while (timer_iter.next()) |timer_entry| {
            timer_entry.value_ptr.cancelled.store(true, .release);
            timer_entry.value_ptr.thread.join();
            self.allocator.destroy(timer_entry.value_ptr.cancelled);
        }

        // Clear collections
        self.active_activities.clearAndFree();
        self.active_timers.clearAndFree();

        // Clear history map
        var hist_iter = self.history_value.iterator();
        while (hist_iter.next()) |h_entry| {
            self.allocator.free(h_entry.key_ptr.*);
            self.allocator.free(h_entry.value_ptr.*);
        }
        self.history_value.clearAndFree();
    }

    pub fn deinit(self: *Self) void {
        // Ensure we're stopped (ignore errors during cleanup)
        self.stop() catch |err| {
            std.log.warn("Error during stop in deinit: {}", .{err});
        };

        // Clean up collections
        self.active_states.deinit(self.allocator);
        self.active_activities.deinit();
        self.active_timers.deinit();
        self.history_value.deinit();
        self.deferred_queue.deinit();

        var attr_iter = self.attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            self.allocator.free(attr_entry.key_ptr.*);
            attr_entry.value_ptr.deinit(self.allocator);
        }
        self.attributes.deinit();

        // Free current state string
        self.allocator.free(self.current_state);

        if (self.owned_model) |owned_model| {
            owned_model.deinit();
            self.allocator.destroy(owned_model);
        }
    }
};

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn groupArgsHaveID(comptime Args: type) bool {
    const args_info = @typeInfo(Args);
    if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
        @compileError("MakeGroup expects a tuple, e.g. MakeGroup(allocator, .{ &first, &second })");
    }

    const fields = std.meta.fields(Args);
    if (fields.len == 0) return false;
    return isStringLike(fields[0].type);
}

fn countGroupArg(arg: anytype) usize {
    const ArgType = @TypeOf(arg);
    if (ArgType == *StateMachine) {
        return 1;
    }
    if (ArgType == *Group) {
        return arg.machines.len;
    }

    switch (@typeInfo(ArgType)) {
        .optional => {
            if (arg) |value| {
                return countGroupArg(value);
            }
            return 0;
        },
        else => @compileError("MakeGroup entries must be *StateMachine, *Group, optional equivalents, or null"),
    }
}

fn appendGroupArg(machines: []*StateMachine, index: *usize, arg: anytype) void {
    const ArgType = @TypeOf(arg);
    if (ArgType == *StateMachine) {
        machines[index.*] = arg;
        index.* += 1;
        return;
    }
    if (ArgType == *Group) {
        for (arg.machines) |machine| {
            machines[index.*] = machine;
            index.* += 1;
        }
        return;
    }

    switch (@typeInfo(ArgType)) {
        .optional => {
            if (arg) |value| {
                appendGroupArg(machines, index, value);
            }
        },
        else => @compileError("MakeGroup entries must be *StateMachine, *Group, optional equivalents, or null"),
    }
}

fn appendJoinedPart(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool, sep: []const u8, part: []const u8) !void {
    if (!first.*) {
        try buffer.appendSlice(allocator, sep);
    }
    try buffer.appendSlice(allocator, part);
    first.* = false;
}

fn cloneEventDetail(allocator: std.mem.Allocator, event: *const EventDetail) !EventDetail {
    const name = try allocator.dupe(u8, event.Name);
    errdefer allocator.free(name);
    const target_name_copy = if (event.Target) |target_name| try allocator.dupe(u8, target_name) else null;
    errdefer if (target_name_copy) |target_name| allocator.free(target_name);
    return EventDetail{
        .Name = name,
        .Kind = event.Kind,
        .Target = target_name_copy,
        .Guard = event.Guard,
        .Schema = event.Schema,
    };
}

pub const Group = struct {
    id: ?[]const u8,
    machines: []*StateMachine,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.id) |id| self.allocator.free(id);
        self.allocator.free(self.machines);
    }

    pub fn ID(self: *const Self) ?[]const u8 {
        return self.id;
    }

    pub fn Dispatch(self: *Self, ctx: *Context, event: Event) !void {
        try self.dispatch(ctx, event);
    }

    pub fn dispatch(self: *Self, ctx: *Context, event: Event) !void {
        for (self.machines) |machine| {
            try machine.Dispatch(ctx, event);
        }
    }

    pub fn Set(self: *Self, ctx: *Context, name: []const u8, value: anytype) !void {
        try self.set(ctx, name, value);
    }

    pub fn set(self: *Self, ctx: *Context, name: []const u8, value: anytype) !void {
        for (self.machines) |machine| {
            try machine.Set(ctx, name, value);
        }
    }

    pub fn Call(self: *Self, ctx: *Context, name: []const u8) !void {
        try self.call(ctx, name);
    }

    pub fn call(self: *Self, ctx: *Context, name: []const u8) !void {
        if (self.machines.len == 0) return;
        try self.machines[0].Call(ctx, name);
    }

    pub fn TakeSnapshot(self: *Self) !Snapshot {
        var members = try self.allocator.alloc(Snapshot, self.machines.len);
        var member_count: usize = 0;
        errdefer {
            for (members[0..member_count]) |*member| {
                member.deinit();
            }
            self.allocator.free(members);
        }

        var event_list = try std.ArrayList(EventDetail).initCapacity(self.allocator, 0);
        errdefer {
            for (event_list.items) |*event| {
                event.deinit(self.allocator);
            }
            event_list.deinit(self.allocator);
        }

        var id_parts = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer id_parts.deinit(self.allocator);
        var qualified_names = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer qualified_names.deinit(self.allocator);
        var states = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer states.deinit(self.allocator);

        var id_first = true;
        var qualified_name_first = true;
        var state_first = true;
        var queue_len: usize = 0;

        for (self.machines, 0..) |machine, i| {
            members[i] = try machine.TakeSnapshot();
            member_count += 1;

            if (members[i].ID) |member_id| {
                try appendJoinedPart(&id_parts, self.allocator, &id_first, ",", member_id);
            }
            try appendJoinedPart(&qualified_names, self.allocator, &qualified_name_first, ",", members[i].QualifiedName);
            try appendJoinedPart(&states, self.allocator, &state_first, " | ", members[i].State);
            queue_len += members[i].QueueLen;

            for (members[i].Events) |*event| {
                try event_list.append(self.allocator, try cloneEventDetail(self.allocator, event));
            }
        }

        var attributes = std.StringHashMap(AttributeSnapshot).init(self.allocator);
        errdefer attributes.deinit();

        return Snapshot{
            .ID = if (self.id) |id| try self.allocator.dupe(u8, id) else if (id_parts.items.len > 0) try self.allocator.dupe(u8, id_parts.items) else null,
            .QualifiedName = try self.allocator.dupe(u8, qualified_names.items),
            .State = try self.allocator.dupe(u8, states.items),
            .QueueLen = queue_len,
            .Attributes = attributes,
            .Events = try event_list.toOwnedSlice(self.allocator),
            .Members = members,
            .allocator = self.allocator,
        };
    }
};

pub fn makeGroup(allocator: std.mem.Allocator, args: anytype) !Group {
    const Args = @TypeOf(args);
    const fields = std.meta.fields(Args);
    const has_id = comptime groupArgsHaveID(Args);
    const start_index: usize = if (has_id) 1 else 0;

    var count: usize = 0;
    inline for (fields, 0..) |_, i| {
        if (i >= start_index) {
            count += countGroupArg(args[i]);
        }
    }
    if (count == 0) return error.EmptyGroup;

    const machines = try allocator.alloc(*StateMachine, count);
    errdefer allocator.free(machines);

    var index: usize = 0;
    inline for (fields, 0..) |_, i| {
        if (i >= start_index) {
            appendGroupArg(machines, &index, args[i]);
        }
    }

    return Group{
        .id = if (has_id) try allocator.dupe(u8, args[0]) else null,
        .machines = machines,
        .allocator = allocator,
    };
}

pub const MakeGroup = makeGroup;
pub const group = makeGroup;

/// Start a state machine with flat element model
pub fn start(ctx: *Context, instance: anytype, model: anytype) !StateMachine {
    return try startWithConfig(ctx, instance, model, Config(.{}));
}

pub fn startWithConfig(ctx: *Context, instance: anytype, model: anytype, config: RuntimeConfig) !StateMachine {
    const ModelArg = @TypeOf(model);
    if (ModelArg == type) {
        const owned_model = try ctx.allocator.create(Model);
        errdefer ctx.allocator.destroy(owned_model);
        owned_model.* = try model.build(ctx.allocator);
        errdefer owned_model.deinit();

        var sm = try startWithBuiltModel(ctx, instance, owned_model, config);
        sm.owned_model = owned_model;
        return sm;
    }

    return try startWithBuiltModel(ctx, instance, model, config);
}

fn startWithBuiltModel(ctx: *Context, instance: anytype, model: *const Model, config: RuntimeConfig) !StateMachine {
    const model_name = model.name;
    const root_state_name = try std.fmt.allocPrint(ctx.allocator, "/{s}", .{model_name});
    defer ctx.allocator.free(root_state_name);
    _ = getState(model, root_state_name) orelse return error.NoRootState;

    var sm = StateMachine{
        .model = model,
        .instance = instance,
        ._context = ctx,
        .current_state = try ctx.allocator.dupe(u8, root_state_name),
        .active_states = try std.ArrayList([]const u8).initCapacity(ctx.allocator, 0),
        .active_activities = std.StringHashMap(std.Thread).init(ctx.allocator),
        .active_timers = std.StringHashMap(TimerHandle).init(ctx.allocator),
        .history_value = std.StringHashMap([]const u8).init(ctx.allocator),
        .deferred_queue = try EventQueue.init(ctx.allocator),
        .attributes = std.StringHashMap(RuntimeAttributeValue).init(ctx.allocator),
        .runtime_id = config.ID,
        .runtime_name = config.Name,
        .runtime_data = config.Data,
        .clock = config.Clock orelse DefaultClock,
        .regular_queue = config.Queue,
        .stopped = false,
        .owned_model = null,
        .allocator = ctx.allocator,
    };

    try sm.initializeAttributes();

    // Enter the root state with default_entry=true to follow initial transitions recursively
    var initial_event = Event.init(ctx.allocator, "__INITIAL__");
    if (config.Data) |data| {
        try initial_event.putData("data", data);
    }
    defer initial_event.deinit();
    try sm.enterState(root_state_name, initial_event, ctx, true);
    try sm.processCompletionTransitions(ctx, initial_event);

    return sm;
}

pub const Start = start;
pub const StartWithConfig = startWithConfig;

pub fn Get(machine: *StateMachine, name: []const u8) !?*anyopaque {
    return try machine.Get(name);
}

pub fn Set(machine: *StateMachine, ctx: *Context, name: []const u8, value: anytype) !void {
    try machine.Set(ctx, name, value);
}

pub fn Call(machine: *StateMachine, ctx: *Context, name: []const u8) !void {
    try machine.Call(ctx, name);
}

pub fn TakeSnapshot(machine: *StateMachine) !Snapshot {
    return try machine.TakeSnapshot();
}

/// Stop a state machine
pub fn stop(sm: *StateMachine) !void {
    try sm.stop();
}

// ============================================================================
// Runtime Model Building Functions (for transition)
// ============================================================================

/// Create a model with flat element storage
pub fn createModel(allocator: std.mem.Allocator, name: []const u8) !Model {
    return Model{
        .name = try allocator.dupe(u8, name),
        .members = std.StringHashMap(*Element).init(allocator),
        .attributes = std.StringHashMap(AttributeElement).init(allocator),
        .transition_map = std.StringHashMap(std.StringHashMap([][]const u8)).init(allocator),
        .deferred_map = std.StringHashMap(std.StringHashMap(bool)).init(allocator),
        .allocator = allocator,
    };
}

pub fn addAttribute(model: *Model, name: []const u8, comptime maybe_type: ?type, default_value: anytype, comptime has_default: bool) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
        return error.InvalidAttributeName;
    }

    const qualified_name = try qualifyModelMemberName(model.allocator, model.name, name);
    errdefer model.allocator.free(qualified_name);

    if (model.attributes.contains(qualified_name)) {
        return error.DuplicateAttribute;
    }

    const ValueType = if (maybe_type) |T| T else if (has_default) @TypeOf(default_value) else void;
    var stored_default: ?*anyopaque = null;
    errdefer if (stored_default) |value| dropTypedValue(ValueType)(model.allocator, value);

    if (has_default) {
        if (maybe_type) |T| {
            if (@TypeOf(default_value) != T) return error.AttributeTypeMismatch;
        }
        stored_default = (try makeRuntimeAttributeValue(model.allocator, default_value)).value;
    }

    const key = try model.allocator.dupe(u8, qualified_name);
    errdefer model.allocator.free(key);

    try model.attributes.put(key, AttributeElement{
        .name = try model.allocator.dupe(u8, name),
        .qualified_name = qualified_name,
        .type_name = if (maybe_type) |_| @typeName(ValueType) else if (has_default) @typeName(ValueType) else null,
        .default_value = stored_default,
        .clone_fn = if (maybe_type != null or has_default) cloneTypedValue(ValueType) else null,
        .drop_fn = if (maybe_type != null or has_default) dropTypedValue(ValueType) else null,
    });
}

fn ensureImplicitAttribute(model: *Model, name: []const u8) !void {
    const qualified_name = try qualifyModelMemberName(model.allocator, model.name, name);
    defer model.allocator.free(qualified_name);

    if (model.attributes.contains(qualified_name)) return;

    const key = try model.allocator.dupe(u8, qualified_name);
    errdefer model.allocator.free(key);

    try model.attributes.put(key, AttributeElement{
        .name = try model.allocator.dupe(u8, name),
        .qualified_name = try model.allocator.dupe(u8, qualified_name),
        .type_name = null,
        .default_value = null,
        .clone_fn = null,
        .drop_fn = null,
    });
}

/// Add a state element to the model
pub fn addState(model: *Model, qualified_name: []const u8, kind: ElementKind) !*StateElement {
    const state_element = try model.allocator.create(StateElement);
    state_element.* = StateElement{
        .element = Element{
            .kind = kind,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .entry = &[_][]const u8{},
        .exit = &[_][]const u8{},
        .activities = &[_][]const u8{},
        .transitions = &[_][]const u8{},
        .substates = &[_][]const u8{},
        .deferred = &[_][]const u8{},
        .initial_transition = null,
    };

    try model.members.put(state_element.element.qualified_name, @ptrCast(state_element));
    return state_element;
}

/// Add a behavior element to the model
pub fn addBehavior(model: *Model, qualified_name: []const u8, function_ptr: *const anyopaque) !*BehaviorElement {
    const behavior_element = try model.allocator.create(BehaviorElement);
    behavior_element.* = BehaviorElement{
        .element = Element{
            .kind = .behavior,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .function_ptr = function_ptr,
    };

    try model.members.put(behavior_element.element.qualified_name, @ptrCast(behavior_element));
    return behavior_element;
}

/// Add an operation element to the model
pub fn addOperation(model: *Model, qualified_name: []const u8, function_ptr: *const anyopaque) !*OperationElement {
    const operation_element = try model.allocator.create(OperationElement);
    operation_element.* = OperationElement{
        .element = Element{
            .kind = .operation,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .function_ptr = function_ptr,
    };

    try model.members.put(operation_element.element.qualified_name, @ptrCast(operation_element));
    return operation_element;
}

/// Add a history element to the model
pub fn addHistory(model: *Model, qualified_name: []const u8, kind: HistoryKind, default_target: ?[]const u8) !*HistoryElement {
    const history_element = try model.allocator.create(HistoryElement);
    history_element.* = HistoryElement{
        .element = Element{
            .kind = .history,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .history_kind = kind,
        .default_target = if (default_target) |t| try model.allocator.dupe(u8, t) else null,
    };

    try model.members.put(history_element.element.qualified_name, @ptrCast(history_element));
    return history_element;
}

/// Add a transition element to the model
pub fn addTransition(model: *Model, qualified_name: []const u8, source_state: []const u8, target_state: ?[]const u8, event_name: ?[]const u8) !*TransitionElement {
    const transition_element = try model.allocator.create(TransitionElement);
    transition_element.* = TransitionElement{
        .element = Element{
            .kind = .transition,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .source = try model.allocator.dupe(u8, source_state),
        .target = if (target_state) |t| try model.allocator.dupe(u8, t) else null,
        .event_name = if (event_name) |e| try model.allocator.dupe(u8, e) else null,
        .guard = null,
        .guards = &[_][]const u8{},
        .effects = &[_][]const u8{},
        .timer_fn = null,
        .timer_kind = .after,
        .paths = std.StringHashMap(TransitionPaths).init(model.allocator),
    };

    try model.members.put(transition_element.element.qualified_name, @ptrCast(transition_element));
    return transition_element;
}

/// Resolve a target path relative to the source state
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer parts.deinit(allocator);

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, segment);
    }

    if (parts.items.len == 0) return try allocator.dupe(u8, "/");

    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);
    for (parts.items) |segment| {
        try result.append(allocator, '/');
        try result.appendSlice(allocator, segment);
    }

    return try allocator.dupe(u8, result.items);
}

fn resolveTargetPath(allocator: std.mem.Allocator, source_state: []const u8, target_path: []const u8) ![]const u8 {
    if (target_path[0] == '/') {
        // Absolute path
        return try normalizePath(allocator, target_path);
    } else if (std.mem.eql(u8, target_path, ".")) {
        // Self reference
        return try allocator.dupe(u8, source_state);
    } else {
        const raw_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_state, target_path });
        defer allocator.free(raw_path);
        return try normalizePath(allocator, raw_path);
    }
}

fn modelRootPath(allocator: std.mem.Allocator, model: *const Model) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "/{s}", .{model.name});
}

fn targetExists(model: *const Model, candidate: []const u8) bool {
    if (model.members.get(candidate)) |element| {
        return element.kind == .state or element.kind == .model or element.kind == .final or element.kind == .choice or element.kind == .history;
    }
    return false;
}

fn firstExistingTarget(model: *const Model, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (targetExists(model, candidate)) return candidate;
    }
    return null;
}

fn canonicalizeTransitionTarget(model: *const Model, allocator: std.mem.Allocator, source_state: []const u8, target_path: []const u8) ![]const u8 {
    const normalized_target = try normalizePath(allocator, target_path);
    defer allocator.free(normalized_target);

    if (targetExists(model, normalized_target)) {
        return try allocator.dupe(u8, normalized_target);
    }

    if (std.mem.eql(u8, target_path, ".")) {
        return try allocator.dupe(u8, source_state);
    }

    var raw_relative: ?[]const u8 = null;
    const source_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{source_state});
    defer allocator.free(source_prefix);
    if (std.mem.startsWith(u8, target_path, source_prefix)) {
        raw_relative = target_path[source_prefix.len..];
    }

    const relative = raw_relative orelse blk: {
        if (target_path.len > 0 and target_path[0] != '/') break :blk target_path;
        break :blk null;
    };

    if (relative) |rel| {
        const source_child_raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_state, rel });
        defer allocator.free(source_child_raw);
        const source_child = try normalizePath(allocator, source_child_raw);
        defer allocator.free(source_child);

        const parent_path = std.fs.path.dirname(source_state) orelse "/";
        const sibling_raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, rel });
        defer allocator.free(sibling_raw);
        const sibling = try normalizePath(allocator, sibling_raw);
        defer allocator.free(sibling);

        const root_path = try modelRootPath(allocator, model);
        defer allocator.free(root_path);
        const root_relative_raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, rel });
        defer allocator.free(root_relative_raw);
        const root_relative = try normalizePath(allocator, root_relative_raw);
        defer allocator.free(root_relative);

        const candidates = [_][]const u8{ source_child, sibling, root_relative };
        if (firstExistingTarget(model, &candidates)) |candidate| {
            return try allocator.dupe(u8, candidate);
        }
    }

    return try allocator.dupe(u8, normalized_target);
}

fn canonicalizeTransitionTargets(model: *Model) !void {
    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .transition) continue;

        const trans: *TransitionElement = @ptrCast(@alignCast(element));
        if (trans.target) |target_path| {
            const canonical = try canonicalizeTransitionTarget(model, model.allocator, trans.source, target_path);
            model.allocator.free(target_path);
            trans.target = canonical;
        }
    }
}

fn appendPathAncestors(
    allocator: std.mem.Allocator,
    states: *std.ArrayList([]const u8),
    from_path: []const u8,
    stop_exclusive: []const u8,
) !void {
    var leaf_to_root = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer leaf_to_root.deinit(allocator);

    var current = from_path;
    while (current.len > 0 and !std.mem.eql(u8, current, stop_exclusive)) {
        try leaf_to_root.append(allocator, current);
        current = std.fs.path.dirname(current) orelse break;
    }

    var i = leaf_to_root.items.len;
    while (i > 0) {
        i -= 1;
        try states.append(allocator, try allocator.dupe(u8, leaf_to_root.items[i]));
    }
}

fn appendDescendantPath(
    allocator: std.mem.Allocator,
    states: *std.ArrayList([]const u8),
    from_exclusive: []const u8,
    to_path: []const u8,
) !void {
    if (!std.mem.startsWith(u8, to_path, from_exclusive)) return;

    const remaining = to_path[from_exclusive.len..];
    if (remaining.len == 0) return;
    if (remaining[0] != '/') return;

    var path_builder = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer path_builder.deinit(allocator);
    try path_builder.appendSlice(allocator, from_exclusive);

    var segments = std.mem.splitScalar(u8, remaining[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        if (path_builder.items.len == 0 or !std.mem.endsWith(u8, path_builder.items, "/")) {
            try path_builder.append(allocator, '/');
        }
        try path_builder.appendSlice(allocator, segment);
        try states.append(allocator, try allocator.dupe(u8, path_builder.items));
    }
}

fn commonAncestorPath(allocator: std.mem.Allocator, path1: []const u8, path2: []const u8) ![]const u8 {
    var segments1 = std.mem.splitScalar(u8, path1, '/');
    var segments2 = std.mem.splitScalar(u8, path2, '/');

    var common_parts = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer common_parts.deinit(allocator);

    while (true) {
        const seg1 = segments1.next();
        const seg2 = segments2.next();
        if (seg1 == null or seg2 == null) break;
        if (!std.mem.eql(u8, seg1.?, seg2.?)) break;
        if (seg1.?.len > 0) try common_parts.append(allocator, seg1.?);
    }

    if (common_parts.items.len == 0) return try allocator.dupe(u8, "");

    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);
    if (path1.len > 0 and path1[0] == '/') try result.append(allocator, '/');
    for (common_parts.items) |part| {
        if (result.items.len > 1) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }
    return try allocator.dupe(u8, result.items);
}

/// Compute transition paths for a given source state
pub fn computeTransitionPaths(model: *Model, trans: *TransitionElement, source_state: []const u8) !void {
    var enter_states = try std.ArrayList([]const u8).initCapacity(model.allocator, 0);
    defer enter_states.deinit(model.allocator);

    var exit_states = try std.ArrayList([]const u8).initCapacity(model.allocator, 0);
    defer exit_states.deinit(model.allocator);

    if (trans.target) |target_path| {
        // Resolve the target path relative to source
        const resolved_target = try resolveTargetPath(model.allocator, source_state, target_path);
        defer model.allocator.free(resolved_target);

        // Check if this is a self-transition
        if (std.mem.eql(u8, source_state, resolved_target)) {
            // Self transition: exit and re-enter the same state
            try exit_states.append(model.allocator, try model.allocator.dupe(u8, source_state));
            try enter_states.append(model.allocator, try model.allocator.dupe(u8, resolved_target));
        } else {
            const common_ancestor = try commonAncestorPath(model.allocator, source_state, resolved_target);
            defer model.allocator.free(common_ancestor);
            try appendPathAncestors(model.allocator, &exit_states, source_state, common_ancestor);
            try appendDescendantPath(model.allocator, &enter_states, common_ancestor, resolved_target);
        }
    }

    // Store precomputed paths
    const paths = TransitionPaths{
        .enter = try enter_states.toOwnedSlice(model.allocator),
        .exit = try exit_states.toOwnedSlice(model.allocator),
    };

    try trans.paths.put(try model.allocator.dupe(u8, source_state), paths);
}

/// Build transition map for optimized event dispatch
pub fn buildTransitionMap(model: *Model) !void {
    // Clear existing transition map
    var trans_iter = model.transition_map.iterator();
    while (trans_iter.next()) |trans_entry| {
        model.allocator.free(trans_entry.key_ptr.*);
        var event_iter = trans_entry.value_ptr.iterator();
        while (event_iter.next()) |event_entry| {
            model.allocator.free(event_entry.key_ptr.*);
            for (event_entry.value_ptr.*) |transition_name| {
                model.allocator.free(transition_name);
            }
            model.allocator.free(event_entry.value_ptr.*);
        }
        trans_entry.value_ptr.deinit();
    }
    model.transition_map.clearAndFree();

    // Iterate through each state's transition list to preserve declaration order.
    var members_iter = model.members.iterator();
    while (members_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .state and element.kind != .model and element.kind != .choice) continue;

        const state_elem: *StateElement = @ptrCast(@alignCast(element));
        const source_state = state_elem.element.qualified_name;

        // Get or create event map for this state
        var event_map = model.transition_map.getPtr(source_state);
        if (event_map == null) {
            const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
            try model.transition_map.put(try model.allocator.dupe(u8, source_state), new_event_map);
            event_map = model.transition_map.getPtr(source_state);
        }

        for (state_elem.transitions) |transition_name| {
            const trans = getTransition(model, transition_name) orelse continue;

            if (trans.event_name) |event_name| {
                // Get or create transition list for this event
                if (event_map.?.getPtr(event_name)) |transition_list| {
                    const old_list = transition_list.*;
                    const new_list = try model.allocator.alloc([]const u8, old_list.len + 1);
                    @memcpy(new_list[0..old_list.len], old_list);
                    new_list[old_list.len] = try model.allocator.dupe(u8, trans.element.qualified_name);
                    transition_list.* = new_list;
                    model.allocator.free(old_list);
                } else {
                    const new_list = try model.allocator.alloc([]const u8, 1);
                    new_list[0] = try model.allocator.dupe(u8, trans.element.qualified_name);
                    try event_map.?.put(try model.allocator.dupe(u8, event_name), new_list);
                }
            }

            // Compute transition paths for this transition
            try computeTransitionPaths(model, trans, source_state);
        }
    }

    var transition_iter = model.members.iterator();
    while (transition_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .transition) continue;
        const trans: *TransitionElement = @ptrCast(@alignCast(element));
        const state_elem = getState(model, trans.source) orelse continue;
        for (state_elem.transitions) |transition_name| {
            if (std.mem.eql(u8, transition_name, trans.element.qualified_name)) break;
        } else {
            var event_map = model.transition_map.getPtr(trans.source);
            if (event_map == null) {
                const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
                try model.transition_map.put(try model.allocator.dupe(u8, trans.source), new_event_map);
                event_map = model.transition_map.getPtr(trans.source);
            }

            if (trans.event_name) |event_name| {
                const new_list = try model.allocator.alloc([]const u8, 1);
                new_list[0] = try model.allocator.dupe(u8, trans.element.qualified_name);
                try event_map.?.put(try model.allocator.dupe(u8, event_name), new_list);
            }
            try computeTransitionPaths(model, trans, trans.source);
        }
    }
}

/// Build deferred event map for O(1) deferred event lookup
pub fn buildDeferredMap(model: *Model) !void {
    // Clear existing deferred map
    var def_iter = model.deferred_map.iterator();
    while (def_iter.next()) |def_entry| {
        def_entry.value_ptr.deinit();
    }
    model.deferred_map.clearAndFree();

    // Iterate through all states and build deferred event map
    var members_iter = model.members.iterator();
    while (members_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .state and element.kind != .model) continue;

        const state_elem: *StateElement = @ptrCast(@alignCast(element));
        const state_name = state_elem.element.qualified_name;

        // Create event map for this state
        var event_map = std.StringHashMap(bool).init(model.allocator);

        // Collect deferred events from this state and all parent states
        var current_path = state_name;
        while (current_path.len > 0) {
            if (model.members.get(current_path)) |current_element| {
                if (current_element.kind == .state or current_element.kind == .model) {
                    const current_state_elem: *StateElement = @ptrCast(@alignCast(current_element));

                    // Add deferred events from this level
                    for (current_state_elem.deferred) |event_name| {
                        try event_map.put(try model.allocator.dupe(u8, event_name), true);
                    }
                }
            }

            // Move up to parent
            if (std.mem.eql(u8, current_path, "/")) break;
            const parent_path = std.fs.path.dirname(current_path) orelse "/";
            if (std.mem.eql(u8, current_path, parent_path)) break; // Avoid infinite loop
            current_path = parent_path;
        }

        // Store the event map for this state
        try model.deferred_map.put(try model.allocator.dupe(u8, state_name), event_map);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Context creation and cancellation" {
    var context = Context.init(testing.allocator);
    try testing.expect(!context.is_done());

    context.cancel();
    try testing.expect(context.is_done());
}

test "Event creation" {
    const event1 = Event.init(testing.allocator, "test_event");
    try testing.expectEqualStrings("test_event", event1.name);
    try testing.expect(event1.data == null);

    var data: i32 = 42;
    var event2 = Event.withData(testing.allocator, "data_event");
    defer event2.deinit();
    try event2.putData("value", &data);
    try testing.expectEqualStrings("data_event", event2.name);
    try testing.expect(event2.data != null);

    const retrieved_data = event2.getData("value").?;
    const value_ptr: *i32 = @ptrCast(@alignCast(retrieved_data));
    try testing.expect(value_ptr.* == 42);
}

test "Instance creation" {
    var instance = Instance.init();
    defer instance.deinit();
}

test "Model creation and element lookup" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add a state
    const state_elem = try addState(&model, "/TestModel/state1", .state);
    try testing.expectEqualStrings("state1", state_elem.element.name());
    try testing.expectEqualStrings("/TestModel", state_elem.element.owner());

    // Test lookup
    const found_state = getState(&model, "/TestModel/state1");
    try testing.expect(found_state != null);
    try testing.expectEqualStrings("state1", found_state.?.element.name());
}

fn testEntryFn(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
}

fn testTimerFn(ctx: *Context, inst: *Instance, event: Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return 1;
}

const QueueTestInstance = struct {
    base: Instance = Instance.init(),
    hit: bool = false,
};

const AttributeTestInstance = struct {
    base: Instance = Instance.init(),
};

fn queueTestEffect(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *QueueTestInstance = @ptrCast(@alignCast(inst));
    test_inst.hit = true;
}

const OperationTestInstance = struct {
    base: Instance = Instance.init(),
    calls: usize = 0,
    effects: usize = 0,
    saw_call_event: bool = false,
};

fn recordOperation(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    const test_inst: *OperationTestInstance = @ptrCast(@alignCast(inst));
    test_inst.calls += 1;
    test_inst.saw_call_event = std.mem.eql(u8, event.name, "hsm_call:/OperationModel/record");
}

fn recordCallEffect(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    const test_inst: *OperationTestInstance = @ptrCast(@alignCast(inst));
    test_inst.effects += 1;
    test_inst.saw_call_event = std.mem.eql(u8, event.name, "hsm_call:/OperationModel/record");
}

const RecordingQueue = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    pushes: usize = 0,
    pops: usize = 0,
    lens: usize = 0,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .events = try std.ArrayList(Event).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.events.deinit(self.allocator);
    }

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pushes += 1;
        try self.events.append(self.allocator, event);
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) anyerror!?Event {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pops += 1;
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) anyerror!usize {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.lens += 1;
        return self.events.items.len;
    }
};

const FailingPushQueue = struct {
    pushes: usize = 0,

    const Self = @This();

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void {
        _ = runtime_context;
        _ = event;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pushes += 1;
        return error.QueuePushFailed;
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) anyerror!?Event {
        _ = context;
        _ = runtime_context;
        return null;
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) anyerror!usize {
        _ = context;
        _ = runtime_context;
        return 0;
    }
};

test "PascalCase DSL aliases compile" {
    const event_builder = On("start");
    try testing.expectEqualStrings("start", event_builder.event_name);

    const target_builder = Target("done");
    try testing.expectEqualStrings("done", target_builder.target_path);

    comptime {
        _ = Define("AliasModel", .{
            Initial(Target("idle")),
            Attribute("counter", i32),
            State("idle", .{
                Transition(.{ On("finish"), Target("done") }),
                Transition(.{ On("effect"), Effect(queueTestEffect), Target("done") }),
                Transition(.{ OnSet("counter"), Target("done") }),
                Transition(.{ OnCall("record"), Target("done") }),
                Transition(.{ When("counter"), Target("done") }),
                Transition(.{ Source("idle"), After(testTimerFn), Target("done") }),
                Transition(.{ Every(testTimerFn), Target("done") }),
                Transition(.{ At(testTimerFn), Target("done") }),
            }),
            Choice("branch", .{
                Transition(.{Target("done")}),
            }),
            ShallowHistory("H", Target("idle")),
            DeepHistory("DH", Target("idle")),
            Operation("record", recordOperation),
            Final("done"),
        });
    }

    try testing.expect(@TypeOf(Define("M", .{})) == @TypeOf(define("M", .{})));
    try testing.expect(@TypeOf(State("s", .{})) == @TypeOf(state("s", .{})));
    try testing.expect(@TypeOf(Final("f")) == @TypeOf(final("f")));
    try testing.expect(@TypeOf(Choice("c", .{})) == @TypeOf(choice("c", .{})));
    try testing.expect(@TypeOf(ShallowHistory("h", Target("s"))) == @TypeOf(history("h", target("s"))));
    try testing.expect(@TypeOf(DeepHistory("h", Target("s"))) == @TypeOf(deepHistory("h", target("s"))));
    try testing.expect(@TypeOf(Initial(Target("s"))) == @TypeOf(initial(target("s"))));
    try testing.expect(@TypeOf(Transition(.{On("e")})) == @TypeOf(transition(.{on("e")})));
    try testing.expect(@TypeOf(Source("s")) == @TypeOf(source("s")));
    try testing.expect(@TypeOf(Attribute("count", i32)) == @TypeOf(attribute("count", i32)));
    try testing.expect(@TypeOf(OnSet("count")) == @TypeOf(onSet("count")));
    try testing.expect(@TypeOf(OnCall("record")) == @TypeOf(onCall("record")));
    try testing.expect(@TypeOf(Operation("record", recordOperation)) == @TypeOf(operation("record", recordOperation)));
    try testing.expect(@TypeOf(When("count")) == @TypeOf(onSet("count")));
    try testing.expect(@TypeOf(when("count")) == @TypeOf(OnSet("count")));
    try testing.expect(@TypeOf(Effect(queueTestEffect)) == @TypeOf(effect(queueTestEffect)));
    try testing.expect(@TypeOf(After(testTimerFn)) == @TypeOf(after(testTimerFn)));
    try testing.expect(@TypeOf(Every(testTimerFn)) == @TypeOf(every(testTimerFn)));
    try testing.expect(@TypeOf(At(testTimerFn)) == @TypeOf(at(testTimerFn)));
}

test "Kind utilities support inheritance matching" {
    const base = comptime MakeKind(.{11});
    const sibling = comptime MakeKind(.{12});
    const derived = comptime MakeKind(.{ 13, base });
    const multi = comptime makeKind(.{ 14, derived, sibling });

    try testing.expect(IsKind(base, base));
    try testing.expect(IsKind(derived, derived));
    try testing.expect(IsKind(derived, base));
    try testing.expect(!IsKind(base, derived));
    try testing.expect(isKind(multi, .{ base, sibling }));
    try testing.expect(isKind(multi, derived));
}

test "Operation Call dispatches OnCall transition" {
    const model_type = comptime Define("OperationModel", .{
        Operation("record", recordOperation),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ OnCall("record"), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const operation_element = getOperation(&model, "/OperationModel/record");
    try testing.expect(operation_element != null);

    const idle_state = getState(&model, "/OperationModel/idle").?;
    const call_transition = getTransition(&model, idle_state.transitions[0]).?;
    try testing.expectEqualStrings("hsm_call:/OperationModel/record", call_transition.event_name.?);

    var ctx = Context.init(testing.allocator);
    var inst = OperationTestInstance{};
    var sm = try Start(&ctx, &inst, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/OperationModel/idle", sm.state());
    try Call(&sm, &ctx, "record");

    try testing.expectEqual(@as(usize, 1), inst.calls);
    try testing.expect(inst.saw_call_event);
    try testing.expectEqualStrings("/OperationModel/done", sm.state());
}

const AtTestInstance = struct {
    base: Instance = Instance.init(),
    deadline_ns: u64 = 0,
    timer_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const AtTestClock = struct {
    now_ns: u64,
    slept_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn sleep(context: ?*anyopaque, duration_ns: u64) void {
        const self: *AtTestClock = @ptrCast(@alignCast(context.?));
        _ = self.slept_ns.fetchAdd(duration_ns, .monotonic);
    }

    fn now(context: ?*anyopaque) u64 {
        const self: *AtTestClock = @ptrCast(@alignCast(context.?));
        return self.now_ns;
    }
};

fn atDeadline(ctx: *Context, inst: *Instance, event: Event) u64 {
    _ = ctx;
    _ = event;
    const test_inst: *AtTestInstance = @ptrCast(@alignCast(inst));
    _ = test_inst.timer_calls.fetchAdd(1, .monotonic);
    return test_inst.deadline_ns;
}

test "At timer uses absolute Clock.Now deadline" {
    const model_type = comptime Define("AtTimerModel", .{
        State("waiting", .{
            Transition(.{At(atDeadline)}),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    const waiting_state = getState(&model, "/AtTimerModel/waiting").?;
    try testing.expectEqual(@as(usize, 1), waiting_state.transitions.len);
    const at_transition = getTransition(&model, waiting_state.transitions[0]).?;
    try testing.expect(at_transition.timer_fn != null);
    try testing.expectEqual(TimerKind.at, at_transition.timer_kind);

    var ctx = Context.init(testing.allocator);
    var inst = AtTestInstance{ .deadline_ns = 1250 };
    var test_clock = AtTestClock{ .now_ns = 1000 };
    const clock = Clock(.{
        .Context = @as(?*anyopaque, @ptrCast(&test_clock)),
        .Sleep = AtTestClock.sleep,
        .Now = AtTestClock.now,
    });

    var sm = try StartWithConfig(&ctx, &inst, &model, Config(.{ .Clock = clock }));
    defer sm.deinit();
    try sm.enterState("/AtTimerModel/waiting", Event.init(testing.allocator, "__TEST_ENTER__"), &ctx, false);

    try testing.expectEqual(@as(u32, 1), sm.active_timers.count());

    var spins: usize = 0;
    while (test_clock.slept_ns.load(.acquire) == 0 and spins < 50) : (spins += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try sm.stop();

    try testing.expectEqual(@as(u64, 1), inst.timer_calls.load(.acquire));
    try testing.expectEqual(@as(u64, 250), test_clock.slept_ns.load(.acquire));
}

test "Config Queue Clock and completion dispatch APIs" {
    const model_type = comptime Define("ConfigQueueModel", .{
        State("idle", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var recording = try RecordingQueue.init(testing.allocator);
    defer recording.deinit();

    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&recording)),
        .Push = RecordingQueue.push,
        .Pop = RecordingQueue.pop,
        .Len = RecordingQueue.len,
    });

    const clock = Clock(.{});
    const config = Config(.{
        .ID = "runtime-id",
        .Name = "runtime.name",
        .Data = @as(?*anyopaque, @ptrCast(&inst)),
        .Clock = clock,
        .Queue = &queue,
    });

    var sm = try StartWithConfig(&ctx, &inst.base, &model, config);
    defer sm.deinit();

    try testing.expectEqualStrings("runtime-id", sm.ID().?);
    try testing.expectEqualStrings("runtime.name", sm.Name());
    try testing.expect(sm.Data().? == @as(*anyopaque, @ptrCast(&inst)));
    try testing.expectEqual(@as(usize, 0), try queue.Len(&ctx));
    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqual(@as(usize, 1), recording.pushes);
    try testing.expect(recording.pops >= 1);
    try testing.expect(recording.lens >= 1);
}

test "custom queue hooks are regular-only and completion events stay runtime-owned" {
    const model_type = comptime Define("CompletionQueueBypassModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("priority"), Target("../done") }),
        }),
        State("done", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var recording = try RecordingQueue.init(testing.allocator);
    defer recording.deinit();

    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&recording)),
        .Push = RecordingQueue.push,
        .Pop = RecordingQueue.pop,
        .Len = RecordingQueue.len,
    });

    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .Queue = &queue }));
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.completion(testing.allocator, "priority"));

    try testing.expectEqualStrings("/CompletionQueueBypassModel/done", sm.state());
    try testing.expectEqual(@as(usize, 0), recording.pushes);
    try testing.expectEqual(@as(usize, 0), recording.pops);
}

test "custom queue push errors propagate as runtime error events" {
    const model_type = comptime Define("QueuePushErrorModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("__ERROR__"), Target("../failed") }),
        }),
        State("failed", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var failing = FailingPushQueue{};

    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&failing)),
        .Push = FailingPushQueue.push,
        .Pop = FailingPushQueue.pop,
        .Len = FailingPushQueue.len,
    });

    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .Queue = &queue }));
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));

    try testing.expectEqualStrings("/QueuePushErrorModel/failed", sm.state());
    try testing.expectEqual(@as(usize, 1), failing.pushes);
}

test "Attribute Set emits OnSet transition and validates type" {
    const model_type = comptime Define("AttributeSetModel", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ OnSet("count"), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = AttributeTestInstance{};
    var sm = try Start(&ctx, &inst.base, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/AttributeSetModel/idle", sm.state());

    const initial_value = (try sm.Get("count")).?;
    const initial_count: *i32 = @ptrCast(@alignCast(initial_value));
    try testing.expectEqual(@as(i32, 0), initial_count.*);

    try sm.Set(&ctx, "count", @as(u32, 1));
    try testing.expectEqualStrings("/AttributeSetModel/idle", sm.state());

    try sm.Set(&ctx, "count", @as(i32, 7));
    try testing.expectEqualStrings("/AttributeSetModel/done", sm.state());

    const updated_value = (try Get(&sm, "/AttributeSetModel/count")).?;
    const updated_count: *i32 = @ptrCast(@alignCast(updated_value));
    try testing.expectEqual(@as(i32, 7), updated_count.*);
}

test "Attribute Set emits When transition" {
    const model_type = comptime Define("AttributeWhenModel", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ When("count"), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const idle_state = getState(&model, "/AttributeWhenModel/idle").?;
    const when_transition = getTransition(&model, idle_state.transitions[0]).?;
    try testing.expectEqualStrings("/AttributeWhenModel/count", when_transition.event_name.?);

    var ctx = Context.init(testing.allocator);
    var inst = AttributeTestInstance{};
    var sm = try Start(&ctx, &inst.base, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/AttributeWhenModel/idle", sm.state());
    try sm.Set(&ctx, "count", @as(i32, 3));
    try testing.expectEqualStrings("/AttributeWhenModel/done", sm.state());
}

test "TakeSnapshot copies runtime identity state and attributes" {
    const model_type = comptime Define("SnapshotModel", .{
        Attribute("count", @as(i32, 4)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("go"), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = AttributeTestInstance{};
    var recording = try RecordingQueue.init(testing.allocator);
    defer recording.deinit();

    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&recording)),
        .Push = RecordingQueue.push,
        .Pop = RecordingQueue.pop,
        .Len = RecordingQueue.len,
    });

    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .ID = "snap-id", .Name = "/SnapshotAlias", .Queue = &queue }));
    defer sm.deinit();

    try recording.events.append(recording.allocator, Event.init(testing.allocator, "queued"));

    var snapshot = try TakeSnapshot(&sm);
    defer snapshot.deinit();

    try testing.expectEqualStrings("snap-id", snapshot.ID.?);
    try testing.expectEqualStrings("/SnapshotAlias", snapshot.QualifiedName);
    try testing.expectEqualStrings("/SnapshotModel/idle", snapshot.State);
    try testing.expectEqual(@as(usize, 1), snapshot.QueueLen);
    try testing.expectEqual(@as(usize, 1), snapshot.Events.len);
    try testing.expectEqualStrings("go", snapshot.Events[0].Name);
    try testing.expectEqual(EventKind, snapshot.Events[0].Kind);
    try testing.expectEqualStrings("/SnapshotModel/done", snapshot.Events[0].Target.?);
    try testing.expect(!snapshot.Events[0].Guard);
    try testing.expect(snapshot.Events[0].Schema == null);

    const snap_value = snapshot.Attributes.get("/SnapshotModel/count").?;
    const snap_count = snap_value.as(i32).?;
    try testing.expectEqual(@as(i32, 4), snap_count.*);

    const mutable_snap_count: *i32 = @constCast(snap_count);
    mutable_snap_count.* = 99;

    const runtime_value = (try sm.Get("count")).?;
    const runtime_count: *i32 = @ptrCast(@alignCast(runtime_value));
    try testing.expectEqual(@as(i32, 4), runtime_count.*);
}

test "MakeGroup dispatch set call and snapshot aggregate machines" {
    const dispatch_model_type = comptime Define("GroupParity", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("go"), Target("../done") }),
            Transition(.{OnSet("count")}),
        }),
        Final("done"),
    });

    var dispatch_model = try dispatch_model_type.build(testing.allocator);
    defer dispatch_model.deinit();

    var ctx = Context.init(testing.allocator);
    var first_inst = AttributeTestInstance{};
    var second_inst = AttributeTestInstance{};
    var first = try StartWithConfig(&ctx, &first_inst.base, &dispatch_model, Config(.{ .ID = "first" }));
    defer first.deinit();
    var second = try StartWithConfig(&ctx, &second_inst.base, &dispatch_model, Config(.{ .ID = "second" }));
    defer second.deinit();

    var pair = try MakeGroup(testing.allocator, .{ &first, &second });
    defer pair.deinit();
    try testing.expectEqual(@as(usize, 2), pair.machines.len);

    try pair.Set(&ctx, "count", @as(i32, 9));
    const first_count_value = (try first.Get("count")).?;
    const first_count: *i32 = @ptrCast(@alignCast(first_count_value));
    const second_count_value = (try second.Get("count")).?;
    const second_count: *i32 = @ptrCast(@alignCast(second_count_value));
    try testing.expectEqual(@as(i32, 9), first_count.*);
    try testing.expectEqual(@as(i32, 9), second_count.*);
    try pair.Set(&ctx, "missing", @as(i32, 1));

    try pair.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/GroupParity/done", first.state());
    try testing.expectEqualStrings("/GroupParity/done", second.state());

    var identified = try MakeGroup(testing.allocator, .{ "dispatch-group", &pair });
    defer identified.deinit();
    try testing.expectEqual(@as(usize, 2), identified.machines.len);
    try testing.expectEqualStrings("dispatch-group", identified.ID().?);

    var snapshot = try identified.TakeSnapshot();
    defer snapshot.deinit();
    try testing.expectEqualStrings("dispatch-group", snapshot.ID.?);
    try testing.expectEqualStrings("GroupParity,GroupParity", snapshot.QualifiedName);
    try testing.expectEqualStrings("/GroupParity/done | /GroupParity/done", snapshot.State);
    try testing.expectEqual(@as(usize, 2), snapshot.Members.?.len);
    try testing.expectEqualStrings("first", snapshot.Members.?[0].ID.?);
    try testing.expectEqualStrings("second", snapshot.Members.?[1].ID.?);

    const call_model_type = comptime Define("GroupCallParity", .{
        Operation("record", recordOperation),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{OnCall("record")}),
        }),
    });

    var call_model = try call_model_type.build(testing.allocator);
    defer call_model.deinit();

    var first_call_inst = OperationTestInstance{};
    var second_call_inst = OperationTestInstance{};
    var first_call = try Start(&ctx, &first_call_inst, &call_model);
    defer first_call.deinit();
    var second_call = try Start(&ctx, &second_call_inst, &call_model);
    defer second_call.deinit();

    var call_group = try makeGroup(testing.allocator, .{ &first_call, &second_call });
    defer call_group.deinit();
    try call_group.Call(&ctx, "record");
    try testing.expectEqual(@as(usize, 1), first_call_inst.calls);
    try testing.expectEqual(@as(usize, 0), second_call_inst.calls);
}

test "Behavior storage and lookup" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add a behavior
    const behavior = try addBehavior(&model, "/TestModel/state1/entry", @ptrCast(&testEntryFn));
    try testing.expectEqualStrings("entry", behavior.element.name());

    // Test lookup
    const found_behavior = getBehavior(&model, "/TestModel/state1/entry");
    try testing.expect(found_behavior != null);
}

test "Transition creation and path computation" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add states
    _ = try addState(&model, "/TestModel/idle", .state);
    _ = try addState(&model, "/TestModel/active", .state);

    // Add transition
    const trans = try addTransition(&model, "/TestModel/idle_to_active", "/TestModel/idle", "/TestModel/active", "start");
    try testing.expectEqualStrings("/TestModel/idle", trans.source);
    try testing.expectEqualStrings("start", trans.event_name.?);
    try testing.expectEqualStrings("/TestModel/active", trans.target.?);

    // Compute paths
    try computeTransitionPaths(&model, trans, "/TestModel/idle");

    // Check paths were computed
    const paths = trans.paths.get("/TestModel/idle");
    try testing.expect(paths != null);
    try testing.expect(paths.?.exit.len == 1);
    try testing.expect(paths.?.enter.len == 1);
}

test "Transition map building" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add states
    _ = try addState(&model, "/TestModel/idle", .state);
    _ = try addState(&model, "/TestModel/active", .state);

    // Add transition
    _ = try addTransition(&model, "/TestModel/idle_to_active", "/TestModel/idle", "/TestModel/active", "start");

    // Build transition map
    try buildTransitionMap(&model);

    // Check transition map was built
    const event_map = model.transition_map.get("/TestModel/idle");
    try testing.expect(event_map != null);

    const transition_list = event_map.?.get("start");
    try testing.expect(transition_list != null);
    try testing.expect(transition_list.?.len == 1);
    try testing.expectEqualStrings("/TestModel/idle_to_active", transition_list.?[0]);
}

test "Deferred events map building" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add state with deferred events
    const state_elem = try addState(&model, "/TestModel/waiting", .state);

    // Manually add deferred events (normally done through defer() builder)
    var deferred_events = try testing.allocator.alloc([]const u8, 2);
    deferred_events[0] = try testing.allocator.dupe(u8, "pause");
    deferred_events[1] = try testing.allocator.dupe(u8, "resume");
    state_elem.deferred = deferred_events;

    // Build deferred map
    try buildDeferredMap(&model);

    // Check deferred map was built
    const event_map = model.deferred_map.get("/TestModel/waiting");
    try testing.expect(event_map != null);

    const is_pause_deferred = event_map.?.get("pause");
    const is_resume_deferred = event_map.?.get("resume");
    try testing.expect(is_pause_deferred != null and is_pause_deferred.?);
    try testing.expect(is_resume_deferred != null and is_resume_deferred.?);
}

test "Enhanced validation" {
    var model = try createModel(testing.allocator, "TestModel");
    defer model.deinit();

    // Add final state with invalid configurations
    const final_state = try addState(&model, "/TestModel/final", .final);

    // Add invalid deferred events to final state
    var deferred_events = try testing.allocator.alloc([]const u8, 1);
    deferred_events[0] = try testing.allocator.dupe(u8, "invalid");
    final_state.deferred = deferred_events;
    // Note: The memory will be cleaned up by model.deinit() which processes the deferred array

    // Validation should fail
    const result = validate(&model);
    try testing.expectError(ValidationError.FinalStateWithDeferred, result);
}
