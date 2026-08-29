const std = @import("std");
const testing = std.testing;

// ============================================================================
// Core Types
// ============================================================================

pub const Version = "v1.3.4";
pub const version = "1.3.4";

/// Context provides cancellation and timing for state machine operations
pub const Context = struct {
    done: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    parent: ?*const Context,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .done = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .parent = null,
        };
    }

    /// Create a child context with a borrowed cancellation parent.
    ///
    /// The parent is not cloned or retained by the child. It must remain
    /// alive until the child is no longer queried, and callers must cancel
    /// the child before releasing either context when work may still run.
    pub fn initWithParent(allocator: std.mem.Allocator, parent: *const Context) Self {
        return Self{
            .done = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .parent = parent,
        };
    }

    pub fn is_done(self: *const Self) bool {
        return self.done.load(.acquire) or (self.parent != null and self.parent.?.is_done());
    }

    pub fn cancel(self: *Self) void {
        self.done.store(true, .release);
    }
};

pub const RuntimeContext = Context;

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

test "package version constants match the release line" {
    try testing.expectEqualStrings("v1.3.4", Version);
    try testing.expectEqualStrings("1.3.4", version);
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

    if (kind == base_kinds) return true;
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

// Canonical kind IDs are explicit so the public values remain stable across
// builds and preserve the shared hierarchy. The low byte is the kind's own
// ID; remaining bytes contain inherited IDs assembled by makeKind.
pub const NullKind: u64 = 0;
pub const ElementKind: u64 = makeKind(.{1});
pub const PartialKind: u64 = makeKind(.{ 2, ElementKind });
pub const VertexKind: u64 = makeKind(.{ 3, ElementKind });
pub const ConstraintKind: u64 = makeKind(.{ 4, ElementKind });
pub const BehaviorKind: u64 = makeKind(.{ 5, ElementKind });
pub const NamespaceKind: u64 = makeKind(.{ 6, ElementKind });
pub const ConcurrentKind: u64 = makeKind(.{ 7, BehaviorKind });
pub const SequentialKind: u64 = makeKind(.{ 8, BehaviorKind });
pub const StateMachineKind: u64 = makeKind(.{ 9, ConcurrentKind, NamespaceKind });
pub const AttributeKind: u64 = makeKind(.{ 10, ElementKind });
pub const OperationKind: u64 = makeKind(.{ 11, BehaviorKind });
pub const StateKind: u64 = makeKind(.{ 12, VertexKind, NamespaceKind });
pub const SubmachineStateKind: u64 = makeKind(.{ 13, StateKind });
pub const ModelKind: u64 = makeKind(.{ 14, StateKind });
pub const TransitionKind: u64 = makeKind(.{ 15, ElementKind });
pub const InternalKind: u64 = makeKind(.{ 16, TransitionKind });
pub const ExternalKind: u64 = makeKind(.{ 17, TransitionKind });
pub const LocalKind: u64 = makeKind(.{ 21, TransitionKind });
pub const SelfKind: u64 = makeKind(.{ 22, TransitionKind });
pub const EventKind: u64 = makeKind(.{ 18, ElementKind });
pub const CompletionEventKind: u64 = makeKind(.{ 19, EventKind });
pub const ChangeEventKind: u64 = makeKind(.{ 24, EventKind });
pub const ErrorEventKind: u64 = makeKind(.{ 20, CompletionEventKind });
pub const TimeEventKind: u64 = makeKind(.{ 23, EventKind });
pub const CallEventKind: u64 = makeKind(.{ 25, EventKind });
pub const PseudostateKind: u64 = makeKind(.{ 26, VertexKind });
pub const InitialKind: u64 = makeKind(.{ 27, PseudostateKind });
pub const EntryPointKind: u64 = makeKind(.{ 28, PseudostateKind });
pub const ExitPointKind: u64 = makeKind(.{ 29, PseudostateKind });
pub const FinalStateKind: u64 = makeKind(.{ 30, StateKind });
pub const ChoiceKind: u64 = makeKind(.{ 31, PseudostateKind });
pub const JunctionKind: u64 = makeKind(.{ 32, PseudostateKind });
pub const DeepHistoryKind: u64 = makeKind(.{ 33, PseudostateKind });
pub const ShallowHistoryKind: u64 = makeKind(.{ 34, PseudostateKind });
pub const ObservationKind: u64 = makeKind(.{ 35, ElementKind });
pub const RegionKind: u64 = makeKind(.{ 36, ElementKind });
pub const CustomKind: u64 = makeKind(.{ 37, ElementKind });
pub const AnyEvent = "*";
pub const anyEvent = AnyEvent;
pub const InitialEventName = "hsm/initial";
pub const FinalEventName = "hsm/final";
pub const ErrorEventName = "hsm/error";

fn stringSlice(value: anytype) []const u8 {
    const ValueType = @TypeOf(value);
    return switch (@typeInfo(ValueType)) {
        .array => |array| if (array.child == u8) value[0..] else @compileError("expected a string-like value"),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) value else @compileError("expected a string-like value"),
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| if (array.child == u8) value[0..] else @compileError("expected a string-like value"),
                else => @compileError("expected a string-like value"),
            },
            else => @compileError("expected a string-like value"),
        },
        else => @compileError("expected a string-like value"),
    };
}

fn matchGlob(value: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, value, pattern) or std.mem.eql(u8, pattern, "*")) return true;
    if (pattern.len == 0) return value.len == 0;

    var value_index: usize = 0;
    var pattern_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_value_index: usize = 0;

    while (true) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
            if (pattern_index == pattern.len) return true;
            continue;
        }

        if (value_index < value.len and pattern_index < pattern.len and
            value[value_index] == pattern[pattern_index])
        {
            value_index += 1;
            pattern_index += 1;
            continue;
        }

        if (value_index == value.len) {
            while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                pattern_index += 1;
            }
            return pattern_index == pattern.len;
        }

        if (star_pattern_index) |star_index| {
            star_value_index += 1;
            if (star_value_index > value.len) return false;
            value_index = star_value_index;
            pattern_index = star_index + 1;
            continue;
        }

        return false;
    }
}

/// Match a value against one pattern or a tuple of wildcard patterns.
pub fn match(value: anytype, patterns: anytype) bool {
    const value_text = stringSlice(value);
    const PatternsType = @TypeOf(patterns);
    const patterns_info = @typeInfo(PatternsType);
    if (patterns_info == .@"struct" and patterns_info.@"struct".is_tuple) {
        inline for (std.meta.fields(PatternsType), 0..) |_, index| {
            if (matchGlob(value_text, stringSlice(patterns[index]))) return true;
        }
        return false;
    }
    return matchGlob(value_text, stringSlice(patterns));
}

pub const Match = match;

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    return path[0..end];
}

fn pathDir(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    const normalized = trimTrailingSeparators(path);
    var index = normalized.len;
    while (index > 0) {
        index -= 1;
        if (normalized[index] != '/') continue;
        if (index == 0) return normalized[0..1];
        var end = index;
        while (end > 1 and normalized[end - 1] == '/') : (end -= 1) {}
        return normalized[0..end];
    }
    return ".";
}

/// Report whether `current` is a strict ancestor of `target`.
pub fn isAncestor(current: []const u8, target_path: []const u8) bool {
    const current_path = trimTrailingSeparators(current);
    const normalized_target = trimTrailingSeparators(target_path);
    if (current_path.len == 0 or normalized_target.len == 0 or
        std.mem.eql(u8, current_path, ".") or std.mem.eql(u8, normalized_target, ".") or
        std.mem.eql(u8, current_path, normalized_target)) return false;
    if (std.mem.eql(u8, current_path, "/")) return true;

    var parent = pathDir(normalized_target);
    while (!std.mem.eql(u8, parent, ".")) {
        if (std.mem.eql(u8, parent, current_path)) return true;
        if (std.mem.eql(u8, parent, "/")) return false;
        parent = pathDir(parent);
    }
    return false;
}

pub const IsAncestor = isAncestor;

/// Find the lowest common ancestor of two qualified state paths.
pub fn lca(a: []const u8, b: []const u8) []const u8 {
    if (std.mem.eql(u8, a, b)) return pathDir(a);
    if (a.len == 0) return b;
    if (b.len == 0) return a;

    var left = a;
    var right = b;
    while (true) {
        const left_parent = pathDir(left);
        const right_parent = pathDir(right);
        if (std.mem.eql(u8, left_parent, right_parent)) return left_parent;
        if (isAncestor(left, right)) return trimTrailingSeparators(left);
        if (isAncestor(right, left)) return trimTrailingSeparators(right);
        left = left_parent;
        right = right_parent;
    }
}

pub const LCA = lca;

/// Event represents a state machine event with optional data.
///
/// Data and metadata values supplied by callers are borrowed `*anyopaque`
/// pointers. Queue and activity envelopes retain those pointers only when the
/// runtime has registered them as an owned generated payload; arbitrary caller
/// payloads remain borrowed and are never copied or destroyed.
pub const Event = struct {
    name: []const u8,
    kind: u64,
    data: ?std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,
    schema: ?*anyopaque = null,
    metadata: ?std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = null,
    owns_name: bool = false,
    owns_id: bool = false,
    owns_source: bool = false,
    owns_target: bool = false,
    owns_data_keys: bool = false,
    owns_metadata_keys: bool = false,

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

    pub fn initial(allocator: std.mem.Allocator) Self {
        var event = Self.init(allocator, InitialEventName);
        event.kind = CompletionEventKind;
        return event;
    }

    pub fn finalEvent(allocator: std.mem.Allocator) Self {
        return Self.completion(allocator, FinalEventName);
    }

    pub fn errorEvent(allocator: std.mem.Allocator) Self {
        var event = Self.withData(allocator, ErrorEventName);
        event.kind = ErrorEventKind;
        return event;
    }

    pub fn timerEvent(allocator: std.mem.Allocator, name: []const u8) Self {
        var event = Self.init(allocator, name);
        event.kind = TimeEventKind;
        return event;
    }

    /// Store a borrowed payload pointer. The event never destroys `value`.
    pub fn putData(self: *Self, key: []const u8, value: *anyopaque) !void {
        if (self.data == null) {
            self.data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }
        const previous = self.data.?.get(key);
        const retained = retainRuntimePayload(value);
        errdefer {
            if (retained) _ = releaseRuntimePayload(value);
        }
        try self.data.?.put(key, value);
        if (previous) |old_value| _ = releaseRuntimePayload(old_value);
    }

    pub fn putOwnedData(self: *Self, key: []const u8, value: *anyopaque, drop_fn: PayloadDropFn) !void {
        try registerRuntimePayload(self.allocator, value, drop_fn);
        errdefer _ = releaseRuntimePayload(value);
        if (self.data == null) {
            self.data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }
        const previous = self.data.?.get(key);
        try self.data.?.put(key, value);
        if (previous) |old_value| _ = releaseRuntimePayload(old_value);
    }

    /// Store borrowed metadata. The event never destroys `value`.
    pub fn putMetadata(self: *Self, key: []const u8, value: *anyopaque) !void {
        if (self.metadata == null) {
            self.metadata = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }
        const previous = self.metadata.?.get(key);
        const retained = retainRuntimePayload(value);
        errdefer {
            if (retained) _ = releaseRuntimePayload(value);
        }
        try self.metadata.?.put(key, value);
        if (previous) |old_value| _ = releaseRuntimePayload(old_value);
    }

    pub fn putOwnedMetadata(self: *Self, key: []const u8, value: *anyopaque, drop_fn: PayloadDropFn) !void {
        try registerRuntimePayload(self.allocator, value, drop_fn);
        errdefer _ = releaseRuntimePayload(value);
        if (self.metadata == null) {
            self.metadata = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }
        const previous = self.metadata.?.get(key);
        try self.metadata.?.put(key, value);
        if (previous) |old_value| _ = releaseRuntimePayload(old_value);
    }

    pub fn ensureMetadata(self: *Self) !void {
        if (self.metadata == null) {
            self.metadata = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
            try self.metadata.?.ensureTotalCapacity(1);
        }
    }

    pub fn getData(self: *const Self, key: []const u8) ?*anyopaque {
        if (self.data) |map| {
            return map.get(key);
        }
        return null;
    }

    pub fn getAttributeChange(self: *const Event) ?*const AttributeChange {
        const change = self.getData("change") orelse return null;
        return @ptrCast(@alignCast(change));
    }

    pub fn getCallData(self: *const Event) ?*const CallData {
        const call = self.getData("call") orelse return null;
        return @ptrCast(@alignCast(call));
    }

    pub fn getMetadata(self: *const Self, key: []const u8) ?*anyopaque {
        if (self.metadata) |map| return map.get(key);
        return null;
    }

    pub fn setIdentity(self: *Self, id: ?[]const u8, source_text: ?[]const u8, target_text: ?[]const u8) !void {
        try self.replaceOwnedIdentity(&self.id, &self.owns_id, id);
        try self.replaceOwnedIdentity(&self.source, &self.owns_source, source_text);
        try self.replaceOwnedIdentity(&self.target, &self.owns_target, target_text);
    }

    fn replaceOwnedIdentity(self: *Self, field: *?[]const u8, owns: *bool, value: ?[]const u8) !void {
        const replacement = if (value) |text| try self.allocator.dupe(u8, text) else null;
        if (owns.*) if (field.*) |old| self.allocator.free(old);
        field.* = replacement;
        owns.* = replacement != null;
    }

    pub fn deinit(self: *Self) void {
        if (self.data) |*map| {
            if (self.owns_data_keys) {
                var iterator = map.iterator();
                while (iterator.next()) |key_entry| {
                    _ = releaseRuntimePayload(key_entry.value_ptr.*);
                    self.allocator.free(@constCast(key_entry.key_ptr.*));
                }
            } else {
                var iterator = map.iterator();
                while (iterator.next()) |key_entry| _ = releaseRuntimePayload(key_entry.value_ptr.*);
            }
            map.deinit();
        }
        if (self.metadata) |*map| {
            if (self.owns_metadata_keys) {
                var iterator = map.iterator();
                while (iterator.next()) |key_entry| {
                    _ = releaseRuntimePayload(key_entry.value_ptr.*);
                    self.allocator.free(@constCast(key_entry.key_ptr.*));
                }
            } else {
                var iterator = map.iterator();
                while (iterator.next()) |key_entry| _ = releaseRuntimePayload(key_entry.value_ptr.*);
            }
            map.deinit();
        }
        if (self.owns_name) self.allocator.free(@constCast(self.name));
        if (self.owns_id) if (self.id) |id| self.allocator.free(@constCast(id));
        if (self.owns_source) if (self.source) |source_text| self.allocator.free(@constCast(source_text));
        if (self.owns_target) if (self.target) |target_text| self.allocator.free(@constCast(target_text));
    }
};

/// Payload carried by the generated hsm/observation event.
pub const ObservationData = struct {
    event: Event,
    occurrence: []const u8,
    source: []const u8,
};

pub const AttributeChange = struct {
    Name: []const u8,
    Old: ?*anyopaque,
    New: *anyopaque,

    pub fn Value(self: *const @This()) *anyopaque {
        return self.New;
    }
};

pub const CallData = struct {
    Name: []const u8,
    Args: ?*anyopaque,
    Values: []const *anyopaque = &.{},
    owns_values: bool = false,

    pub fn argsAs(self: *const @This(), comptime T: type) ?*const T {
        const args = self.Args orelse return null;
        return @ptrCast(@alignCast(args));
    }

    pub fn ArgsAs(self: *const @This(), comptime T: type) ?*const T {
        return self.argsAs(T);
    }

    pub fn valueAs(self: *const @This(), index: usize, comptime T: type) ?*const T {
        if (index >= self.Values.len) return null;
        return @ptrCast(@alignCast(self.Values[index]));
    }

    pub fn ValueAs(self: *const @This(), index: usize, comptime T: type) ?*const T {
        return self.valueAs(index, T);
    }
};

fn cloneEventForQueue(allocator: std.mem.Allocator, event: Event) !Event {
    var cloned = Event.init(allocator, try allocator.dupe(u8, event.name));
    cloned.owns_name = true;
    cloned.kind = event.kind;
    cloned.schema = event.schema;
    errdefer cloned.deinit();
    if (event.id) |id| {
        cloned.id = try allocator.dupe(u8, id);
        cloned.owns_id = true;
    }
    if (event.source) |source_text| {
        cloned.source = try allocator.dupe(u8, source_text);
        cloned.owns_source = true;
    }
    if (event.target) |target_text| {
        cloned.target = try allocator.dupe(u8, target_text);
        cloned.owns_target = true;
    }
    if (event.data) |event_data| {
        cloned.data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        cloned.owns_data_keys = true;
        var iterator = event_data.iterator();
        while (iterator.next()) |event_entry| {
            const key = try allocator.dupe(u8, event_entry.key_ptr.*);
            errdefer allocator.free(key);
            try cloned.data.?.put(key, event_entry.value_ptr.*);
            _ = retainRuntimePayload(event_entry.value_ptr.*);
        }
    }
    if (event.metadata) |event_metadata| {
        cloned.metadata = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        cloned.owns_metadata_keys = true;
        var iterator = event_metadata.iterator();
        while (iterator.next()) |event_entry| {
            const key = try allocator.dupe(u8, event_entry.key_ptr.*);
            errdefer allocator.free(key);
            try cloned.metadata.?.put(key, event_entry.value_ptr.*);
            _ = retainRuntimePayload(event_entry.value_ptr.*);
        }
    }
    return cloned;
}

const OwnedActivityEvent = struct {
    event: Event,
};

fn cloneActivityEvent(allocator: std.mem.Allocator, source_event: Event) !OwnedActivityEvent {
    const name = try allocator.dupe(u8, source_event.name);

    var event = Event.init(allocator, name);
    event.owns_name = true;
    event.kind = source_event.kind;
    event.schema = source_event.schema;
    errdefer {
        event.deinit();
    }

    if (source_event.id) |id| {
        event.id = try allocator.dupe(u8, id);
        event.owns_id = true;
    }
    if (source_event.source) |source_text| {
        event.source = try allocator.dupe(u8, source_text);
        event.owns_source = true;
    }
    if (source_event.target) |target_text| {
        event.target = try allocator.dupe(u8, target_text);
        event.owns_target = true;
    }

    if (source_event.data) |source_data| {
        event.data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        event.owns_data_keys = true;
        var iterator = source_data.iterator();
        while (iterator.next()) |source_entry| {
            const key = try allocator.dupe(u8, source_entry.key_ptr.*);
            event.data.?.put(key, source_entry.value_ptr.*) catch |err| {
                allocator.free(key);
                return err;
            };
            _ = retainRuntimePayload(source_entry.value_ptr.*);
        }
    }
    if (source_event.metadata) |source_metadata| {
        event.metadata = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        event.owns_metadata_keys = true;
        var iterator = source_metadata.iterator();
        while (iterator.next()) |source_entry| {
            const key = try allocator.dupe(u8, source_entry.key_ptr.*);
            event.metadata.?.put(key, source_entry.value_ptr.*) catch |err| {
                allocator.free(key);
                return err;
            };
            _ = retainRuntimePayload(source_entry.value_ptr.*);
        }
    }

    return .{ .event = event };
}

fn deinitActivityEvent(allocator: std.mem.Allocator, owned: *OwnedActivityEvent) void {
    _ = allocator;
    owned.event.deinit();
}

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

/// Activity function signature for a concurrent, low-level callback.
///
/// `ctx`, `inst`, and `event` are borrowed for the callback duration only.
/// The callback must synchronize any instance mutation shared with the
/// serialized machine path, observe `ctx.is_done()`, and return after
/// cancellation. The runtime cancels admitted activities before state-exit
/// teardown and waits for them, except when the callback synchronously stops
/// its own machine; in that case deferred self-cleanup owns the callback's
/// final return path.
pub fn ActivityFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) void;
}

/// Timer function signature - returns nanoseconds for delays
pub fn TimerFn(comptime T: type) type {
    return fn (ctx: *Context, inst: *T, event: Event) u64;
}

/// Runtime queue callback contract:
///
/// * Push receives an event clone. A successful Push transfers ownership of
///   that clone to the queue.
/// * Push must be atomic with respect to failure: if it returns an error, it
///   must not retain or later return the event.
/// * Pop transfers ownership of a returned event to the caller. A null Pop
///   means the queue is empty.
/// * A Pop error is atomic with no transfer or queue mutation; the runtime may
///   retry it once while dispatching or draining.
/// * A Len error has no queue mutation or ownership effect; callers treat it
///   as a failed snapshot rather than as a queue-length value.
/// * Queue callbacks and their Context are borrowed by the machine. They must
///   outlive the machine and provide their own synchronization when shared by
///   machines or timer/worker threads.
///
/// The runtime drains successful queued events during stop/deinit, but cannot
/// recover an event retained by a queue that violates the failed-Push rule.
/// After the bounded Pop retry is exhausted during stop, stop returns the
/// second Pop error. The queue remains the owner of any events it has not
/// returned; its owner must make them drainable before retrying stop/deinit.
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
    /// Borrowed queue; its callback context must outlive the machine.
    Queue: ?*RuntimeQueue = null,
    /// Maximum time in nanoseconds that stop waits for an admitted activity
    /// callback. deinit uses the same bound while attempting its stop. Zero
    /// selects the native five-second default.
    ActivityTimeoutNs: u64 = 0,
};

pub fn Config(args: anytype) RuntimeConfig {
    return RuntimeConfig{
        .ID = if (@hasField(@TypeOf(args), "ID")) args.ID else null,
        .Name = if (@hasField(@TypeOf(args), "Name")) args.Name else null,
        .Data = if (@hasField(@TypeOf(args), "Data")) args.Data else null,
        .Clock = if (@hasField(@TypeOf(args), "Clock")) args.Clock else null,
        .Queue = if (@hasField(@TypeOf(args), "Queue")) args.Queue else null,
        .ActivityTimeoutNs = if (@hasField(@TypeOf(args), "ActivityTimeoutNs")) args.ActivityTimeoutNs else 0,
    };
}

var runtime_id_sequence = std.atomic.Value(u64).init(0);

const ValueCloneFn = *const fn (allocator: std.mem.Allocator, source: *const anyopaque) anyerror!*anyopaque;
pub const PayloadDropFn = *const fn (allocator: std.mem.Allocator, value: *anyopaque) void;
const ValueDropFn = PayloadDropFn;

const RuntimePayloadReference = struct {
    allocator: std.mem.Allocator,
    value: *anyopaque,
    drop_fn: ValueDropFn,
    references: usize = 1,
};

var runtime_payload_registry_mutex: std.Thread.Mutex = .{};
var runtime_payload_registry = std.AutoHashMap(usize, *RuntimePayloadReference).init(std.heap.page_allocator);

fn registerRuntimePayload(allocator: std.mem.Allocator, value: *anyopaque, drop_fn: ValueDropFn) !void {
    // The null attribute sentinel is intentionally not heap-owned.
    if (@intFromPtr(value) == 1) return;

    const reference = try allocator.create(RuntimePayloadReference);
    reference.* = .{
        .allocator = allocator,
        .value = value,
        .drop_fn = drop_fn,
    };

    const key = @intFromPtr(value);
    runtime_payload_registry_mutex.lock();
    if (runtime_payload_registry.contains(key)) {
        runtime_payload_registry_mutex.unlock();
        allocator.destroy(reference);
        return error.RuntimePayloadAlreadyRegistered;
    }
    const put_result = runtime_payload_registry.put(key, reference);
    runtime_payload_registry_mutex.unlock();
    put_result catch |err| {
        allocator.destroy(reference);
        return err;
    };
}

fn retainRuntimePayload(value: *anyopaque) bool {
    const key = @intFromPtr(value);
    if (key == 1) return false;

    runtime_payload_registry_mutex.lock();
    defer runtime_payload_registry_mutex.unlock();
    if (runtime_payload_registry.get(key)) |reference| {
        reference.references +|= 1;
        return true;
    }
    return false;
}

fn releaseRuntimePayload(value: *anyopaque) bool {
    const key = @intFromPtr(value);
    if (key == 1) return false;

    var reference_to_destroy: ?*RuntimePayloadReference = null;
    var found = false;
    {
        runtime_payload_registry_mutex.lock();
        defer runtime_payload_registry_mutex.unlock();
        if (runtime_payload_registry.get(key)) |reference| {
            found = true;
            if (reference.references == 0) @panic("runtime payload reference count underflow");
            reference.references -= 1;
            if (reference.references == 0) {
                _ = runtime_payload_registry.remove(key);
                reference_to_destroy = reference;
            }
        }
    }

    if (reference_to_destroy) |reference| {
        reference.drop_fn(reference.allocator, reference.value);
        reference.allocator.destroy(reference);
    }
    return found;
}

fn cloneTypedValue(comptime T: type) ValueCloneFn {
    return struct {
        fn clone(allocator: std.mem.Allocator, source_value: *const anyopaque) anyerror!*anyopaque {
            const typed_source: *const T = @ptrCast(@alignCast(source_value));
            const copy = try allocator.create(T);
            errdefer allocator.destroy(copy);
            if (comptime T == []const u8) {
                copy.* = try allocator.dupe(u8, typed_source.*);
            } else {
                copy.* = typed_source.*;
            }
            return @ptrCast(copy);
        }
    }.clone;
}

fn dropTypedValue(comptime T: type) ValueDropFn {
    return struct {
        fn drop(allocator: std.mem.Allocator, value: *anyopaque) void {
            const typed_value: *T = @ptrCast(@alignCast(value));
            if (comptime T == []const u8) allocator.free(typed_value.*);
            allocator.destroy(typed_value);
        }
    }.drop;
}

fn dropCallData(allocator: std.mem.Allocator, value: *anyopaque) void {
    const call_data: *CallData = @ptrCast(@alignCast(value));
    if (call_data.owns_values) allocator.free(@constCast(call_data.Values));
    allocator.destroy(call_data);
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
        if (!releaseRuntimePayload(self.value)) self.drop_fn(allocator, self.value);
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
        if (!releaseRuntimePayload(self.value)) self.drop_fn(allocator, self.value);
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

pub const TransitionSnapshot = struct {
    Name: []const u8,
    Kind: u64,
    Source: []const u8,
    Target: ?[]const u8,
    Events: [][]const u8,
    Guard: bool,

    pub fn deinit(self: *TransitionSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.Name);
        allocator.free(self.Source);
        if (self.Target) |target_name| allocator.free(target_name);
        for (self.Events) |event_name| allocator.free(event_name);
        allocator.free(self.Events);
    }
};

pub const Snapshot = struct {
    ID: ?[]const u8,
    QualifiedName: []const u8,
    State: []const u8,
    QueueLen: usize,
    Attributes: std.StringHashMap(AttributeSnapshot),
    Events: []EventDetail,
    Transitions: []TransitionSnapshot,
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
        for (self.Transitions) |*transition_snapshot| {
            transition_snapshot.deinit(self.allocator);
        }
        self.allocator.free(self.Transitions);
        if (self.Members) |members| {
            for (members) |*member| {
                member.deinit();
            }
            self.allocator.free(members);
        }
    }
};

fn dropNullValue(allocator: std.mem.Allocator, value: *anyopaque) void {
    _ = allocator;
    _ = value;
}

fn makeUnregisteredAttributeValue(allocator: std.mem.Allocator, value: anytype) !RuntimeAttributeValue {
    const T = @TypeOf(value);
    if (comptime T == @TypeOf(null)) {
        return RuntimeAttributeValue{ .value = @ptrFromInt(1), .type_name = @typeName(T), .drop_fn = dropNullValue };
    }

    const drop_fn = dropTypedValue(T);
    const copy = try allocator.create(T);
    var initialized = false;
    errdefer {
        if (initialized) drop_fn(allocator, @ptrCast(copy)) else allocator.destroy(copy);
    }
    if (comptime T == []const u8) {
        copy.* = try allocator.dupe(u8, value);
    } else {
        copy.* = value;
    }
    initialized = true;
    return RuntimeAttributeValue{
        .value = @ptrCast(copy),
        .type_name = @typeName(T),
        .drop_fn = drop_fn,
    };
}

fn makeRuntimeAttributeValue(allocator: std.mem.Allocator, value: anytype) !RuntimeAttributeValue {
    var runtime_value = try makeUnregisteredAttributeValue(allocator, value);
    errdefer runtime_value.drop_fn(allocator, runtime_value.value);
    try registerRuntimePayload(allocator, runtime_value.value, runtime_value.drop_fn);
    return runtime_value;
}

fn makeRuntimeCallData(allocator: std.mem.Allocator, name: []const u8, values: []const *anyopaque) !RuntimeAttributeValue {
    const call_data = try allocator.create(CallData);
    const owned_values = allocator.dupe(*anyopaque, values) catch |err| {
        allocator.destroy(call_data);
        return err;
    };
    call_data.* = .{
        .Name = name,
        .Args = if (owned_values.len == 0) null else owned_values[0],
        .Values = owned_values,
        .owns_values = true,
    };
    errdefer dropCallData(allocator, @ptrCast(call_data));
    try registerRuntimePayload(allocator, @ptrCast(call_data), dropCallData);
    return RuntimeAttributeValue{
        .value = @ptrCast(call_data),
        .type_name = @typeName(CallData),
        .drop_fn = dropCallData,
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
    if (std.mem.eql(u8, value.type_name, @typeName([]const u8))) {
        const typed: *const []const u8 = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(@TypeOf(null)))) {
        return makeRuntimeAttributeValue(allocator, null);
    }
    if (std.mem.eql(u8, value.type_name, @typeName(std.json.Value))) {
        const typed: *const std.json.Value = @ptrCast(@alignCast(value.value));
        return makeRuntimeAttributeValue(allocator, typed.*);
    }
    return error.UnsupportedSnapshotAttributeType;
}

fn cloneRuntimeAttributeValue(allocator: std.mem.Allocator, attr: *const AttributeElement) !?RuntimeAttributeValue {
    if (attr.default_value == null or attr.clone_fn == null or attr.drop_fn == null or attr.type_name == null) {
        return null;
    }

    const value = try attr.clone_fn.?(allocator, @ptrCast(attr.default_value.?));
    errdefer attr.drop_fn.?(allocator, value);
    try registerRuntimePayload(allocator, value, attr.drop_fn.?);
    return RuntimeAttributeValue{
        .value = value,
        .type_name = attr.type_name.?,
        .drop_fn = attr.drop_fn.?,
    };
}

fn valuesEqual(comptime T: type, left: *const RuntimeAttributeValue, right: T) bool {
    if (!std.mem.eql(u8, left.type_name, @typeName(T))) return false;
    if (comptime T == @TypeOf(null)) return true;
    const typed_left: *const T = @ptrCast(@alignCast(left.value));
    return std.mem.eql(u8, std.mem.asBytes(typed_left), std.mem.asBytes(&right));
}

fn stateMatchesOrIsDescendant(current_state: []const u8, target_state: []const u8) bool {
    if (std.mem.eql(u8, current_state, target_state)) return true;
    if (!std.mem.startsWith(u8, current_state, target_state)) return false;
    return current_state.len > target_state.len and current_state[target_state.len] == '/';
}

fn canonicalStateName(model: *const Model, path: []const u8) []const u8 {
    if (model.members.get(path)) |element| return element.qualified_name;
    return path;
}

fn modelHasHistory(model: *const Model) bool {
    var iterator = model.members.iterator();
    while (iterator.next()) |member_entry| {
        if (member_entry.value_ptr.*.kind == .history) return true;
    }
    return false;
}

fn modelHasTimers(model: *const Model) bool {
    var iterator = model.members.iterator();
    while (iterator.next()) |member_entry| {
        if (member_entry.value_ptr.*.kind != .transition) continue;
        const timer_transition = @as(*const TransitionElement, @ptrCast(@alignCast(member_entry.value_ptr.*)));
        if (timer_transition.timer_fn != null) return true;
    }
    return false;
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

/// Structural element tags used by the native flat-storage implementation.
pub const ElementType = enum(u64) {
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
    submachine = 11,
    entry_point = 12,
    exit_point = 13,
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
    kind: ElementType,
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

/// Transient connection point at a submachine boundary.
pub const ConnectionPointElement = struct {
    element: Element,
    transitions: [][]const u8,

    const Self = @This();
};

/// Transition element in flat storage
pub const TransitionElement = struct {
    element: Element,
    kind: u64,
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
        var destroyed_elements = std.AutoHashMap(*Element, void).init(self.allocator);
        defer destroyed_elements.deinit();
        var iterator = self.members.iterator();
        while (iterator.next()) |kv| {
            const element = kv.value_ptr.*;
            if (!std.mem.eql(u8, kv.key_ptr.*, element.qualified_name)) {
                self.allocator.free(kv.key_ptr.*);
            }
            if (destroyed_elements.contains(element)) continue;
            destroyed_elements.put(element, {}) catch continue;
            switch (element.kind) {
                .state, .submachine, .model, .final, .choice => {
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
                .entry_point, .exit_point => {
                    const point: *ConnectionPointElement = @ptrCast(@alignCast(element));
                    self.allocator.free(point.element.qualified_name);
                    self.allocator.free(point.element.id);
                    for (point.transitions) |transition_name| {
                        self.allocator.free(transition_name);
                    }
                    if (point.transitions.len > 0) self.allocator.free(point.transitions);
                    self.allocator.destroy(point);
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
        deinitTransitionMap(self.allocator, &self.transition_map);

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
    const expected_kind: ?ElementType = comptime if (T == TransitionElement)
        .transition
    else if (T == BehaviorElement)
        .behavior
    else if (T == OperationElement)
        .operation
    else if (T == HistoryElement)
        .history
    else if (T == StateElement)
        .state
    else
        null;
    if (expected_kind) |kind| {
        if (element.kind != kind) return null;
    } else if (T == ConnectionPointElement) {
        if (element.kind != .entry_point and element.kind != .exit_point) return null;
    } else {
        @compileError("get() requires a supported typed model element");
    }
    return @ptrCast(@alignCast(element));
}

/// Get state element by qualified name
pub fn getState(model: *const Model, qualified_name: []const u8) ?*StateElement {
    const element = model.members.get(qualified_name) orelse return null;
    return switch (element.kind) {
        .model, .state, .submachine, .final, .choice => @ptrCast(@alignCast(element)),
        else => null,
    };
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

/// Get a transient entry or exit connection point by qualified name.
pub fn getConnectionPoint(model: *const Model, qualified_name: []const u8) ?*ConnectionPointElement {
    return get(ConnectionPointElement, model, qualified_name);
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

        const is_effect_builder = true;

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
        const is_effect_builder = true;
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

/// Create a transient entry-point declaration or transition selector.
///
/// Zig has no default `anytype` parameters, so selectors use an empty partial
/// tuple: `EntryPoint("resume", .{})`.
pub fn entryPoint(comptime name: []const u8, comptime elements: anytype) type {
    comptime validateModelMemberLiteral("entry point", name);
    return struct {
        point_name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        point_type: ElementType = .entry_point,
    };
}

/// Create a transient exit-point declaration or transition selector.
pub fn exitPoint(comptime name: []const u8, comptime elements: anytype) type {
    comptime validateModelMemberLiteral("exit point", name);
    return struct {
        point_name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        point_type: ElementType = .exit_point,
    };
}

pub fn exitPointEventName(allocator: std.mem.Allocator, boundary_path: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "hsm_exit:{s}/{s}", .{ boundary_path, name });
}

const entryPointTargetMarker = "__hsm_entry_point__:";

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

/// Create an initial transition builder.
///
/// The legacy initial(target(...)) form remains valid. The tuple form also
/// accepts ordered effects: initial(.{ target(...), effect(...) }).
fn isEffectBuilder(comptime value: anytype) bool {
    const value_type = @TypeOf(value);
    const builder_type = if (value_type == type) value else value_type;
    return switch (@typeInfo(builder_type)) {
        .@"struct" => @hasDecl(builder_type, "is_effect_builder"),
        else => false,
    };
}

pub fn initial(comptime declaration: anytype) type {
    const declaration_type = @TypeOf(declaration);
    if (declaration_type == TargetBuilder) {
        return struct {
            target_path: []const u8 = declaration.target_path,
            elements: @TypeOf(.{declaration}) = .{declaration},
        };
    }

    const declaration_info = @typeInfo(declaration_type);
    if (declaration_info != .@"struct" or !declaration_info.@"struct".is_tuple) {
        @compileError("initial() expects target(...) or a tuple containing target(...) and effect(...)");
    }

    comptime var target_path: ?[]const u8 = null;
    inline for (std.meta.fields(declaration_type), 0..) |_, index| {
        const element = declaration[index];
        const element_type = @TypeOf(element);
        if (element_type == TargetBuilder) {
            if (target_path != null) @compileError("initial() accepts only one target(...)");
            target_path = element.target_path;
        } else if (!isEffectBuilder(element)) {
            @compileError("initial() only accepts target(...) and effect(...)");
        }
    }
    if (target_path == null) @compileError("initial() requires target(...)");

    return struct {
        target_path: []const u8 = target_path.?,
        elements: @TypeOf(declaration) = declaration,
    };
}

/// Create a source builder for explicit transition sources
pub fn source(comptime source_path: []const u8) type {
    return struct {
        source_path: []const u8 = source_path,
    };
}

/// Override the inferred transition subtype.
pub fn transitionType(comptime kind: u64) type {
    if (!isKind(kind, TransitionKind)) @compileError("transition type must derive from TransitionKind");
    return struct {
        transition_kind: u64 = kind,
    };
}

pub const TransitionType = transitionType;

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

        fn getPointName(self: @This(), point_kind: ElementType) ?[]const u8 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == type) {
                    if (@hasField(arg, "point_type")) {
                        const point = arg{};
                        if (point.point_type == point_kind) return point.point_name;
                    }
                } else if (@typeInfo(ArgType) == .@"struct" and @hasField(ArgType, "point_type") and arg.point_type == point_kind) {
                    return arg.point_name;
                }
            }
            return null;
        }

        pub fn getEntryPoint(self: @This()) ?[]const u8 {
            return self.getPointName(.entry_point);
        }

        pub fn getExitPoint(self: @This()) ?[]const u8 {
            return self.getPointName(.exit_point);
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
                if (ArgType == type) {
                    const actual_type_info = @typeInfo(arg);
                    if (actual_type_info == .@"struct" and @hasField(arg, "source_path")) {
                        const source_builder = arg{};
                        return source_builder.source_path;
                    }
                } else if (type_info == .@"struct" and @hasField(ArgType, "source_path")) {
                    return arg.source_path;
                }
            }
            return null;
        }

        pub fn getKind(self: @This()) ?u64 {
            inline for (std.meta.fields(@TypeOf(self.args))) |field| {
                const arg = @field(self.args, field.name);
                const ArgType = @TypeOf(arg);
                if (ArgType == type) {
                    if (@hasField(arg, "transition_kind")) return (arg{}).transition_kind;
                } else if (@typeInfo(ArgType) == .@"struct" and @hasField(ArgType, "transition_kind")) {
                    return arg.transition_kind;
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
        state_type: ElementType = .state,
    };
}

/// Compose a reusable compile-time model under a state boundary.
///
/// The child model's elements are rebased under `name` while the model is
/// flattened into the parent's qualified-name index. This keeps ordinary
/// dispatch and transition execution on the same average O(1) lookup path as native
/// hierarchical states.
pub fn submachineState(comptime name: []const u8, comptime machine: type) type {
    return submachineStateWithPartials(name, machine, .{});
}

/// Compose a reusable child model with boundary-local behavior partials.
///
/// Zig does not support default `anytype` parameters, so the compatibility
/// two-argument form remains `submachineState(name, machine)` and callers that
/// need boundary partials use `submachineStateWithPartials(name, machine, .{
/// ... })`.
pub fn submachineStateWithPartials(comptime name: []const u8, comptime machine: type, comptime partials: anytype) type {
    if (!@hasDecl(machine, "model_elements")) {
        @compileError("submachineState expects a model returned by define");
    }
    const elements = concatTuples(machine.model_elements, partials);
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        state_type: ElementType = .submachine,
    };
}

pub const SubmachineState = submachineState;
pub const submachine = submachineState;
pub const SubmachineStateWithPartials = submachineStateWithPartials;
pub const submachineWithPartials = submachineStateWithPartials;

/// Create a final state builder
pub fn final(comptime name: []const u8) type {
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(.{}) = .{},
        state_type: ElementType = .final,
    };
}

/// Create a choice state builder
pub fn choice(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        state_type: ElementType = .choice,
    };
}

fn makeHistoryBuilder(comptime name: []const u8, comptime declaration: anytype, comptime kind: HistoryKind) type {
    comptime validateModelMemberLiteral("history", name);
    const declaration_type = @TypeOf(declaration);
    const elements = if (declaration_type == TargetBuilder or
        (declaration_type == type and @hasField(declaration, "args")))
        .{declaration}
    else if (@typeInfo(declaration_type) == .@"struct" and @typeInfo(declaration_type).@"struct".is_tuple)
        declaration
    else
        @compileError("history() expects target(...) or transition defaults");

    comptime var default_target: ?[]const u8 = null;
    inline for (std.meta.fields(@TypeOf(elements)), 0..) |_, index| {
        const partial = elements[index];
        const partial_type = @TypeOf(partial);
        const builder_type = if (partial_type == type) partial else partial_type;
        if (builder_type == TargetBuilder) {
            if (default_target != null) @compileError("history() accepts only one target default");
            default_target = if (partial_type == type) (partial{}).target_path else partial.target_path;
        } else if (@hasField(builder_type, "args")) {
            const transition_builder = if (partial_type == type) partial{} else partial;
            inline for (std.meta.fields(@TypeOf(transition_builder.args))) |field| {
                const argument = @field(transition_builder.args, field.name);
                const argument_value = if (@TypeOf(argument) == type) argument{} else argument;
                const argument_type = @TypeOf(argument_value);
                const is_guard = @hasField(argument_type, "function");
                const is_effect = @hasDecl(argument_type, "is_effect_builder");
                const is_target = argument_type == TargetBuilder;
                if (!is_guard and !is_effect and !is_target) {
                    @compileError("history default transitions accept only guard(...), effect(...), and target(...)");
                }
            }
            const target_path = transition_builder.getTarget() orelse @compileError("history default transition requires target(...)");
            if (default_target == null) default_target = target_path;
        } else {
            @compileError("history() defaults must be target(...) or transition(...)");
        }
    }
    if (default_target == null) @compileError("history() requires a default target");

    return struct {
        name: []const u8 = name,
        elements: @TypeOf(elements) = elements,
        default_target: []const u8 = default_target.?,
        history_kind: HistoryKind = kind,
        state_type: ElementType = .history,
    };
}

/// Create a shallow history state builder with one or more default transitions.
pub fn history(comptime name: []const u8, comptime declaration: anytype) type {
    return makeHistoryBuilder(name, declaration, .shallow);
}

/// Create a deep history state builder with one or more default transitions.
pub fn deepHistory(comptime name: []const u8, comptime declaration: anytype) type {
    return makeHistoryBuilder(name, declaration, .deep);
}

/// Attach a model validator to a compile-time model definition.
pub fn validator(comptime callback: anytype) type {
    return struct {
        validator_fn: @TypeOf(callback) = callback,
        model_hook: void = {},
    };
}

/// Attach a model finalizer to a compile-time model definition.
pub fn finalizer(comptime callback: anytype) type {
    return struct {
        finalizer_fn: @TypeOf(callback) = callback,
        model_hook: void = {},
    };
}

/// Attach an observation callback to all matching behaviors and transitions.
///
/// Pass targets as a tuple of strings. An empty tuple observes every
/// observable behavior and transition event.
pub fn observe(comptime callback: anytype, comptime targets: anytype) type {
    return struct {
        observer_fn: @TypeOf(callback) = callback,
        observer_targets: @TypeOf(targets) = targets,
        model_hook: void = {},
    };
}

fn tupleTailType(comptime value: anytype, comptime offset: usize) type {
    const fields = std.meta.fields(@TypeOf(value));
    if (offset > fields.len) @compileError("tuple tail starts past the tuple length");
    var types: [fields.len - offset]type = undefined;
    inline for (fields[offset..], 0..) |field, index| types[index] = field.type;
    return std.meta.Tuple(&types);
}

fn tupleTail(comptime value: anytype, comptime offset: usize) tupleTailType(value, offset) {
    const fields = std.meta.fields(@TypeOf(value));
    const Result = tupleTailType(value, offset);
    var result: Result = undefined;
    inline for (fields[offset..], 0..) |_, index| result[index] = value[offset + index];
    return result;
}

fn declaredElementName(comptime element: anytype) ?[]const u8 {
    const element_type = @TypeOf(element);
    const declaration_type = if (element_type == type) element else element_type;
    if (@typeInfo(declaration_type) != .@"struct") return null;

    const instance = if (element_type == type) declaration_type{} else element;
    if (@hasField(declaration_type, "name")) return instance.name;
    if (@hasField(declaration_type, "attr_name")) return instance.attr_name;
    if (@hasField(declaration_type, "op_name")) return instance.op_name;
    if (@hasField(declaration_type, "point_name")) return instance.point_name;
    return null;
}

const RedefinitionCategory = enum {
    vertex,
    attribute,
    operation,
    connection_point,
};

fn declaredElementCategory(comptime element: anytype) ?RedefinitionCategory {
    const element_type = @TypeOf(element);
    const declaration_type = if (element_type == type) element else element_type;
    if (@typeInfo(declaration_type) != .@"struct") return null;

    if (@hasField(declaration_type, "state_type")) return .vertex;
    if (@hasField(declaration_type, "attr_name")) return .attribute;
    if (@hasField(declaration_type, "op_name")) return .operation;
    if (@hasField(declaration_type, "point_name")) return .connection_point;
    return null;
}

fn declarationType(comptime element: anytype) type {
    const element_type = @TypeOf(element);
    return if (element_type == type) element else element_type;
}

fn isInitialDeclaration(comptime element: anytype) bool {
    const element_type = @TypeOf(element);
    const declaration_type = if (element_type == type) element else element_type;
    if (@typeInfo(declaration_type) != .@"struct") return false;
    return @hasField(declaration_type, "target_path") and !@hasField(declaration_type, "args");
}

fn transitionPath(comptime element: anytype, comptime want_source: bool) ?[]const u8 {
    const element_type = @TypeOf(element);
    const declaration_type = if (element_type == type) element else element_type;
    if (@typeInfo(declaration_type) != .@"struct" or !@hasField(declaration_type, "args")) return null;

    const transition_instance = if (element_type == type) declaration_type{} else element;
    return if (want_source) transition_instance.getSource() else transition_instance.getTarget();
}

fn pathInVertexSubtree(path: []const u8, vertex_name: []const u8) bool {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) normalized = normalized[2..];
    while (normalized.len > 0 and normalized[0] == '/') normalized = normalized[1..];

    return std.mem.eql(u8, normalized, vertex_name) or
        (std.mem.startsWith(u8, normalized, vertex_name) and
            normalized.len > vertex_name.len and normalized[vertex_name.len] == '/');
}

fn vertexReplacementIndex(comptime element: anytype, comptime replacements: anytype) ?usize {
    if (declaredElementCategory(element) != .vertex) return null;
    const element_name = declaredElementName(element) orelse return null;

    inline for (std.meta.fields(@TypeOf(replacements)), 0..) |_, index| {
        const replacement = replacements[index];
        if (declaredElementCategory(replacement) != .vertex) continue;
        if (declaredElementName(replacement)) |replacement_name| {
            if (std.mem.eql(u8, element_name, replacement_name)) return index;
        }
    }
    return null;
}

fn vertexReplacementCount(comptime element: anytype, comptime replacements: anytype) usize {
    if (declaredElementCategory(element) != .vertex) return 0;
    const element_name = declaredElementName(element) orelse return 0;
    var count: usize = 0;
    inline for (std.meta.fields(@TypeOf(replacements)), 0..) |_, index| {
        const replacement = replacements[index];
        if (declaredElementCategory(replacement) != .vertex) continue;
        if (declaredElementName(replacement)) |replacement_name| {
            if (std.mem.eql(u8, element_name, replacement_name)) count += 1;
        }
    }
    return count;
}

fn canMergeVertexChildren(comptime inherited: anytype, comptime replacement: anytype) bool {
    const inherited_type = declarationType(inherited);
    const replacement_type = declarationType(replacement);
    if (@typeInfo(inherited_type) != .@"struct" or @typeInfo(replacement_type) != .@"struct") return false;
    if (!@hasField(inherited_type, "elements") or !@hasField(replacement_type, "elements")) return false;

    const inherited_instance = if (@TypeOf(inherited) == type) inherited_type{} else inherited;
    const replacement_instance = if (@TypeOf(replacement) == type) replacement_type{} else replacement;
    return inherited_instance.state_type == .state and replacement_instance.state_type == .state;
}

fn nestedOverlayHasChanges(comptime base: anytype, comptime additions: anytype) bool {
    const base_fields = std.meta.fields(@TypeOf(base));
    const addition_fields = std.meta.fields(@TypeOf(additions));
    if (addition_fields.len == 0) return false;
    if (base_fields.len != addition_fields.len) return true;

    inline for (addition_fields, 0..) |_, addition_index| {
        const addition = additions[addition_index];
        const addition_category = declaredElementCategory(addition);
        if (addition_category == .vertex) {
            const addition_name = declaredElementName(addition) orelse return true;
            var found = false;
            inline for (base_fields, 0..) |_, base_index| {
                const inherited = base[base_index];
                if (declaredElementCategory(inherited) != .vertex) continue;
                const inherited_name = declaredElementName(inherited) orelse continue;
                if (!std.mem.eql(u8, inherited_name, addition_name)) continue;
                if (found) return true;
                found = true;

                const inherited_type = declarationType(inherited);
                const addition_type = declarationType(addition);
                const inherited_instance = if (@TypeOf(inherited) == type) inherited_type{} else inherited;
                const addition_instance = if (@TypeOf(addition) == type) addition_type{} else addition;
                if (inherited_instance.state_type != addition_instance.state_type) return true;
                if (canMergeVertexChildren(inherited, addition) and
                    nestedOverlayHasChanges(inherited_instance.elements, addition_instance.elements))
                {
                    return true;
                }
            }
            if (!found) return true;
        } else if (addition_category == null and isInitialDeclaration(addition)) {
            const addition_type = declarationType(addition);
            const addition_instance = if (@TypeOf(addition) == type) addition_type{} else addition;
            var found = false;
            inline for (base_fields, 0..) |_, base_index| {
                const inherited = base[base_index];
                if (!isInitialDeclaration(inherited)) continue;
                if (found) return true;
                found = true;
                const inherited_type = declarationType(inherited);
                const inherited_instance = if (@TypeOf(inherited) == type) inherited_type{} else inherited;
                if (!std.mem.eql(u8, inherited_instance.target_path, addition_instance.target_path)) return true;
                if (std.meta.fields(@TypeOf(inherited_instance.elements)).len !=
                    std.meta.fields(@TypeOf(addition_instance.elements)).len)
                {
                    return true;
                }
            }
            if (!found) return true;
        } else {
            // A transition or behavior declaration is an intentional nested
            // change. The recursive overlay keeps unrelated sibling states.
            return true;
        }
    }
    return false;
}

fn mergedVertexType(comptime inherited: anytype, comptime replacement: anytype) type {
    const inherited_type = declarationType(inherited);
    const replacement_type = declarationType(replacement);
    const inherited_instance = if (@TypeOf(inherited) == type) inherited_type{} else inherited;
    const replacement_instance = if (@TypeOf(replacement) == type) replacement_type{} else replacement;
    const merged_elements = overlayTuples(inherited_instance.elements, replacement_instance.elements);

    return struct {
        name: []const u8 = replacement_instance.name,
        elements: @TypeOf(merged_elements) = merged_elements,
        state_type: ElementType = replacement_instance.state_type,
    };
}

fn pathRemovedByVertexOverlay(
    comptime path: []const u8,
    comptime base: anytype,
    comptime additions: anytype,
    comptime prefix: []const u8,
) bool {
    inline for (std.meta.fields(@TypeOf(additions)), 0..) |_, addition_index| {
        const replacement = additions[addition_index];
        if (declaredElementCategory(replacement) != .vertex) continue;
        const replacement_name = declaredElementName(replacement) orelse continue;

        inline for (std.meta.fields(@TypeOf(base)), 0..) |_, base_index| {
            const inherited = base[base_index];
            const inherited_name = declaredElementName(inherited) orelse continue;
            if (declaredElementCategory(inherited) != .vertex or
                !std.mem.eql(u8, inherited_name, replacement_name)) continue;

            const full_name = if (prefix.len == 0)
                replacement_name
            else
                std.fmt.comptimePrint("{s}/{s}", .{ prefix, replacement_name });
            const recursive = vertexReplacementCount(inherited, additions) == 1 and
                canMergeVertexChildren(inherited, replacement) and
                nestedOverlayHasChanges(
                    (if (@TypeOf(inherited) == type) declarationType(inherited){} else inherited).elements,
                    (if (@TypeOf(replacement) == type) declarationType(replacement){} else replacement).elements,
                );
            if (recursive) {
                const inherited_type = declarationType(inherited);
                const replacement_type = declarationType(replacement);
                const inherited_instance = if (@TypeOf(inherited) == type) inherited_type{} else inherited;
                const replacement_instance = if (@TypeOf(replacement) == type) replacement_type{} else replacement;
                if (pathRemovedByVertexOverlay(path, inherited_instance.elements, replacement_instance.elements, full_name)) {
                    return true;
                }
            } else if (pathInVertexSubtree(path, full_name)) {
                return true;
            }
            break;
        }
    }
    return false;
}

fn isTransitionRemovedByVertex(comptime element: anytype, comptime base: anytype, comptime additions: anytype) bool {
    const source_path = transitionPath(element, true) orelse return false;
    const target_path = transitionPath(element, false);
    if (pathRemovedByVertexOverlay(source_path, base, additions, "")) return true;
    return if (target_path) |path| pathRemovedByVertexOverlay(path, base, additions, "") else false;
}

fn isRedefinitionOf(comptime element: anytype, comptime replacement_names: anytype) bool {
    if (isInitialDeclaration(element)) {
        inline for (std.meta.fields(@TypeOf(replacement_names))) |field| {
            if (isInitialDeclaration(@field(replacement_names, field.name))) return true;
        }
    }

    const element_name = declaredElementName(element) orelse return false;
    const element_category = declaredElementCategory(element) orelse return false;
    inline for (std.meta.fields(@TypeOf(replacement_names))) |field| {
        const replacement = @field(replacement_names, field.name);
        if (declaredElementName(replacement)) |replacement_name| {
            if (std.mem.eql(u8, element_name, replacement_name)) {
                const replacement_category = declaredElementCategory(replacement) orelse continue;
                if (element_category != replacement_category) {
                    @compileError("Redefine addition collides with an inherited declaration of a different category");
                }
                return true;
            }
        }
    }
    return false;
}

fn overlayTuplesType(comptime base: anytype, comptime additions: anytype) type {
    const base_fields = std.meta.fields(@TypeOf(base));
    const addition_fields = std.meta.fields(@TypeOf(additions));
    var types: [base_fields.len + addition_fields.len]type = undefined;
    var count: usize = 0;

    inline for (base_fields, 0..) |field, index| {
        _ = field;
        if (vertexReplacementIndex(base[index], additions)) |replacement_index| {
            const replacement = additions[replacement_index];
            if (vertexReplacementCount(base[index], additions) == 1 and
                canMergeVertexChildren(base[index], replacement) and
                nestedOverlayHasChanges(
                    (if (@TypeOf(base[index]) == type) declarationType(base[index]){} else base[index]).elements,
                    (if (@TypeOf(replacement) == type) declarationType(replacement){} else replacement).elements,
                ))
            {
                types[count] = @TypeOf(mergedVertexType(base[index], replacement));
                count += 1;
                continue;
            }
        }
        if (!isRedefinitionOf(base[index], additions) and !isTransitionRemovedByVertex(base[index], base, additions)) {
            types[count] = @TypeOf(base[index]);
            count += 1;
        }
    }
    inline for (addition_fields, 0..) |field, index| {
        _ = field;
        var merged = false;
        inline for (base_fields, 0..) |base_field, base_index| {
            _ = base_field;
            if (vertexReplacementIndex(base[base_index], additions)) |replacement_index| {
                if (replacement_index == index and
                    vertexReplacementCount(base[base_index], additions) == 1 and
                    canMergeVertexChildren(base[base_index], additions[index]) and
                    nestedOverlayHasChanges(
                        (if (@TypeOf(base[base_index]) == type) declarationType(base[base_index]){} else base[base_index]).elements,
                        (if (@TypeOf(additions[index]) == type) declarationType(additions[index]){} else additions[index]).elements,
                    ))
                {
                    merged = true;
                }
            }
        }
        if (!merged) {
            types[count] = @TypeOf(additions[index]);
            count += 1;
        }
    }
    return std.meta.Tuple(types[0..count]);
}

fn overlayTuples(comptime base: anytype, comptime additions: anytype) overlayTuplesType(base, additions) {
    const base_fields = std.meta.fields(@TypeOf(base));
    const addition_fields = std.meta.fields(@TypeOf(additions));
    const Result = overlayTuplesType(base, additions);
    var result: Result = undefined;
    var count: usize = 0;

    inline for (base_fields, 0..) |field, index| {
        _ = field;
        if (vertexReplacementIndex(base[index], additions)) |replacement_index| {
            const replacement = additions[replacement_index];
            if (vertexReplacementCount(base[index], additions) == 1 and
                canMergeVertexChildren(base[index], replacement) and
                nestedOverlayHasChanges(
                    (if (@TypeOf(base[index]) == type) declarationType(base[index]){} else base[index]).elements,
                    (if (@TypeOf(replacement) == type) declarationType(replacement){} else replacement).elements,
                ))
            {
                result[count] = mergedVertexType(base[index], replacement);
                count += 1;
                continue;
            }
        }
        if (!isRedefinitionOf(base[index], additions) and !isTransitionRemovedByVertex(base[index], base, additions)) {
            result[count] = base[index];
            count += 1;
        }
    }
    inline for (addition_fields, 0..) |field, index| {
        _ = field;
        var merged = false;
        inline for (base_fields, 0..) |base_field, base_index| {
            _ = base_field;
            if (vertexReplacementIndex(base[base_index], additions)) |replacement_index| {
                if (replacement_index == index and
                    vertexReplacementCount(base[base_index], additions) == 1 and
                    canMergeVertexChildren(base[base_index], additions[index]) and
                    nestedOverlayHasChanges(
                        (if (@TypeOf(base[base_index]) == type) declarationType(base[base_index]){} else base[base_index]).elements,
                        (if (@TypeOf(additions[index]) == type) declarationType(additions[index]){} else additions[index]).elements,
                    ))
                {
                    merged = true;
                }
            }
        }
        if (!merged) {
            result[count] = additions[index];
            count += 1;
        }
    }
    return result;
}

fn tupleConcatType(comptime left: anytype, comptime right: anytype) type {
    const left_fields = std.meta.fields(@TypeOf(left));
    const right_fields = std.meta.fields(@TypeOf(right));
    var types: [left_fields.len + right_fields.len]type = undefined;
    inline for (left_fields, 0..) |field, index| types[index] = field.type;
    inline for (right_fields, 0..) |field, index| types[left_fields.len + index] = field.type;
    return std.meta.Tuple(&types);
}

fn concatTuples(comptime left: anytype, comptime right: anytype) tupleConcatType(left, right) {
    const left_fields = std.meta.fields(@TypeOf(left));
    const right_fields = std.meta.fields(@TypeOf(right));
    const Result = tupleConcatType(left, right);
    var result: Result = undefined;
    inline for (left_fields, 0..) |_, index| result[index] = left[index];
    inline for (right_fields, 0..) |_, index| result[left_fields.len + index] = right[index];
    return result;
}

fn invokeModelHook(comptime callback: anytype, model: *Model, comptime allow_model_return: bool) !void {
    const CallbackType = @TypeOf(callback);
    const function_info = switch (@typeInfo(CallbackType)) {
        .@"fn" => |info| info,
        .pointer => |info| switch (@typeInfo(info.child)) {
            .@"fn" => |function| function,
            else => @compileError("model hook must be a function"),
        },
        else => @compileError("model hook must be a function"),
    };

    const return_type = function_info.return_type orelse void;
    if (return_type == void) {
        @call(.auto, callback, .{model});
        return;
    }

    if (@typeInfo(return_type) == .error_union) {
        const payload_type = @typeInfo(return_type).error_union.payload;
        if (payload_type == void) {
            try @call(.auto, callback, .{model});
            return;
        }
        if (allow_model_return and payload_type == *Model) {
            const returned_model = try @call(.auto, callback, .{model});
            if (returned_model != model) return ValidationError.FinalizerReturnedDifferentModel;
            return;
        }
        @compileError(if (allow_model_return)
            "model finalizer must return void, an error union of void, *Model, or an error union of *Model"
        else
            "model validator must return void or an error union of void");
    }

    if (allow_model_return and return_type == *Model) {
        const returned_model = @call(.auto, callback, .{model});
        if (returned_model != model) return ValidationError.FinalizerReturnedDifferentModel;
        return;
    }

    @compileError(if (allow_model_return)
        "model finalizer must return void, an error union of void, *Model, or an error union of *Model"
    else
        "model validator must return void or an error union of void");
}

fn invokeValidatorHook(comptime callback: anytype, model: *Model) !void {
    return invokeModelHook(callback, model, false);
}

fn invokeFinalizerHook(comptime callback: anytype, model: *Model) !void {
    return invokeModelHook(callback, model, true);
}

fn applyLastValidator(comptime elements: anytype, model: *Model) !void {
    const fields = std.meta.fields(@TypeOf(elements));
    if (fields.len == 0) return;
    return applyLastValidatorAt(elements, model, fields.len);
}

fn hasModelValidator(comptime elements: anytype) bool {
    const fields = std.meta.fields(@TypeOf(elements));
    inline for (fields, 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "validator_fn")) return true;
    }
    return false;
}

fn applyLastValidatorAt(comptime elements: anytype, model: *Model, comptime count: usize) !void {
    if (count == 0) return;
    const element = elements[count - 1];
    if (@TypeOf(element) == type and @hasField(element, "validator_fn")) {
        const marker = element{};
        return invokeValidatorHook(marker.validator_fn, model);
    }
    return applyLastValidatorAt(elements, model, count - 1);
}

fn applyLastFinalizer(comptime elements: anytype, model: *Model) !void {
    const fields = std.meta.fields(@TypeOf(elements));
    if (fields.len == 0) return;
    return applyLastFinalizerAt(elements, model, fields.len);
}

fn hasModelFinalizer(comptime elements: anytype) bool {
    const fields = std.meta.fields(@TypeOf(elements));
    inline for (fields, 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "finalizer_fn")) return true;
    }
    return false;
}

fn applyLastFinalizerAt(comptime elements: anytype, model: *Model, comptime count: usize) !void {
    if (count == 0) return;
    const element = elements[count - 1];
    if (@TypeOf(element) == type and @hasField(element, "finalizer_fn")) {
        const marker = element{};
        return invokeFinalizerHook(marker.finalizer_fn, model);
    }
    return applyLastFinalizerAt(elements, model, count - 1);
}

fn observationTargetsMatch(comptime targets: anytype, value: []const u8) bool {
    const fields = std.meta.fields(@TypeOf(targets));
    if (fields.len == 0) return true;

    inline for (fields, 0..) |_, index| {
        const target_spec = targets[index];
        const target_type = @TypeOf(target_spec);
        if (target_type == EventBuilder) {
            if (match(value, target_spec.event_name)) return true;
        } else if (isStringLike(target_type)) {
            if (match(value, stringSlice(target_spec))) return true;
        }
    }
    return false;
}

fn emitObservation(
    comptime callback: anytype,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
    ctx: *Context,
    instance: *Instance,
    event: Event,
) void {
    var observation = Event.init(ctx.allocator, "hsm/observation");
    defer observation.deinit();
    observation.setIdentity(null, source_name, null) catch return;
    var payload = ObservationData{
        .event = event,
        .occurrence = occurrence,
        .source = source_name,
    };
    observation.putData("", @ptrCast(&payload)) catch return;
    observation.putData("event", @ptrCast(&payload.event)) catch return;
    observation.putData("occurrence", @ptrCast(&payload.occurrence)) catch return;
    @call(.auto, callback, .{ ctx, instance, observation });
}

fn makeObservedVoidBehavior(
    comptime original: *const anyopaque,
    comptime callback: anytype,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
) *const anyopaque {
    const Wrapper = struct {
        fn call(ctx: *Context, instance: *Instance, event: Event) void {
            emitObservation(callback, source_name, occurrence, ctx, instance, event);
            const original_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void =
                @ptrCast(@alignCast(original));
            original_fn(ctx, instance, event);
        }
    };
    return @ptrCast(&Wrapper.call);
}

fn makeObservedBoolBehavior(
    comptime original: *const anyopaque,
    comptime callback: anytype,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
) *const anyopaque {
    const Wrapper = struct {
        fn call(ctx: *Context, instance: *Instance, event: Event) bool {
            emitObservation(callback, source_name, occurrence, ctx, instance, event);
            const original_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) bool =
                @ptrCast(@alignCast(original));
            return original_fn(ctx, instance, event);
        }
    };
    return @ptrCast(&Wrapper.call);
}

fn makeObservedTimerBehavior(
    comptime original: *const anyopaque,
    comptime callback: anytype,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
) *const anyopaque {
    const Wrapper = struct {
        fn call(ctx: *Context, instance: *Instance, event: Event) u64 {
            emitObservation(callback, source_name, occurrence, ctx, instance, event);
            const original_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 =
                @ptrCast(@alignCast(original));
            return original_fn(ctx, instance, event);
        }
    };
    return @ptrCast(&Wrapper.call);
}

fn observedVoidFunction(
    comptime original: *const anyopaque,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
    comptime elements: anytype,
) *const anyopaque {
    comptime var wrapped = original;
    inline for (std.meta.fields(@TypeOf(elements)), 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "observer_fn")) {
            const marker = comptime element{};
            if (comptime observationTargetsMatch(marker.observer_targets, source_name)) {
                wrapped = comptime makeObservedVoidBehavior(wrapped, marker.observer_fn, source_name, occurrence);
            }
        }
    }
    return wrapped;
}

fn observedBoolFunction(
    comptime original: *const anyopaque,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
    comptime elements: anytype,
) *const anyopaque {
    comptime var wrapped = original;
    inline for (std.meta.fields(@TypeOf(elements)), 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "observer_fn")) {
            const marker = comptime element{};
            if (comptime observationTargetsMatch(marker.observer_targets, source_name)) {
                wrapped = comptime makeObservedBoolBehavior(wrapped, marker.observer_fn, source_name, occurrence);
            }
        }
    }
    return wrapped;
}

fn observedTimerFunction(
    comptime original: *const anyopaque,
    comptime source_name: []const u8,
    comptime occurrence: []const u8,
    comptime elements: anytype,
) *const anyopaque {
    comptime var wrapped = original;
    inline for (std.meta.fields(@TypeOf(elements)), 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "observer_fn")) {
            const marker = comptime element{};
            if (comptime observationTargetsMatch(marker.observer_targets, source_name)) {
                wrapped = comptime makeObservedTimerBehavior(wrapped, marker.observer_fn, source_name, occurrence);
            }
        }
    }
    return wrapped;
}

fn noopBehavior(ctx: *Context, instance: *Instance, event: Event) void {
    _ = ctx;
    _ = instance;
    _ = event;
}

fn hasObservationTarget(comptime elements: anytype, comptime source_name: []const u8) bool {
    inline for (std.meta.fields(@TypeOf(elements)), 0..) |_, index| {
        const element = elements[index];
        if (@TypeOf(element) == type and @hasField(element, "observer_fn")) {
            const marker = comptime element{};
            if (observationTargetsMatch(marker.observer_targets, source_name)) return true;
        }
    }
    return false;
}

/// Replay a compile-time model definition under the same or a replacement
/// root name and append additional top-level elements.
///
/// Zig has no variadic arguments, so pass the optional replacement name and
/// additional elements in one tuple:
/// Redefine(Base, .{ State("extra", .{}) }) or
/// Redefine(Base, .{ "Renamed", State("extra", .{}) }).
pub fn redefine(comptime model: type, comptime args: anytype) type {
    if (!@hasDecl(model, "model_elements") or !@hasDecl(model, "model_name")) {
        @compileError("Redefine expects a model returned by define");
    }

    const fields = std.meta.fields(@TypeOf(args));
    const has_name = fields.len > 0 and isStringLike(fields[0].type);
    const model_name = if (has_name) stringSlice(args[0]) else model.model_name;
    comptime validateModelMemberLiteral("model", model_name);
    const additional = tupleTail(args, if (has_name) 1 else 0);
    return define(model_name, overlayTuples(model.model_elements, additional));
}

/// Define a state machine model at compile time
pub fn define(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        const model_name = name;
        const model_elements = elements;

        pub const machine_name = model_name;

        pub fn build(allocator: std.mem.Allocator) !Model {
            return buildInternal(allocator, true);
        }

        /// Build the model without automatic validation.
        ///
        /// This is intentionally limited to tests that need to inspect an
        /// invalid model with validate() after construction. Explicit model
        /// validators still run so their hook semantics remain unchanged.
        pub fn buildUnchecked(allocator: std.mem.Allocator) !Model {
            return buildInternal(allocator, false);
        }

        fn buildInternal(allocator: std.mem.Allocator, comptime run_default_validator: bool) !Model {
            var model = try createModel(allocator, model_name);
            errdefer model.deinit();

            // Add root state
            _ = try addState(&model, "/" ++ model_name, .model);

            // Register observation markers as model-visible members before
            // validators run. Runtime behavior wrapping remains compile-time
            // and direct; these members provide the canonical model surface.
            comptime var observation_index: usize = 0;
            inline for (std.meta.fields(@TypeOf(model_elements)), 0..) |_, index| {
                const element = model_elements[index];
                if (@TypeOf(element) == type and @hasField(element, "observer_fn")) {
                    const observation_name = try std.fmt.allocPrint(model.allocator, "/{s}/observation_{}", .{ model.name, observation_index });
                    defer model.allocator.free(observation_name);
                    _ = try addBehavior(&model, observation_name, @ptrCast(&noopBehavior));
                    observation_index += 1;
                }
            }

            // Process elements
            try processElements(&model, "/" ++ model_name, "/" ++ model_name, model_elements);

            // Resolve targets against the complete flat member set before maps
            // are built. During element processing, sibling states may not have
            // been created yet, so early resolution is necessarily provisional.
            try canonicalizeTransitionTargets(&model);
            finalizeTransitionKinds(&model);
            if (hasModelValidator(model_elements)) {
                try applyLastValidator(model_elements, &model);
            } else if (run_default_validator) {
                try DefaultModelValidator.validate(&model);
            }

            // Keep duplicate members available for validate() to report, but
            // do not build maps whose qualified-name keys would collide.
            var member_names = std.StringHashMap(void).init(allocator);
            defer member_names.deinit();
            var has_duplicate_member_names = false;
            var member_iter = model.members.iterator();
            while (member_iter.next()) |member_entry| {
                if (member_names.contains(member_entry.value_ptr.*.qualified_name)) {
                    has_duplicate_member_names = true;
                    break;
                }
                try member_names.put(member_entry.value_ptr.*.qualified_name, {});
            }

            if (has_duplicate_member_names and run_default_validator) {
                return ValidationError.DuplicateMemberName;
            }

            if (!has_duplicate_member_names) {
                if (hasModelFinalizer(model_elements)) {
                    try applyLastFinalizer(model_elements, &model);
                } else {
                    try DefaultModelFinalizer.finalize(&model);
                }
            }

            return model;
        }

        fn processElements(model: *Model, parent_path: []const u8, comptime parent_source_path: []const u8, elems: anytype) !void {
            const fields = std.meta.fields(@TypeOf(elems));
            comptime var transition_index: usize = 0;
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

                    if (@hasField(actual_type, "point_type")) {
                        try processConnectionPoint(model, parent_path, parent_source_path, actual_type{});
                        continue;
                    }

                    if (@hasField(actual_type, "op_name")) {
                        const op_instance = actual_type{};
                        try processOperation(model, op_instance);
                        continue;
                    }

                    if (@hasField(actual_type, "args")) {
                        const transition_instance = actual_type{};
                        try processTransition(model, getState(model, parent_path) orelse return error.NoParentState, parent_path, parent_source_path, transition_index, transition_instance);
                        transition_index += 1;
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
                            try processHistoryDefaultTransitions(model, state_path, parent_path, parent_source_path ++ "/" ++ state_instance.name, state_instance.elements);
                        } else {
                            const state_elem = try addState(model, state_path, state_instance.state_type);

                            // Process state contents
                            if (@hasField(actual_type, "elements") and getState(model, state_path).? == state_elem) {
                                try processStateContents(model, state_elem, state_path, parent_source_path ++ "/" ++ state_instance.name, state_instance.elements);
                            }
                        }
                    } else if (@hasField(actual_type, "target_path")) {
                        // It's an initial transition - instantiate it
                        const initial_instance = actual_type{};
                        try processInitialTransition(model, parent_path, parent_source_path, initial_instance);
                    }
                } else if (type_info == .@"struct") {
                    // Handle direct struct instances
                    if (@hasField(element_type, "point_type")) {
                        try processConnectionPoint(model, parent_path, parent_source_path, element);
                    } else if (@hasField(element_type, "attr_name")) {
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
                            try processHistoryDefaultTransitions(model, state_path, parent_path, parent_source_path ++ "/" ++ element.name, element.elements);
                        } else {
                            const state_elem = try addState(model, state_path, element.state_type);

                            // Process state contents
                            if (@hasField(element_type, "elements") and getState(model, state_path).? == state_elem) {
                                try processStateContents(model, state_elem, state_path, parent_source_path ++ "/" ++ element.name, element.elements);
                            }
                        }
                    } else if (@hasField(element_type, "args")) {
                        // Direct transition instance
                        try processTransition(model, getState(model, parent_path) orelse return error.NoParentState, parent_path, parent_source_path, transition_index, element);
                        transition_index += 1;
                    } else if (@hasField(element_type, "target_path")) {
                        // Direct initial transition instance
                        try processInitialTransition(model, parent_path, parent_source_path, element);
                    }
                }
            }
        }

        fn processOperation(model: *Model, comptime op_builder: anytype) !void {
            const operation_path = try qualifyModelMemberName(model.allocator, model.name, op_builder.op_name);
            defer model.allocator.free(operation_path);
            const source_name = comptime std.fmt.comptimePrint("/{s}/{s}", .{ model_name, op_builder.op_name });
            _ = try addOperation(model, operation_path, observedVoidFunction(@ptrCast(op_builder.function_ptr), source_name, "behavior", model_elements));
        }

        fn processConnectionPoint(model: *Model, owner_path: []const u8, comptime owner_source_path: []const u8, point_builder: anytype) !void {
            const point_path = try std.fmt.allocPrint(model.allocator, "{s}/{s}", .{ owner_path, point_builder.point_name });
            defer model.allocator.free(point_path);
            const point = try addConnectionPoint(model, point_path, point_builder.point_type);

            var target_path: ?[]const u8 = null;
            var target_count: usize = 0;
            var effect_names = std.ArrayList([]const u8).empty;
            defer effect_names.deinit(model.allocator);

            inline for (std.meta.fields(@TypeOf(point_builder.elements)), 0..) |_, index| {
                const partial = point_builder.elements[index];
                const PartialType = @TypeOf(partial);
                if (PartialType == TargetBuilder) {
                    target_count += 1;
                    target_path = partial.target_path;
                } else if (PartialType == type) {
                    if (@hasField(partial, "target_path")) {
                        target_count += 1;
                        const partial_instance = partial{};
                        target_path = partial_instance.target_path;
                    } else if (@hasField(partial, "functions")) {
                        const effect_builder = partial{};
                        for (effect_builder.functions, 0..) |func, function_index| {
                            const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ point_path, function_index });
                            const source_name = comptime std.fmt.comptimePrint("{s}/{s}/transition/effect_{}", .{ owner_source_path, point_builder.point_name, function_index });
                            _ = try addBehavior(model, effect_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                            try effect_names.append(model.allocator, effect_name);
                        }
                    }
                } else if (@typeInfo(PartialType) == .@"struct") {
                    if (@hasField(PartialType, "target_path")) {
                        target_count += 1;
                        target_path = partial.target_path;
                    } else if (@hasField(PartialType, "functions")) {
                        for (partial.functions, 0..) |func, function_index| {
                            const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ point_path, function_index });
                            const source_name = comptime std.fmt.comptimePrint("{s}/{s}/transition/effect_{}", .{ owner_source_path, point_builder.point_name, function_index });
                            _ = try addBehavior(model, effect_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                            try effect_names.append(model.allocator, effect_name);
                        }
                    }
                }
            }

            if (target_count > 1) return ValidationError.InvalidTransitionTarget;
            if (point_builder.point_type == .entry_point and target_path == null) return ValidationError.InvalidTransitionTarget;
            if (point_builder.point_type == .exit_point and target_path != null) return ValidationError.InvalidTransitionTarget;

            const resolved_target = if (point_builder.point_type == .exit_point)
                try model.allocator.dupe(u8, owner_path)
            else
                try resolveTargetPath(model.allocator, owner_path, target_path.?);
            defer model.allocator.free(resolved_target);

            const transition_name = try std.fmt.allocPrint(model.allocator, "{s}/transition", .{point_path});
            defer model.allocator.free(transition_name);
            const transition_element = try addTransition(model, transition_name, point_path, resolved_target, null);
            if (effect_names.items.len > 0) {
                transition_element.effects = try effect_names.toOwnedSlice(model.allocator);
            }
            const transition_ref = try model.allocator.dupe(u8, transition_element.element.qualified_name);
            errdefer model.allocator.free(transition_ref);
            const transition_refs = try model.allocator.alloc([]const u8, 1);
            transition_refs[0] = transition_ref;
            point.transitions = transition_refs;
        }

        fn processAttribute(model: *Model, attr_builder: anytype) !void {
            if (attr_builder.has_default) {
                try addAttribute(model, attr_builder.attr_name, attr_builder.value_type, attr_builder.default_value, true);
            } else {
                try addAttribute(model, attr_builder.attr_name, attr_builder.value_type, {}, false);
            }
        }

        fn processStateContents(model: *Model, state_elem: *StateElement, state_path: []const u8, comptime source_path: []const u8, contents: anytype) !void {
            const fields = std.meta.fields(@TypeOf(contents));
            comptime var transition_index: usize = 0;
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

                        if (@hasField(instance_type, "point_type")) {
                            try processConnectionPoint(model, state_path, source_path, content_instance);
                        } else if (@hasField(instance_type, "attr_name")) {
                            try processAttribute(model, content_instance);
                        } else if (@hasField(instance_type, "op_name")) {
                            try processOperation(model, content_instance);
                        } else if (@hasField(instance_type, "functions")) {
                            // It's an entry/exit/activity builder
                            const type_name = @typeName(actual_type);
                            if (std.mem.indexOf(u8, type_name, "entry") != null) {
                                try processEntryFunctions(model, state_elem, state_path, source_path, content_instance.functions);
                            } else if (std.mem.indexOf(u8, type_name, "exit") != null) {
                                try processExitFunctions(model, state_elem, state_path, source_path, content_instance.functions);
                            } else if (std.mem.indexOf(u8, type_name, "activity") != null) {
                                try processActivityFunctions(model, state_elem, state_path, source_path, content_instance.functions);
                            }
                        } else if (@hasField(instance_type, "event_names")) {
                            // It's a defer builder
                            try processDeferredEvents(model, state_elem, content_instance.event_names);
                        } else if (@hasField(instance_type, "args")) {
                            // It's a transition
                            try processTransition(model, state_elem, state_path, source_path, transition_index, content_instance);
                            transition_index += 1;
                        } else if (@hasField(instance_type, "target_path")) {
                            // It's an initial transition
                            try processInitialTransition(model, state_path, source_path, content_instance);
                        } else if (@hasField(instance_type, "state_type")) {
                            // It's a nested state
                            try processElements(model, state_path, source_path ++ "/" ++ content_instance.name, .{content_instance});
                        }
                    }
                } else if (content_type_info == .@"struct") {
                    if (@hasField(content_type, "point_type")) {
                        try processConnectionPoint(model, state_path, source_path, content);
                    } else if (@hasField(content_type, "attr_name")) {
                        try processAttribute(model, content);
                    } else if (@hasField(content_type, "op_name")) {
                        try processOperation(model, content);
                    } else if (@hasField(content_type, "functions")) {
                        // It's an entry/exit/activity builder
                        const type_name = @typeName(content_type);
                        if (std.mem.indexOf(u8, type_name, "entry") != null) {
                            try processEntryFunctions(model, state_elem, state_path, source_path, content.functions);
                        } else if (std.mem.indexOf(u8, type_name, "exit") != null) {
                            try processExitFunctions(model, state_elem, state_path, source_path, content.functions);
                        } else if (std.mem.indexOf(u8, type_name, "activity") != null) {
                            try processActivityFunctions(model, state_elem, state_path, source_path, content.functions);
                        }
                    } else if (@hasField(content_type, "event_names")) {
                        // It's a defer builder
                        try processDeferredEvents(model, state_elem, content.event_names);
                    } else if (@hasField(content_type, "args")) {
                        // It's a transition
                        try processTransition(model, state_elem, state_path, source_path, transition_index, content);
                        transition_index += 1;
                    } else if (@hasField(content_type, "target_path")) {
                        // It's an initial transition
                        try processInitialTransition(model, state_path, source_path, content);
                    } else if (@hasField(content_type, "state_type")) {
                        // It's a nested state
                        try processElements(model, state_path, source_path ++ "/" ++ content.name, .{content});
                    }
                }
            }
        }

        fn processEntryFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, comptime source_path: []const u8, functions: anytype) !void {
            var entry_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/entry_{}", .{ state_path, idx });
                const source_name = comptime std.fmt.comptimePrint("{s}/entry_{}", .{ source_path, idx });
                _ = try addBehavior(model, behavior_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                entry_names[idx] = behavior_name;
            }
            state_elem.entry = entry_names;
        }

        fn processExitFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, comptime source_path: []const u8, functions: anytype) !void {
            var exit_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/exit_{}", .{ state_path, idx });
                const source_name = comptime std.fmt.comptimePrint("{s}/exit_{}", .{ source_path, idx });
                _ = try addBehavior(model, behavior_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                exit_names[idx] = behavior_name;
            }
            state_elem.exit = exit_names;
        }

        fn processActivityFunctions(model: *Model, state_elem: *StateElement, state_path: []const u8, comptime source_path: []const u8, functions: anytype) !void {
            var activity_names = try model.allocator.alloc([]const u8, functions.len);
            inline for (functions, 0..) |func, idx| {
                const behavior_name = try std.fmt.allocPrint(model.allocator, "{s}/activity_{}", .{ state_path, idx });
                const source_name = comptime std.fmt.comptimePrint("{s}/activity_{}", .{ source_path, idx });
                _ = try addBehavior(model, behavior_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
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

        fn processTransition(model: *Model, state_elem: *StateElement, state_path: []const u8, comptime source_path: []const u8, comptime transition_index: usize, trans_builder: anytype) !void {
            try processTransitionWithTargetBase(model, state_elem, state_path, source_path, transition_index, trans_builder, state_path, "transition");
        }

        fn processTransitionWithTargetBase(
            model: *Model,
            state_elem: *StateElement,
            state_path: []const u8,
            comptime source_path: []const u8,
            comptime transition_index: usize,
            trans_builder: anytype,
            target_base_path: []const u8,
            comptime name_marker: []const u8,
        ) !void {
            const trans_name = try std.fmt.allocPrint(model.allocator, "{s}/{s}_{}", .{ state_path, name_marker, transition_index });
            const transition_source_name = comptime std.fmt.comptimePrint("{s}/{s}_{}", .{ source_path, name_marker, transition_index });

            const raw_source_path = trans_builder.getSource();
            var resolved_source_path: ?[]const u8 = null;
            const effective_source_path = if (raw_source_path) |raw_path| blk: {
                resolved_source_path = try resolveTargetPath(model.allocator, state_path, raw_path);
                break :blk resolved_source_path.?;
            } else state_path;
            defer if (resolved_source_path) |allocated_source_path| model.allocator.free(allocated_source_path);

            var resolved_event_name: ?[]const u8 = null;
            defer if (resolved_event_name) |resolved_name| model.allocator.free(resolved_name);

            const declared_event_name = comptime trans_builder.getEvent();
            var event_name = declared_event_name;
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
            const entry_point_name = trans_builder.getEntryPoint();
            const exit_point_name = trans_builder.getExitPoint();
            if (entry_point_name != null and exit_point_name != null) return ValidationError.InvalidTransitionTarget;
            if (exit_point_name != null and
                (trans_builder.getEvent() != null or trans_builder.getOnSet() != null or
                    trans_builder.getOnCall() != null or trans_builder.getTimer() != null))
            {
                return ValidationError.InvalidTransitionTarget;
            }
            const raw_target_path = trans_builder.getTarget();
            if (entry_point_name != null and raw_target_path == null) return ValidationError.InvalidTransitionTarget;
            if (exit_point_name) |point_name| {
                if (resolved_event_name) |resolved_name| {
                    model.allocator.free(resolved_name);
                    resolved_event_name = null;
                }
                resolved_event_name = try exitPointEventName(model.allocator, effective_source_path, point_name);
                event_name = resolved_event_name;
            }

            // Resolve target path if present (ownership transferred to addTransition)
            var resolved_target_path: ?[]const u8 = null;
            if (raw_target_path) |target_path| {
                // A source-qualified self target is relative to the selected
                // source. Other targets remain relative to the declaration
                // owner, matching the sibling runtimes.
                const target_base = if (raw_source_path != null and std.mem.eql(u8, target_path, "."))
                    effective_source_path
                else
                    state_path;
                if (entry_point_name) |point_name| {
                    resolved_target_path = try std.fmt.allocPrint(model.allocator, "{s}{s}|{s}", .{ entryPointTargetMarker, target_path, point_name });
                } else {
                    resolved_target_path = try resolveTargetPath(model.allocator, if (raw_source_path != null) target_base else target_base_path, target_path);
                }
            }
            defer if (resolved_target_path) |target_path| model.allocator.free(target_path);

            const trans = try addTransition(model, trans_name, effective_source_path, resolved_target_path, event_name);
            if (trans_builder.getKind()) |kind| trans.kind = kind;

            // Add guards if present. Multiple guards are evaluated in declaration order as AND.
            const guards = comptime trans_builder.getGuards();
            if (guards.len > 0) {
                var guard_names = try model.allocator.alloc([]const u8, guards.len);
                errdefer model.allocator.free(guard_names);
                inline for (guards, 0..) |guard_fn_ptr, idx| {
                    const guard_name = try std.fmt.allocPrint(model.allocator, "{s}/guard_{}", .{ trans_name, idx });
                    const guard_source_name = comptime std.fmt.comptimePrint("{s}/guard_{}", .{ transition_source_name, idx });
                    _ = try addBehavior(model, guard_name, observedBoolFunction(guard_fn_ptr, guard_source_name, "behavior", model_elements));
                    guard_names[idx] = guard_name;
                }
                trans.guards = guard_names;
                trans.guard = guard_names[0];
            }

            // Add effects if present
            const effects = comptime trans_builder.getEffects();
            if (effects.len > 0) {
                var effect_names = try model.allocator.alloc([]const u8, effects.len);
                inline for (effects, 0..) |effect_fn_ptr, idx| {
                    const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ trans_name, idx });
                    const effect_source_name = comptime std.fmt.comptimePrint("{s}/effect_{}", .{ transition_source_name, idx });
                    _ = try addBehavior(model, effect_name, observedVoidFunction(effect_fn_ptr, effect_source_name, "behavior", model_elements));
                    effect_names[idx] = effect_name;
                }
                trans.effects = effect_names;
            }

            // Add timer function if present
            if (comptime trans_builder.getTimer()) |timer_fn_ptr| {
                const timer_name = try std.fmt.allocPrint(model.allocator, "{s}/timer", .{trans_name});
                const timer_source_name = comptime std.fmt.comptimePrint("{s}/timer", .{transition_source_name});
                _ = try addBehavior(model, timer_name, observedTimerFunction(timer_fn_ptr, timer_source_name, "behavior", model_elements));
                trans.timer_fn = timer_name;
                trans.timer_kind = trans_builder.getTimerKind();
            }

            const observes_transition = hasObservationTarget(model_elements, transition_source_name);
            const observes_event = if (declared_event_name) |declared_event| hasObservationTarget(model_elements, declared_event) else false;
            if (observes_transition or observes_event) {
                const observation_name = try std.fmt.allocPrint(model.allocator, "{s}/observation_event", .{trans_name});
                _ = try addBehavior(model, observation_name, observedVoidFunction(@ptrCast(&noopBehavior), transition_source_name, "event", model_elements));
                const old_effects = trans.effects;
                const new_effects = try model.allocator.alloc([]const u8, old_effects.len + 1);
                new_effects[0] = observation_name;
                @memcpy(new_effects[1..], old_effects);
                if (old_effects.len > 0) model.allocator.free(old_effects);
                trans.effects = new_effects;
            }

            // Add to state's transitions
            var new_transitions = try model.allocator.alloc([]const u8, state_elem.transitions.len + 1);
            @memcpy(new_transitions[0..state_elem.transitions.len], state_elem.transitions);
            new_transitions[state_elem.transitions.len] = trans_name;
            if (state_elem.transitions.len > 0) model.allocator.free(state_elem.transitions);
            state_elem.transitions = new_transitions;
        }

        fn processHistoryDefaultTransitions(
            model: *Model,
            history_path: []const u8,
            parent_path: []const u8,
            comptime source_path: []const u8,
            history_elements: anytype,
        ) !void {
            inline for (std.meta.fields(@TypeOf(history_elements)), 0..) |_, index| {
                const partial = history_elements[index];
                const partial_type = @TypeOf(partial);
                const builder_type = if (partial_type == type) partial else partial_type;
                if (builder_type == TargetBuilder) continue;
                if (!@hasField(builder_type, "args")) @compileError("history defaults must be transition(...)");

                var synthetic_state = StateElement{
                    .element = .{ .kind = .state, .qualified_name = history_path, .id = history_path },
                    .entry = &[_][]const u8{},
                    .exit = &[_][]const u8{},
                    .activities = &[_][]const u8{},
                    .transitions = &[_][]const u8{},
                    .substates = &[_][]const u8{},
                    .deferred = &[_][]const u8{},
                    .initial_transition = null,
                };
                const transition_builder = if (partial_type == type) partial{} else partial;
                try processTransitionWithTargetBase(
                    model,
                    &synthetic_state,
                    history_path,
                    source_path,
                    index,
                    transition_builder,
                    parent_path,
                    "__history_default",
                );
                if (synthetic_state.transitions.len > 0) {
                    for (synthetic_state.transitions) |transition_name| model.allocator.free(transition_name);
                    model.allocator.free(synthetic_state.transitions);
                }
            }
        }

        fn processInitialEffects(model: *Model, transition_element: *TransitionElement, transition_name: []const u8, comptime source_path: []const u8, initial_elements: anytype) !void {
            var effect_names = std.ArrayList([]const u8).empty;
            defer effect_names.deinit(model.allocator);

            inline for (std.meta.fields(@TypeOf(initial_elements)), 0..) |_, index| {
                const partial = initial_elements[index];
                const partial_type = @TypeOf(partial);
                if (comptime isEffectBuilder(partial)) {
                    if (comptime partial_type == type) {
                        const effect_builder = partial{};
                        inline for (effect_builder.functions, 0..) |func, function_index| {
                            const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ transition_name, effect_names.items.len });
                            const source_name = comptime std.fmt.comptimePrint("{s}/.initial/effect_{}", .{ source_path, function_index });
                            _ = try addBehavior(model, effect_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                            try effect_names.append(model.allocator, effect_name);
                        }
                    } else {
                        inline for (partial.functions, 0..) |func, function_index| {
                            const effect_name = try std.fmt.allocPrint(model.allocator, "{s}/effect_{}", .{ transition_name, effect_names.items.len });
                            const source_name = comptime std.fmt.comptimePrint("{s}/.initial/effect_{}", .{ source_path, function_index });
                            _ = try addBehavior(model, effect_name, observedVoidFunction(@ptrCast(&func), source_name, "behavior", model_elements));
                            try effect_names.append(model.allocator, effect_name);
                        }
                    }
                }
            }

            if (effect_names.items.len > 0) {
                transition_element.effects = try effect_names.toOwnedSlice(model.allocator);
            }
        }

        fn processInitialTransition(model: *Model, parent_path: []const u8, comptime source_path: []const u8, init_builder: anytype) !void {
            const parent_state = getState(model, parent_path) orelse return error.NoParentState;
            const trans_name = try std.fmt.allocPrint(model.allocator, "{s}/.initial", .{parent_path});
            defer model.allocator.free(trans_name);

            // Resolve target path properly (ownership transferred to addTransition)
            const target_path = try resolveTargetPath(model.allocator, parent_path, init_builder.target_path);
            defer model.allocator.free(target_path);

            const transition_element = try addTransition(model, trans_name, parent_path, target_path, InitialEventName);
            try processInitialEffects(model, transition_element, trans_name, source_path, init_builder.elements);
            parent_state.initial_transition = try model.allocator.dupe(u8, trans_name);
        }
    };
}

pub const Define = define;
pub const Redefine = redefine;
pub const Validator = validator;
pub const Finalizer = finalizer;
pub const Observe = observe;
pub const TimerEvent = Event.timerEvent;
pub const InitialEvent = Event.initial;
pub const FinalEvent = Event.finalEvent;
pub const ErrorEvent = Event.errorEvent;
pub const State = state;
pub const Submachine = submachineState;
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
pub const EntryPoint = entryPoint;
pub const ExitPoint = exitPoint;
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
pub const Defer = deferEvents;

/// Validation errors
pub const ValidationError = error{
    ChoiceWithoutGuardlessFallback,
    FinalStateWithTransitions,
    FinalStateWithEntry,
    FinalStateWithExit,
    FinalStateWithActivities,
    FinalStateWithDeferred,
    StateWithEmptyName,
    MissingInitialTransition,
    TransitionWithoutTargetOrEffect,
    TransitionWithoutTrigger,
    DuplicateMemberName,
    ConnectionPointNameCollision,
    EmptyModel,
    InvalidTransitionSource,
    InvalidTransitionTarget,
    CircularInitialTransition,
    UnreachableState,
    FinalizerReturnedDifferentModel,
    OutOfMemory,
};

/// Validate a state machine model
pub fn validate(model: *const Model) ValidationError!void {
    try validateInitialTransitionLocality(model);
    try validateInitialTransitionsPresent(model);

    var names = std.StringHashMap(ElementType).init(model.allocator);
    defer names.deinit();
    var name_iter = model.members.iterator();
    while (name_iter.next()) |kv| {
        const name = kv.value_ptr.*.qualified_name;
        if (names.get(name)) |existing_kind| {
            const point_kind = kv.value_ptr.*.kind == .entry_point or kv.value_ptr.*.kind == .exit_point;
            const existing_point_kind = existing_kind == .entry_point or existing_kind == .exit_point;
            if (point_kind or existing_point_kind) return ValidationError.ConnectionPointNameCollision;
            return ValidationError.DuplicateMemberName;
        }
        try names.put(name, kv.value_ptr.*.kind);
    }

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
            .state, .submachine => {
                // Regular states should have valid names and paths
                if (element.qualified_name.len == 0) {
                    return ValidationError.StateWithEmptyName;
                }
            },
            .entry_point => {
                const point = @as(*ConnectionPointElement, @ptrCast(@alignCast(element)));
                if (point.transitions.len != 1) return ValidationError.InvalidTransitionTarget;
                const point_transition = getTransition(model, point.transitions[0]) orelse return ValidationError.InvalidTransitionTarget;
                const point_target = point_transition.target orelse return ValidationError.InvalidTransitionTarget;
                const target_element = model.members.get(point_target) orelse return ValidationError.InvalidTransitionTarget;
                if (target_element.kind == .entry_point or target_element.kind == .exit_point) return ValidationError.InvalidTransitionTarget;
                if (!stateMatchesOrIsDescendant(point_target, point.element.owner())) return ValidationError.InvalidTransitionTarget;
            },
            .exit_point => {
                const point = @as(*ConnectionPointElement, @ptrCast(@alignCast(element)));
                if (point.transitions.len != 1) return ValidationError.InvalidTransitionTarget;
            },
            .transition => {
                // Validate transition sources exist and identify dispatchable states
                const trans = @as(*TransitionElement, @ptrCast(@alignCast(element)));
                const is_initial = std.mem.endsWith(u8, trans.element.qualified_name, "/.initial");
                if (!sourceExists(model, trans.source)) {
                    return ValidationError.InvalidTransitionSource;
                }

                // Validate transition targets exist
                if (trans.target) |target_path| {
                    if (!targetExists(model, target_path)) {
                        return ValidationError.InvalidTransitionTarget;
                    }
                    if (model.members.get(target_path)) |target_element| {
                        if (target_element.kind == .entry_point) {
                            const target_boundary = target_element.owner();
                            const source_is_exit_point = if (model.members.get(trans.source)) |source_element|
                                source_element.kind == .exit_point
                            else
                                false;
                            if (!source_is_exit_point and
                                !std.mem.eql(u8, trans.source, target_boundary) and
                                stateMatchesOrIsDescendant(trans.source, target_boundary))
                            {
                                return ValidationError.InvalidTransitionTarget;
                            }
                        }
                    }
                }
                if (!is_initial and trans.target == null and trans.effects.len == 0) {
                    return ValidationError.TransitionWithoutTargetOrEffect;
                }
                const source_is_choice = if (model.members.get(trans.source)) |source_element| source_element.kind == .choice else false;
                const source_is_history = if (model.members.get(trans.source)) |source_element| source_element.kind == .history else false;
                if (trans.event_name == null and trans.timer_fn == null and
                    !is_initial and
                    !(trans.target != null and (source_is_choice or source_is_history)) and
                    (model.members.get(trans.source) == null or
                        (model.members.get(trans.source).?.kind != .entry_point and
                            model.members.get(trans.source).?.kind != .exit_point)))
                {
                    return ValidationError.TransitionWithoutTrigger;
                }
            },
            else => {},
        }
    }

    // Additional validation: check for circular initial transitions
    try validateInitialTransitions(model);
}

pub const DefaultModelValidator = struct {
    pub fn validate(model: *const Model) ValidationError!void {
        return validateModel(model);
    }
};

pub const DefaultModelFinalizer = struct {
    pub fn finalize(model: *Model) !void {
        try buildTransitionMap(model);
        try buildDeferredMap(model);
    }
};

fn validateModel(model: *const Model) ValidationError!void {
    return validate(model);
}

fn validateInitialTransitionLocality(model: *const Model) ValidationError!void {
    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        if (kv.value_ptr.*.kind != .transition) continue;
        const trans = @as(*const TransitionElement, @ptrCast(@alignCast(kv.value_ptr.*)));
        if (!std.mem.endsWith(u8, trans.element.qualified_name, "/.initial")) continue;
        const target_path = trans.target orelse return ValidationError.InvalidTransitionTarget;
        if (!isAncestor(trans.element.owner(), target_path)) {
            return ValidationError.InvalidTransitionTarget;
        }
    }
}

fn hasChildState(model: *const Model, qualified_name: []const u8) bool {
    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .state and element.kind != .submachine and element.kind != .final and element.kind != .choice and element.kind != .history) continue;
        if (std.mem.eql(u8, element.owner(), qualified_name)) return true;
    }
    return false;
}

fn validateInitialTransitionsPresent(model: *const Model) ValidationError!void {
    var has_model = false;
    var model_has_child = false;
    var root_initial_target: ?[]const u8 = null;
    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind == .model) {
            has_model = true;
            const model_state = @as(*StateElement, @ptrCast(@alignCast(element)));
            model_has_child = hasChildState(model, element.qualified_name);
            if (model_state.initial_transition == null and model_has_child) return ValidationError.MissingInitialTransition;
            if (model_state.initial_transition) |initial_transition_name| {
                if (getTransition(model, initial_transition_name)) |initial_transition| {
                    root_initial_target = initial_transition.target;
                }
            }
        }
    }

    if ((!has_model and model.members.count() == 0) or (has_model and !model_has_child)) {
        return ValidationError.EmptyModel;
    }

    if (root_initial_target) |target_name| {
        var visited = std.StringHashMap(bool).init(model.allocator);
        defer visited.deinit();
        try validateInitialTargetChain(model, target_name, &visited);
    }
}

fn validateInitialTargetChain(
    model: *const Model,
    state_name: []const u8,
    visited: *std.StringHashMap(bool),
) ValidationError!void {
    if (visited.contains(state_name)) return ValidationError.CircularInitialTransition;
    visited.put(state_name, true) catch return ValidationError.OutOfMemory;
    const element = model.members.get(state_name) orelse return;
    if (element.kind != .state and element.kind != .submachine and element.kind != .model) return;
    const state_element = @as(*const StateElement, @ptrCast(@alignCast(element)));
    if (hasChildState(model, state_name) and state_element.initial_transition == null) {
        return ValidationError.MissingInitialTransition;
    }
    if (state_element.initial_transition) |initial_transition_name| {
        const initial_transition = getTransition(model, initial_transition_name) orelse return;
        if (initial_transition.target) |target_name| {
            try validateInitialTargetChain(model, target_name, visited);
        }
    }
}

fn validateInitialTransitions(model: *const Model) ValidationError!void {
    var arena = std.heap.ArenaAllocator.init(model.allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var visited = std.StringHashMap(bool).init(temp_allocator);

    var iter = model.members.iterator();
    while (iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind == .state or element.kind == .submachine or element.kind == .model) {
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
    thread_id: std.atomic.Value(u64),
    dispatching: std.atomic.Value(bool),
};

const TimerHandle = struct {
    thread: std.Thread,
    timer_context: *TimerContext,
};

var deferred_deinit_mutex: std.Thread.Mutex = .{};
var deferred_deinit_machines: ?std.AutoHashMap(*StateMachine, void) = null;

fn requestDeferredDeinit(machine: *StateMachine) !void {
    deferred_deinit_mutex.lock();
    defer deferred_deinit_mutex.unlock();
    if (deferred_deinit_machines == null) {
        deferred_deinit_machines = std.AutoHashMap(*StateMachine, void).init(std.heap.page_allocator);
    }
    try deferred_deinit_machines.?.put(machine, {});
}

fn takeDeferredDeinit(machine: *StateMachine) bool {
    deferred_deinit_mutex.lock();
    defer deferred_deinit_mutex.unlock();
    const machines = &(deferred_deinit_machines orelse return false);
    return machines.fetchRemove(machine) != null;
}

fn hasCurrentTimer(machine: *StateMachine) bool {
    timer_registry_mutex.lock();
    defer timer_registry_mutex.unlock();
    const current_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    var timer_iterator = machine.active_timers.iterator();
    while (timer_iterator.next()) |timer_entry| {
        const timer_context = timer_entry.value_ptr.timer_context;
        if (timer_context.dispatching.load(.acquire) and
            timer_context.thread_id.load(.acquire) == current_thread_id)
        {
            return true;
        }
    }
    return false;
}

const ActivityControl = struct {
    wrapper_owns_context: std.atomic.Value(bool),
    run_requested: std.atomic.Value(bool),
    skip_callback: std.atomic.Value(bool),
};

const ActivityHandle = struct {
    thread: std.Thread,
    ctx: *Context,
    control: *ActivityControl,
};

fn destroyActivityContext(ctx: *Context, control: *ActivityControl) void {
    const allocator = ctx.allocator;
    allocator.destroy(ctx);
    allocator.destroy(control);
}

fn detachActivity(handle: ActivityHandle) void {
    handle.control.wrapper_owns_context.store(true, .release);
    handle.thread.detach();
}

fn joinAndDestroyActivity(handle: ActivityHandle) void {
    handle.thread.join();
    destroyActivityContext(handle.ctx, handle.control);
}

// Timer threads may finish concurrently with state entry/exit and stop. Keep
// the timer index synchronized while dispatch remains serialized by the
// machine's normal runtime path.
var timer_registry_mutex: std.Thread.Mutex = .{};
var activity_registry_mutex: std.Thread.Mutex = .{};
threadlocal var current_activity_context: ?*Context = null;
threadlocal var current_activity_machine: ?*anyopaque = null;
threadlocal var current_queue_processing_machine: ?*StateMachine = null;
var runtime_fallback_transition_depth = std.atomic.Value(usize).init(0);
var runtime_fallback_operation_depth = std.atomic.Value(usize).init(0);

fn historyStorageKey(allocator: std.mem.Allocator, parent_path: []const u8, kind: HistoryKind) ![]const u8 {
    return switch (kind) {
        .shallow => allocator.dupe(u8, parent_path),
        .deep => std.fmt.allocPrint(allocator, "{s}\x00deep", .{parent_path}),
    };
}

/// Queue for deferred events
pub const EventQueue = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    head: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .events = try std.ArrayList(Event).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        while (self.dequeue()) |event| {
            var queued_event = event;
            queued_event.deinit();
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
        if (self.events.items.len == self.events.capacity) {
            const current_capacity = self.events.capacity;
            const new_capacity = if (current_capacity == 0) 1 else current_capacity +| (current_capacity / 2 + 1);
            var replacement = try std.ArrayList(Event).initCapacity(self.allocator, new_capacity);

            const old_count = self.events.items.len;
            if (old_count > 0) {
                const old_capacity = self.events.capacity;
                const old_slots = self.events.allocatedSlice();
                for (0..old_count) |offset| {
                    const index = (self.head + offset) % old_capacity;
                    replacement.appendAssumeCapacity(old_slots[index]);
                }
            }

            self.events.deinit(self.allocator);
            self.events = replacement;
            self.head = 0;
        }

        const index = (self.head + self.events.items.len) % self.events.capacity;
        self.events.allocatedSlice()[index] = event;
        self.events.items.len += 1;
    }

    pub fn pop(self: *Self) ?Event {
        if (self.events.items.len == 0) return null;

        const index = self.head;
        const event = self.events.allocatedSlice()[index];
        self.events.allocatedSlice()[index] = undefined;
        self.events.items.len -= 1;

        if (self.events.items.len == 0) {
            self.head = 0;
        } else {
            self.head = (index + 1) % self.events.capacity;
        }

        return event;
    }

    pub fn len(self: *const Self) usize {
        return self.events.items.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.len() == 0;
    }
};

const InternalRuntimeQueue = struct {
    events: EventQueue,
    mutex: std.Thread.Mutex = .{},
    processing: bool = false,
    runtime_queue: RuntimeQueue,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !*Self {
        const queue = try allocator.create(Self);
        errdefer allocator.destroy(queue);
        queue.* = .{
            .events = try EventQueue.init(allocator),
            .runtime_queue = undefined,
            .allocator = allocator,
        };
        queue.runtime_queue = .{
            .context = @ptrCast(queue),
            .push_fn = push,
            .pop_fn = pop,
            .len_fn = len,
        };
        return queue;
    }

    fn deinit(self: *Self) void {
        self.events.deinit();
        self.allocator.destroy(self);
    }

    fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.events.dequeue()) |queued_event| {
            var event = queued_event;
            event.deinit();
        }
        self.processing = false;
    }

    fn enqueue(self: *Self, event: Event) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.push(event);
        if (self.processing) return false;
        self.processing = true;
        return true;
    }

    /// Reserve the sole drain owner without copying its synchronous event.
    /// Events submitted while another drain is active are copied before they
    /// enter the queue, so their caller-owned storage cannot expire early.
    fn startOrEnqueue(self: *Self, event: Event) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.processing) {
            var queued_event = try cloneEventForQueue(self.allocator, event);
            errdefer queued_event.deinit();
            try self.events.push(queued_event);
            return false;
        }
        self.processing = true;
        return true;
    }

    fn tryStartProcessing(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.processing) return false;
        self.processing = true;
        return true;
    }

    fn waitForProcessing(self: *Self) void {
        while (true) {
            self.mutex.lock();
            const processing = self.processing;
            self.mutex.unlock();
            if (!processing) break;
            std.Thread.yield() catch {};
        }
    }

    fn dequeue(self: *Self) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.pop();
    }

    /// Finish a drain only when no producer raced with the final dequeue.
    /// Keeping `processing` set while an event is executing prevents a second
    /// dispatcher from starting a concurrent drain of the same machine.
    fn finishProcessing(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.events.isEmpty()) return true;
        self.processing = false;
        return false;
    }

    fn stopProcessing(self: *Self) void {
        self.mutex.lock();
        self.processing = false;
        self.mutex.unlock();
    }

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) !void {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        _ = try self.enqueue(event);
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) !?Event {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        return self.dequeue();
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) !usize {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.len();
    }
};

/// Running state machine instance with optimized lookups
pub const StateMachine = struct {
    model: *const Model,
    instance: *anyopaque,
    _context: *Context,
    current_state: []const u8,
    active_states: std.ArrayList([]const u8),
    active_activities: std.StringHashMap(ActivityHandle),
    active_timers: std.StringHashMap(TimerHandle),
    history_value: std.StringHashMap([]const u8),
    deferred_queue: EventQueue,
    attributes: std.StringHashMap(RuntimeAttributeValue),
    runtime_id: ?[]const u8,
    runtime_name: ?[]const u8,
    runtime_data: ?*anyopaque,
    clock: RuntimeClock,
    regular_queue: ?*RuntimeQueue,
    activity_timeout_ns: u64,
    stopped: bool,
    owned_model: ?*anyopaque = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn context(self: *const Self) *Context {
        return canonicalMachineConst(self)._context;
    }

    pub fn state(self: *const Self) []const u8 {
        const machine = canonicalMachineConst(self);
        const lifecycle_lease = acquireLifecycleLease(@constCast(machine)) catch return "";
        var lease = lifecycle_lease orelse return "";
        defer lease.release();
        return if (machine.stopped) "" else machine.current_state;
    }

    pub fn IsStopped(self: *const Self) bool {
        const machine = canonicalMachineConst(self);
        const lifecycle_lease = acquireLifecycleLease(@constCast(machine)) catch return true;
        var lease = lifecycle_lease orelse return true;
        defer lease.release();
        return machine.stopped;
    }

    pub fn AttributeType(self: *const Self, name: []const u8) !?[]const u8 {
        const machine = canonicalMachineConst(self);
        const qualified_name = try qualifyModelMemberName(machine.allocator, machine.model.name, name);
        defer machine.allocator.free(qualified_name);
        if (machine.model.attributes.get(qualified_name)) |attribute_element| {
            if (attribute_element.type_name) |type_name| return type_name;
        }
        if (machine.attributes.get(qualified_name)) |value| return value.type_name;
        return null;
    }

    pub fn ID(self: *const Self) ?[]const u8 {
        return canonicalMachineConst(self).runtime_id;
    }

    pub fn Name(self: *const Self) []const u8 {
        const machine = canonicalMachineConst(self);
        const qualified_name = machine.QualifiedName();
        if (std.mem.lastIndexOfScalar(u8, qualified_name, '/')) |separator| {
            return qualified_name[separator + 1 ..];
        }
        return qualified_name;
    }

    /// Return the stable qualified model path without allocating.
    pub fn QualifiedName(self: *const Self) []const u8 {
        const machine = canonicalMachineConst(self);
        if (machine.runtime_name) |name| return name;
        if (machine.current_state.len == 0 or machine.current_state[0] != '/') return machine.current_state;
        if (std.mem.indexOfScalar(u8, machine.current_state[1..], '/')) |separator| {
            return machine.current_state[0 .. separator + 1];
        }
        return machine.current_state;
    }

    pub fn Data(self: *const Self) ?*anyopaque {
        return canonicalMachineConst(self).runtime_data;
    }

    pub fn Clock(self: *const Self) RuntimeClock {
        return canonicalMachineConst(self).clock;
    }

    fn initializeAttributes(self: *Self) !void {
        var attr_iter = self.model.attributes.iterator();
        while (attr_iter.next()) |attr_entry| {
            if (try cloneRuntimeAttributeValue(self.allocator, attr_entry.value_ptr)) |value| {
                var runtime_value = value;
                var inserted = false;
                errdefer if (!inserted) runtime_value.deinit(self.allocator);
                const key = try self.allocator.dupe(u8, attr_entry.key_ptr.*);
                errdefer self.allocator.free(key);
                try self.attributes.put(key, runtime_value);
                inserted = true;
            }
        }
    }

    pub fn Get(self: *Self, name: []const u8) !?*anyopaque {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.Get(name);
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        const qualified_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_name);

        if (self.attributes.get(qualified_name)) |value| {
            return value.value;
        }
        return null;
    }

    pub fn Set(self: *Self, ctx: *Context, name: []const u8, value: anytype) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.Set(ctx, name, value);
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        const ValueType = @TypeOf(value);
        const qualified_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_name);

        const attr = self.model.attributes.get(qualified_name) orelse return error.UnknownAttribute;
        if (attr.type_name) |expected_type| {
            if (!std.mem.eql(u8, expected_type, @typeName(ValueType))) {
                return error.AttributeTypeMismatch;
            }
        }

        var new_value = try makeRuntimeAttributeValue(self.allocator, value);
        var value_owned_by_attributes = false;
        var value_released = false;
        errdefer if (!value_owned_by_attributes and !value_released) new_value.deinit(self.allocator);
        var storage_key = qualified_name;
        var owns_storage_key = false;
        if (!self.attributes.contains(qualified_name)) {
            storage_key = try self.allocator.dupe(u8, qualified_name);
            owns_storage_key = true;
        }
        errdefer if (owns_storage_key) self.allocator.free(@constCast(storage_key));
        const attr_entry = try self.attributes.getOrPut(storage_key);
        if (attr_entry.found_existing) {
            if (owns_storage_key) {
                self.allocator.free(@constCast(storage_key));
                owns_storage_key = false;
            }
        }
        if (!attr_entry.found_existing) owns_storage_key = false;
        const attribute_key = attr_entry.key_ptr.*;
        var old_value: ?RuntimeAttributeValue = if (attr_entry.found_existing) attr_entry.value_ptr.* else null;
        const unchanged = attr_entry.found_existing and valuesEqual(ValueType, attr_entry.value_ptr, value);
        var attribute_inserted = !attr_entry.found_existing;
        errdefer if (attribute_inserted and !value_owned_by_attributes) {
            if (self.attributes.fetchRemove(attribute_key)) |removed| {
                self.allocator.free(removed.key);
            }
        };

        if (unchanged) {
            new_value.deinit(self.allocator);
            value_released = true;
            return;
        }

        // Build every fallible event payload before committing the new value
        // into the attribute map. A failed payload allocation therefore leaves
        // the previous runtime value and its change event untouched.
        var change_event = Event.withData(ctx.allocator, attribute_key);
        change_event.kind = ChangeEventKind;
        change_event.source = attribute_key;
        defer change_event.deinit();
        try change_event.putData("new", new_value.value);
        if (old_value) |*old| {
            try change_event.putData("old", old.value);
        }
        var typed_change = try makeRuntimeAttributeValue(self.allocator, AttributeChange{
            .Name = attribute_key,
            .Old = if (old_value) |old| old.value else null,
            .New = new_value.value,
        });
        defer typed_change.deinit(self.allocator);
        try change_event.putData("change", typed_change.value);

        attr_entry.value_ptr.* = new_value;
        value_owned_by_attributes = true;

        _ = self.dispatchResult(ctx, change_event) catch |err| {
            // A reentrant Set may replace this value while dispatching. Only
            // roll back when the map still owns this exact committed value;
            // otherwise the reentrant operation owns the newer state.
            if (self.attributes.getPtr(qualified_name)) |current_value| {
                if (current_value.value == new_value.value) {
                    if (old_value) |old| {
                        current_value.* = old;
                    } else if (self.attributes.fetchRemove(attribute_key)) |removed| {
                        self.allocator.free(removed.key);
                    }
                    attribute_inserted = false;
                    new_value.deinit(self.allocator);
                    value_owned_by_attributes = false;
                    value_released = true;
                } else {
                    attribute_inserted = false;
                    value_owned_by_attributes = false;
                    value_released = true;
                }
            } else {
                attribute_inserted = false;
                value_owned_by_attributes = false;
                value_released = true;
            }
            return err;
        };

        if (old_value) |*old| old.deinit(self.allocator);
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
        _ = try self.processEvent(ctx, error_event);
    }

    pub fn dispatch(self: *Self, ctx: *Context, event: Event) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.dispatch(ctx, event);
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        _ = try self.dispatchResult(ctx, event);
    }

    pub fn Flush(self: *Self, ctx: *Context) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.Flush(ctx);
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        const owner = runtimeOwner(self) orelse return;
        const internal_queue = owner.owned_queue orelse return;
        if (!internal_queue.tryStartProcessing()) return;
        const previous_queue_processing_machine = current_queue_processing_machine;
        current_queue_processing_machine = machine;
        defer current_queue_processing_machine = previous_queue_processing_machine;
        while (true) {
            const queued_event = internal_queue.dequeue() orelse {
                if (internal_queue.finishProcessing()) continue;
                break;
            };
            var processed_event = queued_event;
            defer if (processed_event.owns_name or processed_event.owns_id or processed_event.owns_source or processed_event.owns_target or processed_event.owns_data_keys or processed_event.owns_metadata_keys) processed_event.deinit();
            _ = machine.processRegularEvent(ctx, processed_event) catch |err| {
                internal_queue.stopProcessing();
                return err;
            };
            if (machine.stopped) {
                internal_queue.clear();
                break;
            }
        }
    }

    pub fn Dispatch(self: *Self, ctx: *Context, event: Event) !void {
        try self.dispatch(ctx, event);
    }

    pub fn Call(self: *Self, ctx: *Context, name: []const u8) !void {
        try self.callWithData(ctx, name, null);
    }

    pub fn call(self: *Self, ctx: *Context, name: []const u8) !void {
        try self.callWithData(ctx, name, null);
    }

    /// Call an operation and expose an optional opaque payload to its on-call
    /// event as event data under the empty path.
    pub fn CallWithData(self: *Self, ctx: *Context, name: []const u8, data: ?*anyopaque) !void {
        try self.callWithData(ctx, name, data);
    }

    pub fn callWithData(self: *Self, ctx: *Context, name: []const u8, data: ?*anyopaque) !void {
        var values: [1]*anyopaque = undefined;
        const value_slice: []const *anyopaque = if (data) |payload| blk: {
            values[0] = payload;
            break :blk values[0..];
        } else &[_]*anyopaque{};
        try self.callWithValues(ctx, name, value_slice);
    }

    /// Call an operation with a tuple of borrowed pointer arguments.
    /// Values are exposed through CallData.ValueAs(T) in the on-call event.
    pub fn CallWithArgs(self: *Self, ctx: *Context, name: []const u8, args: anytype) !void {
        try self.callWithArgs(ctx, name, args);
    }

    pub fn callWithArgs(self: *Self, ctx: *Context, name: []const u8, args: anytype) !void {
        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);
        if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
            @compileError("CallWithArgs arguments must be a tuple of pointers");
        }
        const fields = std.meta.fields(ArgsType);
        var values = try self.allocator.alloc(*anyopaque, fields.len);
        defer self.allocator.free(values);
        inline for (fields, 0..) |_, index| {
            const ValueType = @TypeOf(args[index]);
            if (@typeInfo(ValueType) != .pointer or @typeInfo(ValueType).pointer.size != .one) {
                @compileError("CallWithArgs arguments must be single-item pointers");
            }
            values[index] = @ptrCast(@constCast(args[index]));
        }
        try self.callWithValues(ctx, name, values);
    }

    fn callWithValues(self: *Self, ctx: *Context, name: []const u8, values: []const *anyopaque) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.callWithValues(ctx, name, values);
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        if (machine.stopped) return error.MachineStopped;
        const was_done = ctx.is_done();
        const qualified_operation_name = try qualifyModelMemberName(self.allocator, self.model.name, name);
        defer self.allocator.free(qualified_operation_name);

        const event_name = try callEventName(ctx.allocator, qualified_operation_name);
        defer ctx.allocator.free(event_name);

        var call_event = Event.withData(ctx.allocator, event_name);
        call_event.kind = CallEventKind;
        call_event.source = try ctx.allocator.dupe(u8, qualified_operation_name);
        call_event.owns_source = true;
        defer call_event.deinit();
        if (values.len > 0) try call_event.putData("", values[0]);

        if (getOperation(self.model, qualified_operation_name)) |operation_element| {
            var call_data = try makeRuntimeCallData(self.allocator, operation_element.element.qualified_name, values);
            defer call_data.deinit(self.allocator);
            try call_event.putData("call", call_data.value);

            const operation_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(operation_element.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            _ = operationDepth(self).fetchAdd(1, .acq_rel);
            self.executeWithErrorHandling(operation_fn, ctx, instance, call_event, "operation") catch |err| {
                _ = operationDepth(self).fetchSub(1, .acq_rel);
                try self.dispatchErrorEvent(ctx, err, "operation_execution");
                return;
            };
            _ = operationDepth(self).fetchSub(1, .acq_rel);
        } else return error.UnknownOperation;

        if (!was_done and ctx.is_done()) return;
        _ = try self.dispatchResult(ctx, call_event);
        if (transitionDepth(self).load(.acquire) == 0 and operationDepth(self).load(.acquire) == 0) {
            if (runtimeOwner(self)) |owner| {
                if (owner.owned_queue) |internal_queue| {
                    while (true) {
                        const queued_event = internal_queue.dequeue() orelse {
                            if (internal_queue.finishProcessing()) continue;
                            break;
                        };
                        var processed_event = queued_event;
                        defer if (processed_event.owns_name or processed_event.owns_id or processed_event.owns_source or processed_event.owns_target or processed_event.owns_data_keys or processed_event.owns_metadata_keys) processed_event.deinit();
                        _ = self.processRegularEvent(ctx, processed_event) catch |err| {
                            internal_queue.stopProcessing();
                            return err;
                        };
                    }
                }
            }
        }
    }

    fn dispatchResult(self: *Self, ctx: *Context, event: Event) anyerror!DispatchStatus {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.dispatchResult(ctx, event);
        if (self.stopped and current_lifecycle_machine != self) return error.MachineStopped;

        if (isKind(event.kind, CompletionEventKind)) {
            _ = try self.processEvent(ctx, event);
            return dispatch_status_processed;
        }

        if (self.regular_queue) |queue| {
            if (runtimeOwner(self)) |owner| {
                if (owner.owned_queue) |internal_queue| {
                    if (queue == &internal_queue.runtime_queue) {
                        const must_queue = transitionDepth(self).load(.acquire) > 0 or current_activity_context == ctx or
                            (current_activity_machine != null and current_activity_machine.? == @as(*anyopaque, @ptrCast(machine))) or
                            (std.mem.startsWith(u8, event.name, "hsm_call:") and operationDepth(self).load(.acquire) > 0);
                        const should_process = internal_queue.startOrEnqueue(event) catch |err| {
                            try self.dispatchErrorEvent(ctx, err, "queue_push");
                            return dispatch_status_processed;
                        };
                        if (!should_process) return dispatch_status_processed;

                        if (must_queue) {
                            var enqueued_event = cloneEventForQueue(ctx.allocator, event) catch |err| {
                                internal_queue.stopProcessing();
                                try self.dispatchErrorEvent(ctx, err, "queue_push");
                                return dispatch_status_processed;
                            };
                            _ = internal_queue.enqueue(enqueued_event) catch |err| {
                                enqueued_event.deinit();
                                internal_queue.stopProcessing();
                                try self.dispatchErrorEvent(ctx, err, "queue_push");
                                return dispatch_status_processed;
                            };
                            internal_queue.stopProcessing();
                            return dispatch_status_processed;
                        }

                        const previous_queue_processing_machine = current_queue_processing_machine;
                        current_queue_processing_machine = machine;
                        defer current_queue_processing_machine = previous_queue_processing_machine;
                        var result = dispatch_status_processed;
                        const direct_result = self.processRegularEvent(ctx, event) catch |err| {
                            internal_queue.stopProcessing();
                            return err;
                        };
                        if (direct_result == dispatch_status_deferred) {
                            result = dispatch_status_deferred;
                        }
                        if (self.stopped) {
                            internal_queue.clear();
                            return result;
                        }
                        while (true) {
                            const queued_event_value = internal_queue.dequeue() orelse {
                                if (internal_queue.finishProcessing()) continue;
                                break;
                            };
                            var processed_event = queued_event_value;
                            defer if (processed_event.owns_name or processed_event.owns_id or processed_event.owns_source or processed_event.owns_target or processed_event.owns_data_keys or processed_event.owns_metadata_keys) processed_event.deinit();
                            const item_result = self.processRegularEvent(ctx, processed_event) catch |err| {
                                internal_queue.stopProcessing();
                                return err;
                            };
                            if (item_result == dispatch_status_deferred) {
                                result = dispatch_status_deferred;
                            }
                            if (self.stopped) {
                                internal_queue.clear();
                                break;
                            }
                        }
                        return result;
                    }
                }
            }

            const must_queue = transitionDepth(self).load(.acquire) > 0 or current_activity_context == ctx or
                (current_activity_machine != null and current_activity_machine.? == @as(*anyopaque, @ptrCast(machine))) or
                (std.mem.startsWith(u8, event.name, "hsm_call:") and operationDepth(self).load(.acquire) > 0);
            var enqueued_event = try cloneEventForQueue(ctx.allocator, event);
            queue.Push(ctx, enqueued_event) catch |err| switch (err) {
                error.QueueFull => {
                    enqueued_event.deinit();
                    try self.dispatchErrorEvent(ctx, err, "queue_push");
                    return dispatch_status_queue_full;
                },
                else => {
                    enqueued_event.deinit();
                    try self.dispatchErrorEvent(ctx, err, "queue_push");
                    return dispatch_status_processed;
                },
            };
            if (must_queue) return dispatch_status_processed;

            var result = dispatch_status_processed;
            var pop_error_seen = false;
            while (true) {
                const maybe_queued_event = queue.Pop(ctx) catch |err| {
                    if (pop_error_seen) break;
                    pop_error_seen = true;
                    try self.dispatchErrorEvent(ctx, err, "queue_pop");
                    continue;
                };
                const queued_event = maybe_queued_event orelse break;
                var processed_event = queued_event;
                defer if (processed_event.owns_name or processed_event.owns_id or processed_event.owns_source or processed_event.owns_target or processed_event.owns_data_keys or processed_event.owns_metadata_keys) processed_event.deinit();
                const item_result = try self.processRegularEvent(ctx, processed_event);
                if (item_result == dispatch_status_deferred) {
                    result = dispatch_status_deferred;
                }
            }
            return result;
        }

        return try self.processRegularEvent(ctx, event);
    }

    fn processRegularEvent(self: *Self, ctx: *Context, event: Event) anyerror!DispatchStatus {
        if (self.stopped) return dispatch_status_processed;

        const is_qualified_timer_event = event.kind == TimeEventKind and
            (std.mem.startsWith(u8, event.name, "_timeout:") or
                std.mem.startsWith(u8, event.name, "_periodic:"));

        if (is_qualified_timer_event) {
            _ = try self.processEvent(ctx, event);
        } else {
            // Local handlers get first refusal. Only an unhandled local event can
            // be deferred; parent handlers are consulted afterward.
            const local_handled = try self.processLocalEvent(ctx, event);
            if (!local_handled) {
                if (self.model.deferred_map.get(self.current_state)) |event_map| {
                    if (event_map.get(event.name)) |is_deferred| {
                        if (is_deferred) {
                            var deferred_event = try cloneEventForQueue(self.allocator, event);
                            errdefer deferred_event.deinit();
                            try self.deferred_queue.enqueue(deferred_event);
                            return dispatch_status_deferred;
                        }
                    }
                }

                _ = try self.processEventAfterLocal(ctx, event);
            }
        }

        // After processing, check deferred queue for events that can now be processed
        if (!self.deferred_queue.isEmpty()) try self.processDeferredEvents(ctx);

        return dispatch_status_processed;
    }

    pub fn TakeSnapshot(self: *Self) !Snapshot {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.TakeSnapshot();
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
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

        const transitions = try self.snapshotTransitions();
        errdefer {
            for (transitions) |*transition_snapshot| {
                transition_snapshot.deinit(self.allocator);
            }
            self.allocator.free(transitions);
        }

        const snapshot_id = if (self.runtime_id) |id| try self.allocator.dupe(u8, id) else null;
        errdefer if (snapshot_id) |id| self.allocator.free(id);
        const snapshot_name = try self.allocator.dupe(u8, self.QualifiedName());
        errdefer self.allocator.free(snapshot_name);
        const snapshot_state = try self.allocator.dupe(u8, self.current_state);
        errdefer self.allocator.free(snapshot_state);
        const queue_len = try self.snapshotQueueLen();

        return Snapshot{
            .ID = snapshot_id,
            .QualifiedName = snapshot_name,
            .State = snapshot_state,
            .QueueLen = queue_len,
            .Attributes = attributes,
            .Events = events,
            .Transitions = transitions,
            .allocator = self.allocator,
        };
    }

    fn snapshotTransitions(self: *Self) ![]TransitionSnapshot {
        var transitions = try std.ArrayList(TransitionSnapshot).initCapacity(self.allocator, 0);
        errdefer {
            for (transitions.items) |*transition_snapshot| {
                transition_snapshot.deinit(self.allocator);
            }
            transitions.deinit(self.allocator);
        }

        var indexes = std.StringHashMap(usize).init(self.allocator);
        defer indexes.deinit();

        if (self.model.transition_map.get(self.current_state)) |transitions_by_event| {
            var event_iterator = transitions_by_event.iterator();
            while (event_iterator.next()) |event_entry| {
                for (event_entry.value_ptr.*) |transition_name| {
                    const transition_element = getTransition(self.model, transition_name) orelse continue;
                    if (transition_element.event_name == null) continue;

                    if (indexes.get(transition_name)) |index| {
                        const event_copy = try self.allocator.dupe(u8, event_entry.key_ptr.*);
                        const current_events = transitions.items[index].Events;
                        const grown_events = self.allocator.realloc(current_events, current_events.len + 1) catch |err| {
                            self.allocator.free(event_copy);
                            return err;
                        };
                        grown_events[current_events.len] = event_copy;
                        transitions.items[index].Events = grown_events;
                        continue;
                    }

                    var snapshot = blk: {
                        const name = try self.allocator.dupe(u8, transition_element.element.qualified_name);
                        errdefer self.allocator.free(name);
                        const source_name = try self.allocator.dupe(u8, transition_element.source);
                        errdefer self.allocator.free(source_name);
                        const target_name_copy = if (transition_element.target) |target_name| try self.allocator.dupe(u8, target_name) else null;
                        errdefer if (target_name_copy) |target_name| self.allocator.free(target_name);
                        const event_name = try self.allocator.dupe(u8, event_entry.key_ptr.*);
                        errdefer self.allocator.free(event_name);
                        const event_names = try self.allocator.alloc([]const u8, 1);
                        event_names[0] = event_name;
                        break :blk TransitionSnapshot{
                            .Name = name,
                            .Kind = transition_element.kind,
                            .Source = source_name,
                            .Target = target_name_copy,
                            .Events = event_names,
                            .Guard = transition_element.guard != null,
                        };
                    };
                    indexes.put(transition_name, transitions.items.len) catch |err| {
                        snapshot.deinit(self.allocator);
                        return err;
                    };
                    transitions.append(self.allocator, snapshot) catch |err| {
                        _ = indexes.remove(transition_name);
                        snapshot.deinit(self.allocator);
                        return err;
                    };
                }
            }
        }

        var member_iterator = self.model.members.iterator();
        while (member_iterator.next()) |member_entry| {
            if (member_entry.value_ptr.*.kind != .transition) continue;
            const timer_transition = @as(*TransitionElement, @ptrCast(@alignCast(member_entry.value_ptr.*)));
            if (timer_transition.timer_fn == null or !stateMatchesOrIsDescendant(self.current_state, timer_transition.source)) continue;

            const timer_name = if (timer_transition.timer_kind == .at)
                try std.fmt.allocPrint(self.allocator, "{s}/timepoint", .{timer_transition.element.qualified_name})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/duration", .{timer_transition.element.qualified_name});
            var timer_name_owned = true;
            errdefer if (timer_name_owned) self.allocator.free(timer_name);

            if (indexes.get(timer_transition.element.qualified_name)) |index| {
                const current_events = transitions.items[index].Events;
                const grown_events = self.allocator.realloc(current_events, current_events.len + 1) catch |err| {
                    return err;
                };
                grown_events[current_events.len] = timer_name;
                transitions.items[index].Events = grown_events;
                transitions.items[index].Guard = true;
                timer_name_owned = false;
                continue;
            }

            const name = try self.allocator.dupe(u8, timer_transition.element.qualified_name);
            errdefer self.allocator.free(name);
            const source_name = try self.allocator.dupe(u8, timer_transition.source);
            errdefer self.allocator.free(source_name);
            const target_name_copy = if (timer_transition.target) |target_name| try self.allocator.dupe(u8, target_name) else null;
            errdefer if (target_name_copy) |target_name| self.allocator.free(target_name);
            const event_names = try self.allocator.alloc([]const u8, 1);
            event_names[0] = timer_name;
            const snapshot = TransitionSnapshot{
                .Name = name,
                .Kind = timer_transition.kind,
                .Source = source_name,
                .Target = target_name_copy,
                .Events = event_names,
                .Guard = true,
            };
            timer_name_owned = false;
            indexes.put(timer_transition.element.qualified_name, transitions.items.len) catch |err| {
                var owned_snapshot = snapshot;
                owned_snapshot.deinit(self.allocator);
                return err;
            };
            transitions.append(self.allocator, snapshot) catch |err| {
                _ = indexes.remove(timer_transition.element.qualified_name);
                var owned_snapshot = snapshot;
                owned_snapshot.deinit(self.allocator);
                return err;
            };
        }

        return try transitions.toOwnedSlice(self.allocator);
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

                    const name = if (std.mem.startsWith(u8, event_entry.key_ptr.*, "hsm_call:"))
                        try self.allocator.dupe(u8, event_entry.key_ptr.*["hsm_call:".len..])
                    else
                        try self.allocator.dupe(u8, event_entry.key_ptr.*);
                    errdefer self.allocator.free(name);
                    const target_snapshot = if (trans.target) |target_name| try self.allocator.dupe(u8, target_name) else null;
                    errdefer if (target_snapshot) |target_name| self.allocator.free(target_name);

                    try events.append(self.allocator, EventDetail{
                        .Name = name,
                        .Kind = if (std.mem.startsWith(u8, event_entry.key_ptr.*, "hsm_call:"))
                            CallEventKind
                        else if (self.model.attributes.contains(event_entry.key_ptr.*))
                            ChangeEventKind
                        else
                            EventKind,
                        .Target = target_snapshot,
                        .Guard = trans.guard != null,
                        .Schema = null,
                    });
                }
            }
        }

        var member_iter = self.model.members.iterator();
        while (member_iter.next()) |member_entry| {
            if (member_entry.value_ptr.*.kind != .transition) continue;
            const trans = @as(*TransitionElement, @ptrCast(@alignCast(member_entry.value_ptr.*)));
            if (trans.timer_fn == null or !stateMatchesOrIsDescendant(self.current_state, trans.source)) continue;

            const suffix = if (trans.timer_kind == .at) "/timepoint" else "/duration";
            const name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ trans.element.qualified_name, suffix });
            errdefer self.allocator.free(name);
            const target_snapshot = if (trans.target) |target_name| try self.allocator.dupe(u8, target_name) else null;
            errdefer if (target_snapshot) |target_name| self.allocator.free(target_name);

            try events.append(self.allocator, EventDetail{
                .Name = name,
                .Kind = TimeEventKind,
                .Target = target_snapshot,
                .Guard = true,
                .Schema = null,
            });
        }

        return try events.toOwnedSlice(self.allocator);
    }

    fn processTransitionNames(self: *Self, ctx: *Context, event: Event, transition_names: []const []const u8) !bool {
        const was_done = ctx.is_done();
        for (transition_names) |transition_name| {
            const trans = getTransition(self.model, transition_name) orelse continue;
            const matches = self.matchesTransition(trans, event, ctx);
            if (!was_done and ctx.is_done()) return true;
            if (matches) {
                try self.executeTransition(trans, event, ctx);
                return true;
            }
        }
        return false;
    }

    fn processLocalEvent(self: *Self, ctx: *Context, event: Event) !bool {
        const was_done = ctx.is_done();
        const event_map = self.model.transition_map.get(self.current_state) orelse return false;
        const transition_names = event_map.get(event.name) orelse return false;
        const prioritize_model_root = std.mem.startsWith(u8, event.name, "hsm_exit:");
        const pass_count: usize = if (prioritize_model_root) 2 else 1;
        var pass: usize = 0;
        while (pass < pass_count) : (pass += 1) {
            for (transition_names) |transition_name| {
                const trans = getTransition(self.model, transition_name) orelse continue;
                const declaration_owner = trans.element.owner();
                const owner_is_model_root = declaration_owner.len == self.model.name.len + 1 and
                    declaration_owner.len > 0 and declaration_owner[0] == '/' and
                    std.mem.eql(u8, declaration_owner[1..], self.model.name);
                const owner_is_ancestor = !std.mem.eql(u8, declaration_owner, self.current_state) and
                    stateMatchesOrIsDescendant(self.current_state, declaration_owner);
                const owner_has_priority = owner_is_ancestor and !owner_is_model_root;
                const owner_is_submachine = if (self.model.members.get(declaration_owner)) |owner_element|
                    owner_element.kind == .submachine
                else
                    false;
                const current_parent_is_submachine = if (std.fs.path.dirname(self.current_state)) |current_parent|
                    if (self.model.members.get(current_parent)) |current_parent_element|
                        current_parent_element.kind == .submachine
                    else
                        false
                else
                    false;
                const exit_point_priority = (std.mem.eql(u8, declaration_owner, self.current_state) and
                    !current_parent_is_submachine) or
                    (owner_has_priority and owner_is_submachine);
                // Ordinary ancestor-owned transitions belong to the bubbling
                // phase, after the current state has had a chance to defer
                // the event. Exit-point events use the specialized ordering
                // below because their synthetic boundary aliases are indexed
                // into the active-state bucket.
                if (!prioritize_model_root and !std.mem.eql(u8, declaration_owner, self.current_state) and !owner_is_model_root) continue;
                if (prioritize_model_root and exit_point_priority != (pass == 0)) continue;
                if (!std.mem.eql(u8, trans.source, self.current_state) or
                    (!std.mem.eql(u8, declaration_owner, self.current_state) and
                        !owner_has_priority and !owner_is_model_root)) continue;
                const matches = self.matchesTransition(trans, event, ctx);
                if (!was_done and ctx.is_done()) return true;
                if (matches) {
                    try self.executeTransition(trans, event, ctx);
                    return true;
                }
            }
        }
        return false;
    }

    fn processLocalWildcardEvent(self: *Self, ctx: *Context, event: Event) !bool {
        const was_done = ctx.is_done();
        const event_map = self.model.transition_map.get(self.current_state) orelse return false;
        const transition_names = event_map.get(AnyEvent) orelse return false;
        for (transition_names) |transition_name| {
            const trans = getTransition(self.model, transition_name) orelse continue;
            const declaration_owner = trans.element.owner();
            const owner_is_model_root = declaration_owner.len == self.model.name.len + 1 and
                declaration_owner.len > 0 and declaration_owner[0] == '/' and
                std.mem.eql(u8, declaration_owner[1..], self.model.name);
            if (!std.mem.eql(u8, trans.source, self.current_state) or
                (!std.mem.eql(u8, declaration_owner, self.current_state) and !owner_is_model_root)) continue;
            const matches = self.matchesTransition(trans, event, ctx);
            if (!was_done and ctx.is_done()) return true;
            if (matches) {
                try self.executeTransition(trans, event, ctx);
                return true;
            }
        }
        return false;
    }

    fn processAncestorTransitionNames(
        self: *Self,
        ctx: *Context,
        event: Event,
        transition_names: []const []const u8,
    ) !bool {
        const was_done = ctx.is_done();
        for (transition_names) |transition_name| {
            const trans = getTransition(self.model, transition_name) orelse continue;
            // Local transitions were already tested by processLocalEvent. Use
            // the declaration owner rather than the effective source so a
            // source-qualified transition declared on an ancestor can still
            // target the active state itself.
            if (std.mem.startsWith(u8, event.name, "hsm_exit:") and
                std.mem.eql(u8, trans.source, self.current_state)) continue;
            if (std.mem.eql(u8, trans.element.owner(), self.current_state) and
                std.mem.eql(u8, trans.source, self.current_state)) continue;
            const source_path = trans.source;
            const source_is_current_or_ancestor = std.mem.eql(u8, source_path, self.current_state) or
                (source_path.len < self.current_state.len and
                    std.mem.startsWith(u8, self.current_state, source_path) and
                    self.current_state[source_path.len] == '/');
            if (!source_is_current_or_ancestor) continue;
            const matches = self.matchesTransition(trans, event, ctx);
            if (!was_done and ctx.is_done()) return true;
            if (matches) {
                try self.executeTransition(trans, event, ctx);
                return true;
            }
        }
        return false;
    }

    fn processAncestorEvent(self: *Self, ctx: *Context, event: Event) !bool {
        const was_done = ctx.is_done();
        if (self.model.transition_map.get(self.current_state)) |event_map| {
            if (event_map.get(event.name)) |transition_names| {
                if (try self.processAncestorTransitionNames(ctx, event, transition_names)) return true;
            }
        }
        if (!was_done and ctx.is_done()) return true;
        return false;
    }

    fn processEventAfterLocal(self: *Self, ctx: *Context, event: Event) !bool {
        if (try self.processAncestorEvent(ctx, event)) return true;
        if (try self.processLocalWildcardEvent(ctx, event)) return true;
        if (self.model.transition_map.get(self.current_state)) |event_map| {
            if (event_map.get(AnyEvent)) |transition_names| {
                if (try self.processAncestorTransitionNames(ctx, event, transition_names)) return true;
            }
        }
        if (try self.processTimerEventInState(self.current_state, event, ctx)) return true;

        // Defensive fallback for timer events only; ordinary named events use
        // the expanded current-state transition bucket above.
        if (std.mem.startsWith(u8, event.name, "_timeout") or std.mem.startsWith(u8, event.name, "_periodic")) {
            return try self.bubbleTimerEvent(event, ctx);
        }
        return false;
    }

    fn processEvent(self: *Self, ctx: *Context, event: Event) !bool {
        if (event.kind == TimeEventKind and
            (std.mem.startsWith(u8, event.name, "_timeout:") or
                std.mem.startsWith(u8, event.name, "_periodic:")))
        {
            if (try self.processTimerEventInState(self.current_state, event, ctx)) return true;
            return try self.bubbleTimerEvent(event, ctx);
        }
        if (try self.processLocalEvent(ctx, event)) return true;
        return try self.processEventAfterLocal(ctx, event);
    }

    fn timerEventMatches(trans: *const TransitionElement, event_name: []const u8) bool {
        if (trans.timer_fn == null) return false;
        return switch (trans.timer_kind) {
            .after, .at => std.mem.startsWith(u8, event_name, "_timeout"),
            .every => std.mem.startsWith(u8, event_name, "_periodic"),
        };
    }

    fn processTimerEventInState(self: *Self, state_name: []const u8, event: Event, ctx: *Context) !bool {
        if (event.kind != TimeEventKind) return false;
        const was_done = ctx.is_done();
        const generated_transition_name = if (std.mem.startsWith(u8, event.name, "_timeout:"))
            event.name["_timeout:".len..]
        else if (std.mem.startsWith(u8, event.name, "_periodic:"))
            event.name["_periodic:".len..]
        else
            null;

        if (generated_transition_name) |generated_name| {
            const event_map = self.model.transition_map.get(state_name) orelse return false;
            const transition_names = event_map.get(event.name) orelse return false;
            for (transition_names) |transition_name| {
                const trans = getTransition(self.model, transition_name) orelse continue;
                if (!std.mem.eql(u8, trans.source, state_name)) continue;
                if (!timerEventMatches(trans, event.name)) continue;
                if (!std.mem.eql(u8, generated_name, trans.element.qualified_name)) continue;
                const matches = self.matchesTransition(trans, event, ctx);
                if (!was_done and ctx.is_done()) return true;
                if (!matches) continue;
                try self.executeTransition(trans, event, ctx);
                return true;
            }
            return false;
        }

        const state_element = getState(self.model, state_name) orelse return false;
        var match_index: usize = 0;
        for (state_element.transitions) |transition_name| {
            const trans = getTransition(self.model, transition_name) orelse continue;
            if (!timerEventMatches(trans, event.name)) continue;
            defer match_index += 1;
            const suffix = if (std.mem.startsWith(u8, event.name, "_timeout_"))
                event.name["_timeout_".len..]
            else if (std.mem.startsWith(u8, event.name, "_periodic_"))
                event.name["_periodic_".len..]
            else
                "";
            if (suffix.len > 0) {
                if ((std.mem.eql(u8, suffix, "fast") or std.mem.eql(u8, suffix, "short")) and match_index != 0) continue;
                if ((std.mem.eql(u8, suffix, "slow") or std.mem.eql(u8, suffix, "medium")) and match_index != 1) continue;
                if (std.mem.eql(u8, suffix, "long") and match_index != 2) continue;
                const source_name = std.fs.path.basename(trans.source);
                if (!std.mem.eql(u8, suffix, "fast") and !std.mem.eql(u8, suffix, "short") and
                    !std.mem.eql(u8, suffix, "slow") and !std.mem.eql(u8, suffix, "medium") and
                    !std.mem.eql(u8, suffix, "long") and !std.mem.eql(u8, suffix, source_name)) continue;
            }
            const matches = self.matchesTransition(trans, event, ctx);
            if (!was_done and ctx.is_done()) return true;
            if (!matches) continue;
            try self.executeTransition(trans, event, ctx);
            return true;
        }
        return false;
    }

    fn processDeferredEvents(self: *Self, ctx: *Context) anyerror!void {
        var processed_any = true;
        while (processed_any and !self.deferred_queue.isEmpty()) {
            processed_any = false;

            // Visit the current queue exactly once, rotating still-deferred events
            // to the tail so eligible events replay in FIFO order without shifting.
            const queued_count = self.deferred_queue.len();
            var i: usize = 0;
            while (i < queued_count) : (i += 1) {
                var deferred_event = self.deferred_queue.dequeue() orelse break;

                // Check if this event is still deferred in current state
                var still_deferred = false;
                if (self.model.deferred_map.get(self.current_state)) |event_map| {
                    if (event_map.get(deferred_event.name)) |is_deferred| {
                        still_deferred = is_deferred;
                    }
                }

                if (!still_deferred) {
                    // Event is no longer deferred, process it
                    defer deferred_event.deinit();
                    _ = try self.dispatchResult(ctx, deferred_event);
                    processed_any = true;
                } else {
                    self.deferred_queue.enqueue(deferred_event) catch |err| {
                        deferred_event.deinit();
                        return err;
                    };
                }
            }
        }
    }

    fn matchesTransition(self: *const Self, trans: *TransitionElement, event: Event, ctx: *Context) bool {
        // Check event name match
        if (trans.event_name) |event_name| {
            const exact_match = std.mem.eql(u8, event_name, AnyEvent) or std.mem.eql(u8, event_name, event.name);
            const exit_alias_match = if (!exact_match and
                std.mem.startsWith(u8, event_name, "hsm_exit:") and
                std.mem.startsWith(u8, event.name, "hsm_exit:"))
            blk: {
                const expected_separator = std.mem.lastIndexOfScalar(u8, event_name, '/');
                const actual_separator = std.mem.lastIndexOfScalar(u8, event.name, '/');
                if (expected_separator == null or actual_separator == null) break :blk false;
                const expected_point = event_name[expected_separator.? + 1 ..];
                const actual_point = event.name[actual_separator.? + 1 ..];
                const actual_boundary = event.name["hsm_exit:".len..actual_separator.?];
                break :blk std.mem.eql(u8, expected_point, actual_point) and
                    stateMatchesOrIsDescendant(actual_boundary, trans.source);
            } else false;
            if (!exact_match and !exit_alias_match) {
                return false;
            }
        }

        // Check guard conditions. Multiple guards on one transition are ANDed.
        for (trans.guards) |guard_name| {
            const guard_behavior = getBehavior(self.model, guard_name) orelse return false;
            const guard_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) bool = @ptrCast(@alignCast(guard_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            const guard_result = blk: {
                _ = transitionDepth(self).fetchAdd(1, .acq_rel);
                defer _ = transitionDepth(self).fetchSub(1, .acq_rel);
                break :blk guard_fn(ctx, instance, event);
            };
            if (!guard_result) {
                return false;
            }
        }

        // Runtime-built models use the legacy single-guard slot.
        if (trans.guards.len == 0) {
            if (trans.guard) |guard_name| {
                const guard_behavior = getBehavior(self.model, guard_name) orelse return false;
                const guard_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) bool = @ptrCast(@alignCast(guard_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                const guard_result = blk: {
                    _ = transitionDepth(self).fetchAdd(1, .acq_rel);
                    defer _ = transitionDepth(self).fetchSub(1, .acq_rel);
                    break :blk guard_fn(ctx, instance, event);
                };
                if (!guard_result) return false;
            }
        }

        return true;
    }

    fn processCompletionTransitions(self: *Self, ctx: *Context, event: Event) anyerror!void {
        const was_done = ctx.is_done();
        var depth: usize = 0;
        // A valid completion/choice chain may be deeper than a fixed sentinel;
        // the model member count is a finite cycle guard without rejecting a
        // well-formed chain solely because of its hierarchy depth.
        const max_completion_steps = self.model.members.count() + 1;
        while (depth < max_completion_steps) : (depth += 1) {
            const element = self.model.members.get(self.current_state) orelse return;
            if (element.kind == .final) {
                const parent_path = std.fs.path.dirname(self.current_state) orelse return;
                const parent_events = self.model.transition_map.get(parent_path) orelse return;
                const transition_names = parent_events.get(FinalEventName) orelse return;
                var completion_event = Event.completion(ctx.allocator, FinalEventName);
                defer completion_event.deinit();
                for (transition_names) |transition_name| {
                    const trans = getTransition(self.model, transition_name) orelse continue;
                    if (!std.mem.eql(u8, trans.source, parent_path)) continue;
                    const matches = self.matchesTransition(trans, completion_event, ctx);
                    if (!was_done and ctx.is_done()) return;
                    if (matches) {
                        try self.executeTransition(trans, completion_event, ctx);
                        return;
                    }
                }
                return;
            }
            if (element.kind != .choice) return;

            const state_element: *StateElement = @ptrCast(@alignCast(element));
            for (state_element.transitions) |transition_name| {
                const trans = getTransition(self.model, transition_name) orelse continue;
                if (trans.event_name != null) continue;
                const matches = self.matchesTransition(trans, event, ctx);
                if (!was_done and ctx.is_done()) return;
                if (matches) {
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
        _ = transitionDepth(self).fetchAdd(1, .acq_rel);
        defer _ = transitionDepth(self).fetchSub(1, .acq_rel);
        const was_done = ctx.is_done();
        const previous_state = self.current_state;

        if (trans.event_name != null or (trans.timer_kind == .every and trans.target == null)) {
            if (trans.timer_fn) |timer_fn_name| {
                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse return;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                _ = timer_fn(ctx, instance, event);
                if (!was_done and ctx.is_done()) return;
            }
        }

        // Handle internal transitions without leaving the active state.
        if (trans.kind == InternalKind or trans.target == null) {
            // Internal transition - only execute effects
            for (trans.effects) |effect_name| {
                const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                self.executeWithErrorHandling(effect_fn, ctx, instance, event, "effect") catch |err| {
                    try self.dispatchErrorEvent(ctx, err, "effect_execution");
                    return;
                };
                if (!was_done and ctx.is_done()) return;
            }
            return;
        }

        // External transition - paths are prepared during model construction.
        if (trans.paths.get(self.current_state)) |paths| {
            const target_is_choice = if (trans.target) |target_name|
                if (self.model.members.get(target_name)) |target_element| target_element.kind == .choice else false
            else
                false;
            const target_is_history = if (trans.target) |target_name|
                if (self.model.members.get(target_name)) |target_element| target_element.kind == .history else false
            else
                false;
            // Exit states in reverse order
            var i = paths.exit.len;
            while (i > 0) {
                i -= 1;
                try self.exitState(paths.exit[i], event, ctx, !target_is_history);
                if (!was_done and ctx.is_done()) {
                    self.current_state = previous_state;
                    return;
                }
            }

            // Execute transition effects
            for (trans.effects) |effect_name| {
                const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                effect_fn(ctx, instance, event);
                if (!was_done and ctx.is_done()) {
                    self.current_state = previous_state;
                    return;
                }
            }

            // Enter states in forward order
            const effective_source_self_transition = trans.kind == SelfKind or
                (trans.target != null and std.mem.eql(u8, trans.source, trans.target.?));
            const target_is_active_ancestor = trans.target != null and stateMatchesOrIsDescendant(self.current_state, trans.target.?);
            const target_has_initial = if (trans.target) |target_name| blk: {
                const target_element = self.model.members.get(target_name) orelse break :blk false;
                if (target_element.kind != .state and target_element.kind != .submachine and target_element.kind != .model) break :blk false;
                break :blk @as(*StateElement, @ptrCast(@alignCast(target_element))).initial_transition != null;
            } else false;
            for (paths.enter, 0..) |state_name, idx| {
                // Only follow initial transitions for the final target state
                const is_target = (idx == paths.enter.len - 1) and trans.target != null and
                    std.mem.eql(u8, state_name, trans.target.?) and
                    (!target_is_active_ancestor or effective_source_self_transition);
                const entered = try self.enterState(state_name, event, ctx, is_target);
                if (!entered) {
                    self.current_state = previous_state;
                    return;
                }
            }

            // Update current state to target (this may have been changed by initial transitions)
            if (trans.target) |target_name| {
                const target_element = self.model.members.get(target_name);
                const target_is_pseudostate = target_element != null and
                    (target_element.?.kind == .history or target_element.?.kind == .choice or
                        target_element.?.kind == .entry_point or target_element.?.kind == .exit_point);
                const followed_target_initial = target_has_initial and
                    (!target_is_active_ancestor or effective_source_self_transition);
                if (target_is_choice or (!target_is_pseudostate and
                    (target_is_active_ancestor or !target_has_initial) and !followed_target_initial))
                {
                    self.current_state = canonicalStateName(self.model, target_name);
                }
            }

            try self.processCompletionTransitions(ctx, event);
            if (target_is_choice and !was_done and ctx.is_done()) {
                self.current_state = previous_state;
                return;
            }
        } else {
            return error.NoTransitionPaths;
        }
    }

    fn bubbleTimerEvent(self: *Self, event: Event, ctx: *Context) !bool {
        // Timer events are generated for the state that owns the timer, so a
        // defensive parent walk remains necessary when the active state is a
        // descendant of that owner. Ordinary named events are fully expanded
        // into transition_map at build time and never reach this path.
        var current_path = self.current_state;
        while (current_path.len > 1) {
            const parent_path = std.fs.path.dirname(current_path) orelse break;
            if (try self.processTimerEventInState(parent_path, event, ctx)) return true;
            current_path = parent_path;
        }
        return false;
    }

    fn exitState(self: *Self, state_name: []const u8, event: Event, ctx: *Context, record_history: bool) !void {
        const was_done = ctx.is_done();
        const element = self.model.members.get(state_name) orelse return;

        if (element.kind == .submachine) {
            const submachine_state: *StateElement = @ptrCast(@alignCast(element));
            if (submachine_state.deferred.len == 0 and !std.mem.startsWith(u8, event.name, "hsm_exit:")) {
                while (self.deferred_queue.dequeue()) |queued_event| {
                    var event_to_drop = queued_event;
                    event_to_drop.deinit();
                }
            }
        }

        // Only states handle activities and exit actions
        if (element.kind == .state or element.kind == .submachine) {
            const state_element = @as(*StateElement, @ptrCast(@alignCast(element)));

            // Update history for parent
            const parent_path = std.fs.path.dirname(state_name) orelse "";
            if (record_history and self.history_value.capacity() > 0 and parent_path.len > 0 and !std.mem.eql(u8, parent_path, "/")) {
                try self.rememberHistory(parent_path, state_name, .shallow);

                // The first state exited is the active leaf. Preserve that leaf
                // for every enclosing composite so deep history restores the
                // complete configuration instead of following initial transitions.
                if (std.mem.eql(u8, state_name, self.current_state)) {
                    var ancestor_path = parent_path;
                    while (ancestor_path.len > 0 and !std.mem.eql(u8, ancestor_path, "/")) {
                        try self.rememberHistory(ancestor_path, state_name, .deep);
                        ancestor_path = std.fs.path.dirname(ancestor_path) orelse "";
                    }
                }
            }

            // Wait for activities to finish (with timeout to avoid hanging)
            for (state_element.activities) |activity_name| {
                activity_registry_mutex.lock();
                var active: ?ActivityHandle = null;
                if (self.active_activities.fetchRemove(activity_name)) |removed| active = removed.value;
                activity_registry_mutex.unlock();
                if (active) |removed| {
                    const is_current_activity = current_activity_context != null and current_activity_context.? == removed.ctx;
                    removed.ctx.cancel();
                    if (is_current_activity) detachActivity(removed) else joinAndDestroyActivity(removed);
                }
            }

            // Cancel timers. The owner joins retained handles after the active
            // transition has completed, avoiding self-join and handle races.
            for (state_element.transitions) |trans_name| {
                timer_registry_mutex.lock();
                if (self.active_timers.get(trans_name)) |handle| {
                    const timer_context = handle.timer_context;
                    const trans = getTransition(self.model, trans_name);
                    const is_current_timer = timer_context.dispatching.load(.acquire) and
                        timer_context.thread_id.load(.acquire) == @as(u64, @intCast(std.Thread.getCurrentId()));
                    const preserve_current_self = is_current_timer and trans != null and
                        trans.?.target != null and std.mem.eql(u8, trans.?.source, trans.?.target.?) and
                        (trans.?.timer_kind == .every or trans.?.timer_kind == .after);
                    timer_context.cancelled.store(!preserve_current_self, .release);
                }
                timer_registry_mutex.unlock();
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
                if (!was_done and ctx.is_done()) return;
            }
        }
    }

    fn rememberHistory(self: *Self, parent_path: []const u8, target_path: []const u8, kind: HistoryKind) !void {
        const key = try historyStorageKey(self.allocator, parent_path, kind);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, target_path);
        errdefer self.allocator.free(value);

        const result = try self.history_value.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(key);
            self.allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = value;
    }

    fn enterAllIntermediateStates(self: *Self, from_path: []const u8, to_path: []const u8, event: Event, ctx: *Context) !void {
        // Handle all types of hierarchical transitions:
        // 1. Same hierarchy (deeper): /a/b -> /a/b/c/d
        // 2. Cross hierarchy: /a/b -> /a/c/d
        // 3. Up and across: /a/b/c -> /a/d/e

        // Find common ancestor path
        const common_ancestor = self.findCommonAncestor(from_path, to_path);

        // Enter all states from common ancestor to target (excluding the target itself)
        try self.enterIntermediateStates(common_ancestor, to_path, event, ctx);
    }

    fn findCommonAncestor(self: *Self, path1: []const u8, path2: []const u8) []const u8 {
        _ = self;
        return lca(path1, path2);
    }

    fn enterIntermediateStates(self: *Self, from_path: []const u8, to_path: []const u8, event: Event, ctx: *Context) !void {
        const was_done = ctx.is_done();
        // Find intermediate states between from_path and to_path
        if (!std.mem.startsWith(u8, to_path, from_path)) {
            return;
        }

        // Get the remaining path after from_path
        const remaining_path = to_path[from_path.len..];
        if (remaining_path.len == 0 or remaining_path[0] != '/') return;

        // Walk the existing target path directly. Do not allocate a builder or
        // duplicate each intermediate qualified name during entry.
        var segment_end = from_path.len + 1;
        while (segment_end <= to_path.len) {
            if (std.mem.indexOfScalarPos(u8, to_path, segment_end, '/')) |separator| {
                segment_end = separator;
            } else {
                segment_end = to_path.len;
            }

            // Do not enter the final state here; the main enterState call owns it.
            const segment_path = to_path[0..segment_end];
            if (!std.mem.eql(u8, segment_path, to_path)) {
                // This is an intermediate state - enter it without processing initial transitions
                if (getState(self.model, segment_path)) |state_element| {
                    // Execute entry behaviors for this intermediate state
                    for (state_element.entry) |entry_name| {
                        const entry_behavior = getBehavior(self.model, entry_name) orelse continue;
                        const entry_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(entry_behavior.function_ptr));
                        const instance: *Instance = @ptrCast(@alignCast(self.instance));
                        entry_fn(ctx, instance, event);
                        if (!was_done and ctx.is_done()) return;
                    }
                }
            }

            if (segment_end == to_path.len) break;
            segment_end += 1;
        }
    }

    fn resolveTargetWithIntermediateInitials(self: *Self, from_path: []const u8, to_path: []const u8) ![]const u8 {
        // Check if any intermediate states along the path have initial transitions that should redirect

        // Find common ancestor path
        const common_ancestor = self.findCommonAncestor(from_path, to_path);

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

    fn enterState(self: *Self, state_name: []const u8, event: Event, ctx: *Context, default_entry: bool) !bool {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.enterState(state_name, event, ctx, default_entry);
        _ = transitionDepth(self).fetchAdd(1, .acq_rel);
        defer _ = transitionDepth(self).fetchSub(1, .acq_rel);
        const was_done = ctx.is_done();
        const entry_previous_state = self.current_state;
        var committed = false;
        defer {
            if (!committed) self.current_state = entry_previous_state;
        }
        const element = self.model.members.get(state_name) orelse return true;

        if (element.kind == .entry_point or element.kind == .exit_point) {
            const point = @as(*ConnectionPointElement, @ptrCast(@alignCast(element)));
            if (point.transitions.len != 1) return error.InvalidTransitionTarget;
            const point_transition = getTransition(self.model, point.transitions[0]) orelse return error.InvalidTransitionTarget;
            if (element.kind == .entry_point) {
                const point_target = point_transition.target orelse return error.InvalidTransitionTarget;
                self.current_state = canonicalStateName(self.model, point_target);
                const entered = try self.enterState(point_target, event, ctx, true);
                if (!entered) return false;
            } else {
                for (point_transition.effects) |effect_name| {
                    const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                    const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                    const instance: *Instance = @ptrCast(@alignCast(self.instance));
                    effect_fn(ctx, instance, event);
                    if (!was_done and ctx.is_done()) return false;
                }
                const boundary = element.owner();
                self.current_state = canonicalStateName(self.model, boundary);
                var exit_event = try cloneEventForQueue(self.allocator, event);
                defer exit_event.deinit();
                const exit_name = try exitPointEventName(self.allocator, boundary, element.name());
                if (exit_event.owns_name) self.allocator.free(@constCast(exit_event.name));
                exit_event.name = exit_name;
                exit_event.owns_name = true;
                const handled = try self.processEvent(ctx, exit_event);
                if (!handled) return error.UnhandledExitPoint;
                if (!was_done and ctx.is_done()) return false;
            }
            committed = true;
            return true;
        }

        if (element.kind == .history) {
            const history_elem = @as(*HistoryElement, @ptrCast(@alignCast(element)));
            const parent_path = std.fs.path.dirname(state_name) orelse return true;
            const history_key = try historyStorageKey(self.allocator, parent_path, history_elem.history_kind);
            defer self.allocator.free(history_key);

            var restored_history = false;
            var target_path: []const u8 = undefined;
            const default_transition_names: ?[][]const u8 = if (self.model.transition_map.get(state_name)) |history_events| history_events.get("") else null;

            // Try to find history
            if (self.history_value.get(history_key)) |last_active| {
                target_path = last_active;
                restored_history = true;
            } else if (default_transition_names) |transition_names| {
                var selected_transition: ?*TransitionElement = null;
                for (transition_names) |transition_name| {
                    const default_transition = getTransition(self.model, transition_name) orelse continue;
                    const matches = self.matchesTransition(default_transition, event, ctx);
                    if (!was_done and ctx.is_done()) return false;
                    if (matches) {
                        selected_transition = default_transition;
                        break;
                    }
                }
                const selected = selected_transition orelse return true;
                target_path = selected.target orelse return true;
                for (selected.effects) |effect_name| {
                    const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                    const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                    const instance: *Instance = @ptrCast(@alignCast(self.instance));
                    effect_fn(ctx, instance, event);
                    if (!was_done and ctx.is_done()) return false;
                }
            } else if (history_elem.default_target) |def_target| {
                target_path = def_target;
            } else {
                // No history and no default - stuck (should be validation error)
                return true;
            }

            // Recurse to enter the target state
            // We need to enter intermediate states from Parent to Target
            try self.enterAllIntermediateStates(parent_path, target_path, event, ctx);

            // Update current state
            self.current_state = canonicalStateName(self.model, target_path);

            // Shallow history follows the target state's initial transition;
            // deep history restores the recorded leaf without redirecting it.
            // A deep-history default target is a normal initial entry, so a
            // composite default still reaches its initialized leaf.
            const entered = try self.enterState(target_path, event, ctx, history_elem.history_kind == .shallow or !restored_history);
            if (!entered) return false;
            committed = true;
            return true;
        }

        const state_element = getState(self.model, state_name) orelse return error.InvalidTransitionTarget;
        self.current_state = canonicalStateName(self.model, state_name);
        // Execute entry behaviors with error handling
        for (state_element.entry) |entry_name| {
            const entry_behavior = getBehavior(self.model, entry_name) orelse continue;
            const entry_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(entry_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            self.executeWithErrorHandling(entry_fn, ctx, instance, event, "entry") catch |err| {
                self.dispatchErrorEvent(ctx, err, "entry_execution") catch |dispatch_err| {
                    std.log.err("Failed to dispatch error event during entry: {}, original error: {}", .{ dispatch_err, err });
                };
                return false; // Stop processing if entry action fails
            };
            if (!was_done and ctx.is_done()) return false;
        }

        // Activities belong to the state itself, so they start before a
        // composite state's initial transition enters its child.
        for (state_element.activities) |activity_name| {
            activity_registry_mutex.lock();
            const active = self.active_activities.fetchRemove(activity_name);
            activity_registry_mutex.unlock();
            if (active) |removed| {
                const is_current_activity = current_activity_context != null and current_activity_context.? == removed.value.ctx;
                removed.value.ctx.cancel();
                if (is_current_activity) detachActivity(removed.value) else joinAndDestroyActivity(removed.value);
            }
            const activity_behavior = getBehavior(self.model, activity_name) orelse continue;
            const activity_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(activity_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            var start_gate = std.atomic.Value(bool).init(false);

            const ActivityArgs = struct {
                ctx: *Context,
                machine: *StateMachine,
                control: *ActivityControl,
                inst: *Instance,
                event: OwnedActivityEvent,
                behavior_name: []const u8,
                func: *const fn (ctx: *Context, inst: *Instance, event: Event) void,
                start_gate: *std.atomic.Value(bool),
            };

            const ActivityWrapper = struct {
                fn run(args: ActivityArgs) void {
                    var owned_args = args;
                    const previous_activity_context = current_activity_context;
                    const previous_activity_machine = current_activity_machine;
                    defer {
                        current_activity_context = previous_activity_context;
                        current_activity_machine = previous_activity_machine;
                        deinitActivityEvent(owned_args.event.event.allocator, &owned_args.event);
                        if (owned_args.control.wrapper_owns_context.load(.acquire)) {
                            destroyActivityContext(owned_args.ctx, owned_args.control);
                        }
                        if (takeDeferredDeinit(owned_args.machine)) owned_args.machine.deinit();
                    }
                    owned_args.start_gate.store(true, .release);
                    while (!owned_args.control.run_requested.load(.acquire)) {
                        std.Thread.yield() catch {};
                    }
                    if (owned_args.control.skip_callback.load(.acquire)) return;

                    // Activity callbacks are concurrent behavior, but their
                    // admission and callback body still belong to the owning
                    // machine's serialized lifecycle. Holding a real lease
                    // here makes stop/deinit wait for an admitted callback and
                    // makes callbacks that start after stop admission close
                    // exit without touching the machine.
                    var lifecycle_lease = acquireActivityLifecycleLease(owned_args.machine) catch return orelse return;
                    defer lifecycle_lease.release();
                    current_activity_context = owned_args.ctx;
                    current_activity_machine = @as(*anyopaque, @ptrCast(owned_args.machine));
                    owned_args.func(owned_args.ctx, owned_args.inst, owned_args.event.event);
                }
            };

            const activity_ctx = try self.allocator.create(Context);
            activity_ctx.* = Context.initWithParent(self.allocator, self._context);
            const activity_control = self.allocator.create(ActivityControl) catch |err| {
                self.allocator.destroy(activity_ctx);
                return err;
            };
            activity_control.* = .{
                .wrapper_owns_context = std.atomic.Value(bool).init(false),
                .run_requested = std.atomic.Value(bool).init(false),
                .skip_callback = std.atomic.Value(bool).init(false),
            };
            var activity_event = cloneActivityEvent(self.allocator, event) catch |err| {
                std.log.warn("Failed to clone activity event for {s}: {}", .{ activity_name, err });
                self.allocator.destroy(activity_ctx);
                self.allocator.destroy(activity_control);
                continue;
            };
            const args = ActivityArgs{ .ctx = activity_ctx, .machine = canonicalMachine(self), .control = activity_control, .inst = instance, .event = activity_event, .behavior_name = activity_name, .func = activity_fn, .start_gate = &start_gate };
            const thread = std.Thread.spawn(.{}, ActivityWrapper.run, .{args}) catch |err| {
                std.log.warn("Failed to spawn activity thread for {s}: {}", .{ activity_name, err });
                deinitActivityEvent(self.allocator, &activity_event);
                destroyActivityContext(activity_ctx, activity_control);
                continue;
            };
            while (!start_gate.load(.acquire)) {
                std.Thread.yield() catch {};
            }

            var machine_stopped = false;
            var registration_error: ?anyerror = null;
            activity_registry_mutex.lock();
            if (self.stopped) {
                machine_stopped = true;
                activity_ctx.cancel();
                activity_control.skip_callback.store(true, .release);
            } else {
                self.active_activities.put(activity_name, .{ .thread = thread, .ctx = activity_ctx, .control = activity_control }) catch |err| {
                    registration_error = err;
                    activity_control.skip_callback.store(true, .release);
                };
            }
            activity_control.run_requested.store(true, .release);
            activity_registry_mutex.unlock();

            if (machine_stopped) {
                thread.join();
                destroyActivityContext(activity_ctx, activity_control);
                continue;
            }
            if (registration_error) |err| {
                std.log.warn("Failed to track activity thread for {s}: {}", .{ activity_name, err });
                thread.join();
                destroyActivityContext(activity_ctx, activity_control);
                continue;
            }
        }

        if (default_entry and state_element.initial_transition != null and self.active_timers.capacity() > 0) {
            const timer_was_done = ctx.is_done();
            try self.startTimerTransitions(state_element, event, ctx);
            if (!timer_was_done and ctx.is_done()) {
                self.current_state = canonicalStateName(self.model, state_name);
                committed = true;
                return true;
            }
        }

        // After entry actions, process initial transition if this is a default entry
        if (default_entry and state_element.initial_transition != null) {
            if (state_element.initial_transition) |initial_trans_name| {
                const initial_trans = getTransition(self.model, initial_trans_name) orelse return true;
                // The composite state is active before its initial effect and
                // child entry run.
                self.current_state = canonicalStateName(self.model, state_name);
                for (initial_trans.effects) |effect_name| {
                    const effect_behavior = getBehavior(self.model, effect_name) orelse continue;
                    const effect_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) void = @ptrCast(@alignCast(effect_behavior.function_ptr));
                    const instance: *Instance = @ptrCast(@alignCast(self.instance));
                    effect_fn(ctx, instance, event);
                    if (!was_done and ctx.is_done()) return false;
                }
                if (initial_trans.target) |target_name| {
                    const original_current_state = self.current_state;
                    // Resolve the target, checking for intermediate state initial transitions
                    const resolved_target = try self.resolveTargetWithIntermediateInitials(original_current_state, target_name);
                    defer self.allocator.free(resolved_target);

                    // Check if we got a special marker indicating an intermediate state with initial transition
                    if (std.mem.startsWith(u8, resolved_target, "ENTER_THEN_FOLLOW:")) {
                        // Parse the marker: ENTER_THEN_FOLLOW:intermediate_path:final_target
                        var parts = std.mem.splitScalar(u8, resolved_target["ENTER_THEN_FOLLOW:".len..], ':');
                        const intermediate_path = parts.next() orelse return true;
                        _ = parts.next() orelse return true;

                        // First, enter intermediate states up to the intermediate_path
                        try self.enterAllIntermediateStates(original_current_state, intermediate_path, event, ctx);
                        if (!was_done and ctx.is_done()) return false;

                        // Update current state to intermediate state
                        self.current_state = canonicalStateName(self.model, intermediate_path);

                        // Enter the intermediate state (which will execute its entry actions and process its initial transition)
                        const entered = try self.enterState(intermediate_path, event, ctx, true);
                        if (!entered) return false;
                        committed = true;
                        return true; // The intermediate state's initial transition will handle the rest
                    } else {
                        // Normal resolved target
                        // Update current state to the resolved target
                        self.current_state = canonicalStateName(self.model, resolved_target);

                        // Enter intermediate states for any hierarchical transition
                        try self.enterAllIntermediateStates(original_current_state, resolved_target, event, ctx);
                        if (!was_done and ctx.is_done()) return false;

                        const entered = try self.enterState(resolved_target, event, ctx, true);
                        if (!entered) return false;
                        committed = true;
                        return true; // Don't continue with activities since we've transitioned
                    }
                }
            }
        }

        if (self.active_timers.capacity() > 0) try self.startTimerTransitions(state_element, event, ctx);
        committed = true;
        return true;
    }

    fn startTimerTransitions(self: *Self, state_element: *StateElement, event: Event, ctx: *Context) !void {
        const was_done = ctx.is_done();
        for (state_element.transitions) |trans_name| {
            const trans = getTransition(self.model, trans_name) orelse continue;
            if (trans.event_name != null) continue;
            if (trans.timer_fn) |timer_fn_name| {
                var timer_to_join: ?TimerHandle = null;
                var preserve_current_timer = false;
                var skip_current_timer = false;
                timer_registry_mutex.lock();
                if (self.active_timers.get(trans_name)) |active| {
                    const is_current_timer = active.timer_context.dispatching.load(.acquire) and
                        active.timer_context.thread_id.load(.acquire) == @as(u64, @intCast(std.Thread.getCurrentId()));
                    preserve_current_timer = is_current_timer and trans.target != null and
                        std.mem.eql(u8, trans.source, trans.target.?);
                    if (!preserve_current_timer) {
                        active.timer_context.cancelled.store(true, .release);
                        skip_current_timer = is_current_timer;
                        if (!is_current_timer) {
                            timer_to_join = active;
                            _ = self.active_timers.remove(trans_name);
                        }
                    }
                }
                timer_registry_mutex.unlock();
                if (timer_to_join) |active| {
                    active.thread.join();
                }
                if (preserve_current_timer or skip_current_timer) continue;

                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse continue;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                const timer_value_ns = timer_fn(ctx, instance, event);
                if (!was_done and ctx.is_done()) return;
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
                    // Timer workers retain the machine's start context, not
                    // an arbitrary event/entry context supplied to this
                    // transition. The machine context is the documented
                    // lifetime boundary for asynchronous runtime work.
                    .ctx = self._context,
                    .clock = self.clock,
                    .delay_ns = delay_ns,
                    .cancelled = cancelled,
                    .thread_id = std.atomic.Value(u64).init(0),
                    .dispatching = std.atomic.Value(bool).init(false),
                };

                timer_registry_mutex.lock();
                const thread = std.Thread.spawn(.{}, timerThreadFn, .{ timer_context, self, trans_name }) catch |err| {
                    timer_registry_mutex.unlock();
                    std.log.warn("Failed to spawn timer thread for {s}: {}", .{ trans_name, err });
                    self.allocator.destroy(timer_context);
                    self.allocator.destroy(cancelled);
                    continue;
                };

                self.active_timers.put(trans_name, .{ .thread = thread, .timer_context = timer_context }) catch |err| {
                    timer_registry_mutex.unlock();
                    std.log.warn("Failed to track timer thread for {s}: {}", .{ trans_name, err });
                    cancelled.store(true, .release);
                    thread.join();
                    continue;
                };
                timer_registry_mutex.unlock();
            }
        }
    }

    fn timerThreadFn(timer_context: *TimerContext, machine: *StateMachine, transition_name: []const u8) void {
        const allocator = machine.allocator;
        defer {
            timer_context.dispatching.store(false, .release);
            timer_registry_mutex.lock();
            _ = machine.active_timers.remove(transition_name);
            timer_registry_mutex.unlock();
            if (takeDeferredDeinit(machine)) machine.deinit();
            allocator.destroy(timer_context.cancelled);
            allocator.destroy(timer_context);
        }

        timer_context.thread_id.store(@intCast(std.Thread.getCurrentId()), .release);

        const timer_transition = getTransition(machine.model, transition_name) orelse return;
        var delay_ns = timer_context.delay_ns;
        const sleep_chunk_ns = std.time.ns_per_ms * 100;

        while (true) {
            var remaining_ns = delay_ns;
            while (remaining_ns > 0 and !timer_context.ctx.is_done() and !timer_context.cancelled.load(.acquire)) {
                const chunk = @min(remaining_ns, sleep_chunk_ns);
                timer_context.clock.Sleep(chunk);
                remaining_ns -= chunk;
            }

            if (remaining_ns > 0 or timer_context.ctx.is_done() or timer_context.cancelled.load(.acquire)) return;

            const prefix = if (timer_transition.timer_kind == .every) "_periodic:" else "_timeout:";
            const event_name = std.fmt.allocPrint(machine.allocator, "{s}{s}", .{ prefix, transition_name }) catch return;
            defer machine.allocator.free(event_name);

            var timer_event = Event.init(machine.allocator, event_name);
            timer_event.kind = TimeEventKind;
            var lifecycle_lease = (acquireLifecycleLease(machine) catch return) orelse {
                timer_event.deinit();
                return;
            };
            defer lifecycle_lease.release();
            if (machine.stopped) {
                timer_event.deinit();
                return;
            }
            timer_context.dispatching.store(true, .release);
            _ = machine.dispatch(timer_context.ctx, timer_event) catch {};
            timer_context.dispatching.store(false, .release);

            const rearm_self = timer_transition.target != null and
                std.mem.eql(u8, timer_transition.source, timer_transition.target.?);
            if (timer_transition.timer_kind != .every and !rearm_self) {
                timer_event.deinit();
                return;
            }
            if (timer_context.ctx.is_done() or timer_context.cancelled.load(.acquire)) {
                timer_event.deinit();
                return;
            }
            if (!stateMatchesOrIsDescendant(machine.current_state, timer_transition.source)) {
                timer_event.deinit();
                return;
            }

            const timer_name = timer_transition.timer_fn orelse {
                timer_event.deinit();
                return;
            };
            const timer_behavior = getBehavior(machine.model, timer_name) orelse {
                timer_event.deinit();
                return;
            };
            const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(machine.instance));
            delay_ns = timer_fn(timer_context.ctx, instance, timer_event);
            timer_event.deinit();
            if (delay_ns == 0) return;
        }
    }

    pub fn start(self: *Self) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.start();
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();
        if (!self.stopped) return;
        return self.restart();
    }

    pub fn stop(self: *Self) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.stop();
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        var lifecycle_lease_active = true;
        defer if (lifecycle_lease_active) lifecycle_lease.release();
        const root_state_name = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.model.name});
        defer self.allocator.free(root_state_name);
        if (self.stopped) {
            activity_registry_mutex.lock();
            const has_pending_activities = self.active_activities.count() > 0;
            activity_registry_mutex.unlock();
            const has_active_configuration = !std.mem.eql(u8, self.current_state, canonicalStateName(self.model, root_state_name));
            if (!has_pending_activities and !has_active_configuration) return;
        }

        const queue_drain_owner = current_queue_processing_machine == self;
        if (!queue_drain_owner) {
            if (runtimeOwner(self)) |owner| {
                if (owner.owned_queue) |owned_queue| owned_queue.waitForProcessing();
            }
        }

        activity_registry_mutex.lock();
        const activity_count = self.active_activities.count();
        activity_registry_mutex.unlock();
        var activity_entries = try std.ArrayList(ActivityHandle).initCapacity(self.allocator, activity_count);
        defer activity_entries.deinit(self.allocator);

        timer_registry_mutex.lock();
        const timer_count = self.active_timers.count();
        timer_registry_mutex.unlock();
        var timer_entries = try std.ArrayList(TimerHandle).initCapacity(self.allocator, timer_count);
        defer timer_entries.deinit(self.allocator);
        var current_timer_flags = try std.ArrayList(bool).initCapacity(self.allocator, timer_count);
        defer current_timer_flags.deinit(self.allocator);
        var timer_names = try std.ArrayList([]const u8).initCapacity(self.allocator, timer_count);
        defer timer_names.deinit(self.allocator);

        // Preflight every stop-owned allocation while the exclusive lifecycle
        // lease is still held. Once stopped is published, the teardown below
        // only mutates already-owned storage and cannot fail due to bookkeeping
        // growth halfway through the active-state exit.
        // A lifecycle stop exits the active configuration before releasing
        // runtime state. This matches the sibling runtimes and makes restart
        // a true stop/re-enter cycle rather than a silent state reset.
        var exit_event = Event.init(self.allocator, FinalEventName);
        defer exit_event.deinit();

        self.stopped = true;
        // Keep stop/restart/deinit entrants out while teardown is in flight,
        // but do not use the permanent close bit: a stopped machine remains
        // restartable and its lifecycle gate must survive this operation.
        setLifecycleStopping(self, true);
        defer setLifecycleStopping(self, false);

        // Cancel admitted activities before exiting their owning states, then
        // wait for every callback except a callback that is synchronously
        // stopping this same machine. This prevents activity code from
        // touching the shared instance while exit/teardown behavior runs.
        activity_registry_mutex.lock();
        var active_activity_iter = self.active_activities.iterator();
        while (active_activity_iter.next()) |activity_entry| {
            activity_entry.value_ptr.ctx.cancel();
        }
        activity_registry_mutex.unlock();
        // A non-owning lease means this stop is re-entrant from an already
        // admitted lifecycle callback (entry/exit/effect/activity/timer), so
        // that caller's one reference may remain while teardown avoids a
        // self-wait. An ordinary external stop owns its lease and must wait
        // for every admitted callback reference. Releasing this lease also
        // unlocks the gate before the wait: an external caller that counted
        // a reference while blocked on the gate can observe `stopping`,
        // release that reference, and cannot spuriously consume the timeout.
        const retained_lifecycle_references: usize = if (!lifecycle_lease.owns_reference) 1 else 0;
        lifecycle_lease.release();
        lifecycle_lease_active = false;
        if (!waitForAdmittedActivityCallbacks(self, retained_lifecycle_references, self.activity_timeout_ns)) {
            return error.ActivityTimeout;
        }

        if (self.regular_queue) |queue| {
            const is_internal_queue = if (runtimeOwner(self)) |owner| if (owner.owned_queue) |owned_queue|
                queue == &owned_queue.runtime_queue
            else
                false else false;
            if (!is_internal_queue) {
                // Drain injected-queue ownership before state exit. If a
                // persistent Pop failure remains, the machine stays stopped
                // with its active configuration intact for a later retry.
                var pop_error_seen = false;
                while (true) {
                    const queued_event = queue.Pop(self._context) catch |err| {
                        if (pop_error_seen) return err;
                        pop_error_seen = true;
                        std.log.warn("Failed to drain custom queue during stop: {}", .{err});
                        continue;
                    } orelse break;
                    var event_to_drop = queued_event;
                    event_to_drop.deinit();
                }
            }
        }

        errdefer self.stopped = false;

        const previous_lifecycle_machine = current_lifecycle_machine;
        const previous_lifecycle_depth = current_lifecycle_depth;
        current_lifecycle_machine = self;
        current_lifecycle_depth = 1;
        defer {
            current_lifecycle_machine = previous_lifecycle_machine;
            current_lifecycle_depth = previous_lifecycle_depth;
        }

        var state_name = self.current_state;
        while (!std.mem.eql(u8, state_name, root_state_name)) {
            // Stop discards history below, so avoid allocating history records
            // while tearing down. This also keeps stop's preflighted error
            // surface independent of history-map growth.
            try self.exitState(state_name, exit_event, self._context, false);
            state_name = std.fs.path.dirname(state_name) orelse break;
        }

        // Snapshot activities under their registry lock, then join outside it
        // so callbacks cannot block unrelated state bookkeeping.
        activity_registry_mutex.lock();
        var activity_lock_held = true;
        defer if (activity_lock_held) activity_registry_mutex.unlock();
        var activity_iter = self.active_activities.iterator();
        while (activity_iter.next()) |activity_entry| {
            const active = activity_entry.value_ptr.*;
            active.ctx.cancel();
            const is_current_activity = current_activity_context != null and current_activity_context.? == active.ctx;
            if (is_current_activity) {
                detachActivity(active);
            } else {
                activity_entries.appendAssumeCapacity(active);
            }
        }
        self.active_activities.clearAndFree();
        activity_registry_mutex.unlock();
        activity_lock_held = false;

        for (activity_entries.items) |activity_entry| {
            joinAndDestroyActivity(activity_entry);
        }

        // Snapshot and cancel timers under the registry lock, then join and
        // release their handles after unlocking. A timer thread never frees
        // its own handle: the owner must retain it until join completes.
        timer_registry_mutex.lock();
        var timer_lock_held = true;
        defer if (timer_lock_held) timer_registry_mutex.unlock();
        var timer_iter = self.active_timers.iterator();
        while (timer_iter.next()) |timer_entry| {
            const timer_context = timer_entry.value_ptr.timer_context;
            timer_context.cancelled.store(true, .release);
            const current_thread_id: u64 = @intCast(std.Thread.getCurrentId());
            const is_current_timer = timer_context.dispatching.load(.acquire) and
                timer_context.thread_id.load(.acquire) == current_thread_id;
            timer_entries.appendAssumeCapacity(timer_entry.value_ptr.*);
            current_timer_flags.appendAssumeCapacity(is_current_timer);
            timer_names.appendAssumeCapacity(timer_entry.key_ptr.*);
        }
        for (timer_names.items, current_timer_flags.items) |timer_name, is_current_timer| {
            if (!is_current_timer) _ = self.active_timers.remove(timer_name);
        }
        timer_registry_mutex.unlock();
        timer_lock_held = false;

        for (timer_entries.items, current_timer_flags.items) |timer_entry, is_current_timer| {
            if (!is_current_timer) {
                timer_entry.thread.join();
            }
        }

        while (self.deferred_queue.dequeue()) |queued_event| {
            var event_to_drop = queued_event;
            event_to_drop.deinit();
        }
        if (runtimeOwner(self)) |owner| {
            if (owner.owned_queue) |owned_queue| {
                if (!queue_drain_owner) owned_queue.clear();
            }
        }

        timer_registry_mutex.lock();
        var has_current_timer = false;
        for (timer_names.items, current_timer_flags.items) |_, is_current_timer| {
            if (is_current_timer) has_current_timer = true;
        }
        if (!has_current_timer) self.active_timers.clearAndFree();
        timer_registry_mutex.unlock();

        // Keep the canonical model-root path alive for allocation-free
        // identity queries after stop. state() hides it while stopped.
        self.current_state = canonicalStateName(self.model, root_state_name);

        // Clear collections
        self.active_activities.clearAndFree();

        // Clear history map
        var hist_iter = self.history_value.iterator();
        while (hist_iter.next()) |h_entry| {
            self.allocator.free(h_entry.key_ptr.*);
            self.allocator.free(h_entry.value_ptr.*);
        }
        self.history_value.clearAndFree();
        removeContextMachine(self._context, self);
    }

    /// Stop the current runtime and re-enter the model's initial state.
    pub fn restart(self: *Self) !void {
        const machine = canonicalMachine(self);
        if (machine != self) return machine.restart();
        var lifecycle_lease = try acquireLifecycleLease(machine) orelse return error.MachineStopped;
        defer lifecycle_lease.release();

        try self.stop();
        try registerContextMachine(self._context, self);

        if (runtimeOwner(self)) |owner| {
            if (owner.owned_queue) |internal_queue| {
                const previous_queue_processing_machine = current_queue_processing_machine;
                current_queue_processing_machine = self;
                defer current_queue_processing_machine = previous_queue_processing_machine;
                while (true) {
                    const queued_event = internal_queue.dequeue() orelse break;
                    var event = queued_event;
                    if (event.owns_name or event.owns_id or event.owns_source or event.owns_target or event.owns_data_keys or event.owns_metadata_keys) event.deinit();
                }
                internal_queue.stopProcessing();
            }
        }

        const root_state_name = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.model.name});
        defer self.allocator.free(root_state_name);
        _ = getState(self.model, root_state_name) orelse return error.NoRootState;

        while (self.deferred_queue.dequeue()) |queued_event| {
            var event = queued_event;
            event.deinit();
        }

        var history_iter = self.history_value.iterator();
        while (history_iter.next()) |history_entry| {
            self.allocator.free(history_entry.key_ptr.*);
            self.allocator.free(history_entry.value_ptr.*);
        }
        self.history_value.clearAndFree();

        var attribute_iter = self.attributes.iterator();
        while (attribute_iter.next()) |attribute_entry| {
            self.allocator.free(attribute_entry.key_ptr.*);
            attribute_entry.value_ptr.deinit(self.allocator);
        }
        self.attributes.clearAndFree();
        try self.initializeAttributes();

        self.active_states.clearRetainingCapacity();
        self.stopped = false;
        if (modelHasHistory(self.model)) try self.history_value.ensureTotalCapacity(1);
        if (modelHasTimers(self.model)) try self.active_timers.ensureTotalCapacity(1);

        self.current_state = canonicalStateName(self.model, root_state_name);
        var initial_event = Event.initial(self.allocator);
        if (self.runtime_data) |data| try initial_event.putData("", data);
        defer initial_event.deinit();
        _ = try self.enterState(root_state_name, initial_event, self._context, true);
        try self.processCompletionTransitions(self._context, initial_event);

        if (runtimeOwner(self)) |owner| {
            if (owner.owned_queue) |internal_queue| {
                while (true) {
                    const queued_event = internal_queue.dequeue() orelse {
                        if (internal_queue.finishProcessing()) continue;
                        break;
                    };
                    var processed_event = queued_event;
                    defer if (processed_event.owns_name or processed_event.owns_id or processed_event.owns_source or processed_event.owns_target or processed_event.owns_data_keys or processed_event.owns_metadata_keys) processed_event.deinit();
                    _ = self.processRegularEvent(self._context, processed_event) catch |err| {
                        internal_queue.stopProcessing();
                        return err;
                    };
                    if (self.stopped) {
                        internal_queue.clear();
                        break;
                    }
                }
            }
        }
    }

    pub fn deinit(self: *Self) void {
        const owner = runtimeOwner(self);
        if (owner) |runtime_owner| {
            if (&runtime_owner.machine != self) {
                runtime_owner.machine.deinit();
                return;
            }
        }

        if (current_lifecycle_machine == self or context_dispatch_machine == self) {
            requestDeferredDeinit(self) catch return;
            self.stop() catch |err| {
                std.log.warn("Error during deferred dispatch stop in deinit: {}", .{err});
            };
            return;
        }

        // A timer callback may synchronously request deinit. It cannot join
        // itself, so leave ownership intact and let the timer thread finish
        // cleanup after its dispatch returns.
        if (hasCurrentTimer(self)) {
            requestDeferredDeinit(self) catch return;
            self.stop() catch |err| {
                std.log.warn("Error during deferred stop in deinit: {}", .{err});
            };
            return;
        }

        // Ensure we're stopped before unregistering or releasing runtime
        // collections. A concurrent stop is retried after its teardown
        // admission closes; a concurrent deinit owns permanent closure.
        while (true) {
            self.stop() catch |err| {
                if (err == error.MachineStopped) {
                    if (waitForStopAdmission(self)) continue;
                    return;
                }
                std.log.warn("Error during stop in deinit: {}", .{err});
                return;
            };
            break;
        }

        const lifecycle_gate = beginLifecycleClose(self) orelse return;
        waitForLifecycleClose(lifecycle_gate);
        unregisterContextMachine(self._context, self);

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

        if (self.runtime_id) |id| self.allocator.free(id);
        if (self.runtime_name) |name| self.allocator.free(name);

        if (owner) |runtime_owner| {
            if (runtime_owner.owned_model) |owned_model| {
                owned_model.deinit();
                runtime_owner.allocator.destroy(owned_model);
            }
            if (runtime_owner.owned_queue) |owned_queue| owned_queue.deinit();
            finishLifecycleClose(self, lifecycle_gate);
            runtime_owner.allocator.destroy(runtime_owner);
        }
    }
};

const LifecycleGate = struct {
    mutex: std.Thread.Mutex = .{},
    closing: bool = false,
    stopping: bool = false,
    references: usize = 0,
};

const LifecycleLease = struct {
    machine: *StateMachine,
    gate: ?*LifecycleGate,
    previous_machine: ?*StateMachine,
    previous_depth: usize,
    owns_reference: bool,

    fn release(self: *LifecycleLease) void {
        if (!self.owns_reference) {
            current_lifecycle_machine = self.previous_machine;
            current_lifecycle_depth = self.previous_depth;
            return;
        }

        const gate = self.gate.?;
        current_lifecycle_machine = self.previous_machine;
        current_lifecycle_depth = self.previous_depth;
        gate.mutex.unlock();

        lifecycle_registry_mutex.lock();
        gate.references -= 1;
        const destroy_gate = gate.closing and gate.references == 0;
        if (destroy_gate) _ = lifecycle_registry.?.remove(self.machine);
        lifecycle_registry_mutex.unlock();
        if (destroy_gate) std.heap.page_allocator.destroy(gate);
    }
};

/// Admission reference for concurrent activity callbacks. Unlike a regular
/// lifecycle lease, this does not hold the gate mutex for the callback body:
/// activities are concurrent by contract. The reference still keeps the
/// machine alive through lifecycle close and lets stop reject any callback
/// that has not yet been admitted.
const ActivityLifecycleLease = struct {
    gate: *LifecycleGate,
    previous_machine: ?*StateMachine,
    previous_depth: usize,

    fn release(self: *ActivityLifecycleLease) void {
        current_lifecycle_machine = self.previous_machine;
        current_lifecycle_depth = self.previous_depth;
        lifecycle_registry_mutex.lock();
        self.gate.references -= 1;
        lifecycle_registry_mutex.unlock();
    }
};

threadlocal var current_lifecycle_machine: ?*StateMachine = null;
threadlocal var current_lifecycle_depth: usize = 0;
var lifecycle_registry_mutex: std.Thread.Mutex = .{};
var lifecycle_registry: ?std.AutoHashMap(*StateMachine, *LifecycleGate) = null;

fn registerLifecycleGate(machine: *StateMachine) !void {
    const gate = try std.heap.page_allocator.create(LifecycleGate);
    gate.* = .{};
    lifecycle_registry_mutex.lock();
    if (lifecycle_registry == null) lifecycle_registry = std.AutoHashMap(*StateMachine, *LifecycleGate).init(std.heap.page_allocator);
    if (lifecycle_registry.?.get(machine) != null) {
        lifecycle_registry_mutex.unlock();
        std.heap.page_allocator.destroy(gate);
        return error.DuplicateLifecycleGate;
    }
    lifecycle_registry.?.put(machine, gate) catch |err| {
        lifecycle_registry_mutex.unlock();
        std.heap.page_allocator.destroy(gate);
        return err;
    };
    lifecycle_registry_mutex.unlock();
}

fn acquireLifecycleLease(machine: *StateMachine) !?LifecycleLease {
    if (current_lifecycle_machine == machine) {
        if (current_activity_machine != null and current_activity_machine.? == @as(*anyopaque, @ptrCast(machine))) {
            lifecycle_registry_mutex.lock();
            const activity_gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
            const activity_blocked = activity_gate == null or activity_gate.?.closing or activity_gate.?.stopping;
            lifecycle_registry_mutex.unlock();
            if (activity_blocked) return null;
        }
        const previous_depth = current_lifecycle_depth;
        current_lifecycle_depth += 1;
        return LifecycleLease{
            .machine = machine,
            .gate = null,
            .previous_machine = machine,
            .previous_depth = previous_depth,
            .owns_reference = false,
        };
    }

    lifecycle_registry_mutex.lock();
    const gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
    if (gate == null or gate.?.closing or gate.?.stopping) {
        lifecycle_registry_mutex.unlock();
        return null;
    }
    gate.?.references += 1;
    lifecycle_registry_mutex.unlock();

    const lifecycle_gate = gate.?;
    lifecycle_gate.mutex.lock();
    lifecycle_registry_mutex.lock();
    const closing = lifecycle_gate.closing;
    const stopping = lifecycle_gate.stopping;
    lifecycle_registry_mutex.unlock();
    if (closing or stopping) {
        lifecycle_gate.mutex.unlock();
        lifecycle_registry_mutex.lock();
        lifecycle_gate.references -= 1;
        lifecycle_registry_mutex.unlock();
        return null;
    }
    const lease = LifecycleLease{
        .machine = machine,
        .gate = lifecycle_gate,
        .previous_machine = current_lifecycle_machine,
        .previous_depth = current_lifecycle_depth,
        .owns_reference = true,
    };
    current_lifecycle_machine = machine;
    current_lifecycle_depth = 1;
    return lease;
}

fn acquireActivityLifecycleLease(machine: *StateMachine) !?ActivityLifecycleLease {
    lifecycle_registry_mutex.lock();
    const gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
    if (gate == null or gate.?.closing or gate.?.stopping) {
        lifecycle_registry_mutex.unlock();
        return null;
    }
    gate.?.references += 1;
    lifecycle_registry_mutex.unlock();

    const lease = ActivityLifecycleLease{
        .gate = gate.?,
        .previous_machine = current_lifecycle_machine,
        .previous_depth = current_lifecycle_depth,
    };
    current_lifecycle_machine = machine;
    current_lifecycle_depth = 1;
    return lease;
}

fn setLifecycleStopping(machine: *StateMachine, stopping: bool) void {
    lifecycle_registry_mutex.lock();
    if (lifecycle_registry) |registry| {
        if (registry.get(machine)) |gate| gate.stopping = stopping;
    }
    lifecycle_registry_mutex.unlock();
}

fn waitForStopAdmission(machine: *StateMachine) bool {
    while (true) {
        lifecycle_registry_mutex.lock();
        const gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
        const stopping = gate != null and gate.?.stopping;
        const closing = gate != null and gate.?.closing;
        lifecycle_registry_mutex.unlock();
        if (gate == null or closing) return false;
        if (!stopping) return true;
        std.Thread.yield() catch {};
    }
}

fn waitForAdmittedActivityCallbacks(machine: *StateMachine, retained_references: usize, timeout_ns: u64) bool {
    const timeout: i128 = @intCast(timeout_ns);
    const deadline = std.time.nanoTimestamp() + timeout;
    while (true) {
        lifecycle_registry_mutex.lock();
        const gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
        const references = if (gate) |value| value.references else 0;
        lifecycle_registry_mutex.unlock();
        if (gate == null or references <= retained_references) return true;
        if (std.time.nanoTimestamp() >= deadline) return false;
        std.Thread.yield() catch {};
    }
}

fn beginLifecycleClose(machine: *StateMachine) ?*LifecycleGate {
    lifecycle_registry_mutex.lock();
    const gate = if (lifecycle_registry) |registry| registry.get(machine) else null;
    if (gate == null or gate.?.closing) {
        lifecycle_registry_mutex.unlock();
        return null;
    }
    gate.?.closing = true;
    gate.?.references += 1;
    lifecycle_registry_mutex.unlock();

    gate.?.mutex.lock();
    gate.?.mutex.unlock();
    return gate;
}

fn waitForLifecycleClose(gate: *LifecycleGate) void {
    while (true) {
        lifecycle_registry_mutex.lock();
        const references = gate.references;
        lifecycle_registry_mutex.unlock();
        if (references == 1) break;
        std.Thread.yield() catch {};
    }
}

fn finishLifecycleClose(machine: *StateMachine, gate: *LifecycleGate) void {
    lifecycle_registry_mutex.lock();
    gate.references -= 1;
    _ = lifecycle_registry.?.remove(machine);
    lifecycle_registry_mutex.unlock();
    std.heap.page_allocator.destroy(gate);
}

pub fn qualifiedName(machine: *const StateMachine) []const u8 {
    return machine.QualifiedName();
}

pub const QualifiedName = qualifiedName;

var context_registry_mutex: std.Thread.Mutex = .{};
var context_registry: ?std.AutoHashMap(*Context, std.ArrayList(*StateMachine)) = null;
var context_registry_leases: ?std.AutoHashMap(*StateMachine, usize) = null;
threadlocal var context_dispatch_machine: ?*StateMachine = null;
threadlocal var context_dispatch_depth: usize = 0;

fn retainContextLeaseLocked(machine: *StateMachine) !void {
    if (context_registry_leases == null) {
        context_registry_leases = std.AutoHashMap(*StateMachine, usize).init(std.heap.page_allocator);
    }
    const lease_entry = try context_registry_leases.?.getOrPut(machine);
    if (!lease_entry.found_existing) lease_entry.value_ptr.* = 0;
    lease_entry.value_ptr.* += 1;
}

fn releaseContextLease(machine: *StateMachine) void {
    context_registry_mutex.lock();
    defer context_registry_mutex.unlock();
    const leases = &(context_registry_leases orelse return);
    const count = leases.getPtr(machine) orelse return;
    if (count.* <= 1) {
        _ = leases.remove(machine);
    } else {
        count.* -= 1;
    }
}

fn waitForContextLeases(machine: *StateMachine) void {
    while (true) {
        context_registry_mutex.lock();
        const leased = if (context_registry_leases) |leases| leases.get(machine) != null else false;
        context_registry_mutex.unlock();
        if (!leased) break;
        std.Thread.yield() catch {};
    }
}

fn leasedInstancesFromContext(allocator: std.mem.Allocator, context: *Context) ![]*StateMachine {
    context_registry_mutex.lock();
    defer context_registry_mutex.unlock();
    const registry = context_registry orelse return allocator.alloc(*StateMachine, 0);
    const machines = registry.get(context) orelse return allocator.alloc(*StateMachine, 0);
    const leased = try allocator.dupe(*StateMachine, machines.items);
    var retained: usize = 0;
    errdefer {
        while (retained > 0) : (retained -= 1) {
            const machine = leased[retained - 1];
            const leases = &(context_registry_leases orelse unreachable);
            const count = leases.getPtr(machine) orelse unreachable;
            if (count.* <= 1) {
                _ = leases.remove(machine);
            } else {
                count.* -= 1;
            }
        }
        allocator.free(leased);
    }
    for (leased) |machine| {
        try retainContextLeaseLocked(machine);
        retained += 1;
    }
    return leased;
}

fn registerContextMachine(context: *Context, machine: *StateMachine) !void {
    context_registry_mutex.lock();
    defer context_registry_mutex.unlock();
    if (context_registry == null) context_registry = std.AutoHashMap(*Context, std.ArrayList(*StateMachine)).init(std.heap.page_allocator);
    if (context_registry.?.getPtr(context)) |machines| {
        try machines.append(std.heap.page_allocator, machine);
        return;
    }
    var machines = try std.ArrayList(*StateMachine).initCapacity(std.heap.page_allocator, 1);
    errdefer machines.deinit(std.heap.page_allocator);
    try machines.append(std.heap.page_allocator, machine);
    try context_registry.?.put(context, machines);
}

fn unregisterContextMachine(context: *Context, machine: *StateMachine) void {
    removeContextMachine(context, machine);
    waitForContextLeases(machine);
}

fn removeContextMachine(context: *Context, machine: *StateMachine) void {
    context_registry_mutex.lock();
    if (context_registry) |*registry| {
        if (registry.getPtr(context)) |machines| {
            for (machines.items, 0..) |registered, index| {
                if (registered == machine) {
                    _ = machines.orderedRemove(index);
                    break;
                }
            }
            if (machines.items.len == 0) {
                if (registry.fetchRemove(context)) |removed| {
                    var owned = removed.value;
                    owned.deinit(std.heap.page_allocator);
                }
            }
        }
    }
    context_registry_mutex.unlock();
}

/// Return the most recently started machine registered with `context`.
pub fn fromContext(context: *Context) ?*StateMachine {
    context_registry_mutex.lock();
    defer context_registry_mutex.unlock();
    const registry = context_registry orelse return null;
    const machines = registry.get(context) orelse return null;
    return if (machines.items.len == 0) null else machines.items[machines.items.len - 1];
}

pub const FromContext = fromContext;

/// A context lookup lease keeps the selected machine registered and its
/// lifecycle gate held until `release`/`deinit` is called.
pub const ContextMachineLease = struct {
    machine: *StateMachine,
    lifecycle: LifecycleLease,
    released: bool = false,

    pub fn Machine(self: *const @This()) *StateMachine {
        return self.machine;
    }

    pub fn ID(self: *const @This()) ?[]const u8 {
        return self.machine.ID();
    }

    pub fn Name(self: *const @This()) []const u8 {
        return self.machine.Name();
    }

    pub fn QualifiedName(self: *const @This()) []const u8 {
        return self.machine.QualifiedName();
    }

    pub fn IsStopped(self: *const @This()) bool {
        return self.machine.IsStopped();
    }

    pub fn release(self: *@This()) void {
        if (self.released) return;
        self.lifecycle.release();
        releaseContextLease(self.machine);
        self.released = true;
    }

    pub fn deinit(self: *@This()) void {
        self.release();
    }
};

pub fn fromContextLease(context: *Context) !?ContextMachineLease {
    context_registry_mutex.lock();
    const registry = context_registry orelse {
        context_registry_mutex.unlock();
        return null;
    };
    const machines = registry.get(context) orelse {
        context_registry_mutex.unlock();
        return null;
    };
    if (machines.items.len == 0) {
        context_registry_mutex.unlock();
        return null;
    }
    const machine = machines.items[machines.items.len - 1];
    retainContextLeaseLocked(machine) catch |err| {
        context_registry_mutex.unlock();
        return err;
    };
    context_registry_mutex.unlock();

    const lifecycle = acquireLifecycleLease(machine) catch |err| {
        releaseContextLease(machine);
        return err;
    };
    if (lifecycle == null) {
        releaseContextLease(machine);
        return null;
    }
    return ContextMachineLease{ .machine = machine, .lifecycle = lifecycle.? };
}

pub const FromContextLease = fromContextLease;

/// Copy all machines registered with `context` into caller-owned storage.
pub fn instancesFromContext(allocator: std.mem.Allocator, context: *Context) ![]*StateMachine {
    context_registry_mutex.lock();
    defer context_registry_mutex.unlock();
    const registry = context_registry orelse return allocator.alloc(*StateMachine, 0);
    const machines = registry.get(context) orelse return allocator.alloc(*StateMachine, 0);
    return allocator.dupe(*StateMachine, machines.items);
}

pub const InstancesFromContext = instancesFromContext;

pub fn instancesFromContextLease(allocator: std.mem.Allocator, context: *Context) ![]ContextMachineLease {
    const machines = try leasedInstancesFromContext(allocator, context);
    defer allocator.free(machines);
    var leases = allocator.alloc(ContextMachineLease, machines.len) catch |err| {
        for (machines) |machine| releaseContextLease(machine);
        return err;
    };
    var initialized: usize = 0;
    errdefer {
        for (leases[0..initialized]) |*lease| lease.release();
        for (machines[initialized..]) |machine| releaseContextLease(machine);
        allocator.free(leases);
    }

    for (machines, 0..) |machine, index| {
        const lifecycle = (try acquireLifecycleLease(machine)) orelse return error.MachineStopped;
        leases[index] = ContextMachineLease{ .machine = machine, .lifecycle = lifecycle };
        initialized += 1;
    }
    return leases;
}

pub const InstancesFromContextLease = instancesFromContextLease;

fn duplicateContextSourceID(allocator: std.mem.Allocator, context: *Context) !?[]const u8 {
    var lease = (try fromContextLease(context)) orelse return null;
    defer lease.release();
    const id = lease.ID() orelse return null;
    return try allocator.dupe(u8, id);
}

fn dispatchIDMatches(id: ?[]const u8, ids: anytype) bool {
    const IdsType = @TypeOf(ids);
    const info = @typeInfo(IdsType);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("DispatchTo IDs must be a tuple of string-like values");
    }
    const fields = std.meta.fields(IdsType);
    if (fields.len == 0) return true;
    const value = id orelse return false;
    inline for (fields, 0..) |_, index| {
        if (match(value, ids[index])) return true;
    }
    return false;
}

/// Dispatch an event to every live machine registered with `context`.
pub fn dispatchAll(context: *Context, event: Event) !void {
    return dispatchTo(context, event, .{});
}

pub const DispatchAll = dispatchAll;

/// Dispatch an event to machines whose IDs match the supplied glob patterns.
/// An empty tuple selects every registered machine.
pub fn dispatchTo(context: *Context, event: Event, ids: anytype) !void {
    const machines = try leasedInstancesFromContext(context.allocator, context);
    defer context.allocator.free(machines);
    const source_id = if (event.source) |source_text| source_text else blk: {
        var selected_source: ?[]const u8 = null;
        for (machines) |machine| {
            var lifecycle_lease = (try acquireLifecycleLease(machine)) orelse continue;
            defer lifecycle_lease.release();
            if (!machine.stopped) {
                selected_source = machine.ID();
                break;
            }
        }
        break :blk selected_source;
    };
    for (machines) |machine| {
        var lease_released = false;
        defer if (!lease_released) releaseContextLease(machine);
        var lifecycle_lease = (try acquireLifecycleLease(machine)) orelse {
            lease_released = true;
            releaseContextLease(machine);
            continue;
        };
        var lifecycle_lease_active = true;
        defer if (lifecycle_lease_active) lifecycle_lease.release();
        if (machine.stopped) {
            lease_released = true;
            releaseContextLease(machine);
            continue;
        }
        if (!dispatchIDMatches(machine.ID(), ids)) {
            lease_released = true;
            releaseContextLease(machine);
            continue;
        }
        var routed_event = try cloneEventForQueue(context.allocator, event);
        defer routed_event.deinit();
        const target_id = machine.ID();
        try routed_event.setIdentity(routed_event.id, source_id, routed_event.target orelse target_id);
        const previous_dispatch_machine = context_dispatch_machine;
        context_dispatch_depth += 1;
        context_dispatch_machine = machine;
        const dispatch_result = machine.dispatch(context, routed_event);
        context_dispatch_machine = previous_dispatch_machine;
        context_dispatch_depth -= 1;
        lifecycle_lease.release();
        lifecycle_lease_active = false;
        lease_released = true;
        releaseContextLease(machine);
        if (context_dispatch_depth == 0 and takeDeferredDeinit(machine)) machine.deinit();
        try dispatch_result;
    }
}

pub const DispatchTo = dispatchTo;

const RuntimeOwner = struct {
    machine: StateMachine,
    owned_model: ?*Model,
    owned_queue: ?*InternalRuntimeQueue,
    transition_depth: std.atomic.Value(usize),
    operation_depth: std.atomic.Value(usize),
    allocator: std.mem.Allocator,
};

fn runtimeOwner(machine: *const StateMachine) ?*RuntimeOwner {
    const owner = machine.owned_model orelse return null;
    return @ptrCast(@alignCast(owner));
}

fn transitionDepth(machine: *const StateMachine) *std.atomic.Value(usize) {
    if (runtimeOwner(machine)) |owner| return &owner.transition_depth;
    return &runtime_fallback_transition_depth;
}

fn operationDepth(machine: *const StateMachine) *std.atomic.Value(usize) {
    if (runtimeOwner(machine)) |owner| return &owner.operation_depth;
    return &runtime_fallback_operation_depth;
}

fn canonicalMachine(machine: *StateMachine) *StateMachine {
    return if (runtimeOwner(machine)) |owner| &owner.machine else machine;
}

fn canonicalMachineConst(machine: *const StateMachine) *const StateMachine {
    return if (runtimeOwner(machine)) |owner| &owner.machine else machine;
}

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
        @compileError("MakeGroup expects a tuple, e.g. MakeGroup(allocator, .{ first, second })");
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

fn cloneTransitionSnapshot(allocator: std.mem.Allocator, transition_snapshot: *const TransitionSnapshot) !TransitionSnapshot {
    const name = try allocator.dupe(u8, transition_snapshot.Name);
    errdefer allocator.free(name);
    const source_name = try allocator.dupe(u8, transition_snapshot.Source);
    errdefer allocator.free(source_name);
    const target_name_copy = if (transition_snapshot.Target) |target_name| try allocator.dupe(u8, target_name) else null;
    errdefer if (target_name_copy) |target_name| allocator.free(target_name);
    const events = try allocator.alloc([]const u8, transition_snapshot.Events.len);
    var event_count: usize = 0;
    errdefer {
        for (events[0..event_count]) |event_name| allocator.free(event_name);
        allocator.free(events);
    }
    for (transition_snapshot.Events, 0..) |event_name, index| {
        events[index] = try allocator.dupe(u8, event_name);
        event_count += 1;
    }
    return TransitionSnapshot{
        .Name = name,
        .Kind = transition_snapshot.Kind,
        .Source = source_name,
        .Target = target_name_copy,
        .Events = events,
        .Guard = transition_snapshot.Guard,
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

    pub fn Instances(self: *const Self) []*StateMachine {
        return self.machines;
    }

    pub fn States(self: *const Self) ![][]const u8 {
        var states = try self.allocator.alloc([]const u8, self.machines.len);
        for (self.machines, 0..) |machine, index| states[index] = machine.state();
        return states;
    }

    pub fn State(self: *const Self) ![]const u8 {
        const states = try self.States();
        defer self.allocator.free(states);
        var joined = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer joined.deinit(self.allocator);
        for (states, 0..) |state_name, index| {
            if (index > 0) try joined.appendSlice(self.allocator, "\n");
            try joined.appendSlice(self.allocator, state_name);
        }
        return try joined.toOwnedSlice(self.allocator);
    }

    pub fn Snapshots(self: *Self) ![]Snapshot {
        var values = try self.allocator.alloc(Snapshot, self.machines.len);
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |*snapshot| snapshot.deinit();
            self.allocator.free(values);
        }
        for (self.machines) |machine| {
            values[initialized] = try machine.TakeSnapshot();
            initialized += 1;
        }
        return values;
    }

    pub fn snapshots(self: *Self) ![]Snapshot {
        return self.Snapshots();
    }

    pub fn Context(self: *const Self) ?*RuntimeContext {
        if (self.machines.len == 0) return null;
        return self.machines[0].context();
    }

    pub fn Clock(self: *const Self) RuntimeClock {
        if (self.machines.len == 0) return DefaultClock;
        return self.machines[0].Clock();
    }

    pub fn Stop(self: *Self) !void {
        for (self.machines) |machine| try machine.stop();
    }

    pub fn Restart(self: *Self) !void {
        for (self.machines) |machine| try machine.restart();
    }

    pub fn Dispatch(self: *Self, ctx: *RuntimeContext, event: Event) !void {
        try self.dispatch(ctx, event);
    }

    pub fn dispatch(self: *Self, ctx: *RuntimeContext, event: Event) !void {
        const owned_context_source = if (event.source == null) try duplicateContextSourceID(ctx.allocator, ctx) else null;
        defer if (owned_context_source) |source_id| ctx.allocator.free(source_id);
        const source_id = event.source orelse owned_context_source orelse self.id;
        for (self.machines) |machine| {
            if (machine.IsStopped()) continue;
            const target_id = machine.ID();
            var routed_event = try cloneEventForQueue(ctx.allocator, event);
            defer routed_event.deinit();
            try routed_event.setIdentity(routed_event.id, source_id, routed_event.target orelse target_id);
            try machine.Dispatch(ctx, routed_event);
        }
    }

    pub fn Set(self: *Self, ctx: *RuntimeContext, name: []const u8, value: anytype) !void {
        try self.set(ctx, name, value);
    }

    pub fn set(self: *Self, ctx: *RuntimeContext, name: []const u8, value: anytype) !void {
        for (self.machines) |machine| {
            try machine.Set(ctx, name, value);
        }
    }

    pub fn Call(self: *Self, ctx: *RuntimeContext, name: []const u8) !void {
        try self.call(ctx, name);
    }

    pub fn call(self: *Self, ctx: *RuntimeContext, name: []const u8) !void {
        if (self.machines.len == 0) return;
        try self.machines[0].Call(ctx, name);
    }

    pub fn CallWithData(self: *Self, ctx: *RuntimeContext, name: []const u8, data: ?*anyopaque) !void {
        try self.callWithData(ctx, name, data);
    }

    pub fn callWithData(self: *Self, ctx: *RuntimeContext, name: []const u8, data: ?*anyopaque) !void {
        if (self.machines.len == 0) return;
        try self.machines[0].CallWithData(ctx, name, data);
    }

    pub fn CallWithArgs(self: *Self, ctx: *RuntimeContext, name: []const u8, args: anytype) !void {
        try self.callWithArgs(ctx, name, args);
    }

    pub fn callWithArgs(self: *Self, ctx: *RuntimeContext, name: []const u8, args: anytype) !void {
        if (self.machines.len == 0) return;
        try self.machines[0].CallWithArgs(ctx, name, args);
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

        var transition_list = try std.ArrayList(TransitionSnapshot).initCapacity(self.allocator, 0);
        errdefer {
            for (transition_list.items) |*transition_snapshot| {
                transition_snapshot.deinit(self.allocator);
            }
            transition_list.deinit(self.allocator);
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
            try appendJoinedPart(&qualified_names, self.allocator, &qualified_name_first, ",", machine.Name());
            try appendJoinedPart(&states, self.allocator, &state_first, " | ", members[i].State);
            queue_len += members[i].QueueLen;

            for (members[i].Events) |*event| {
                try event_list.append(self.allocator, try cloneEventDetail(self.allocator, event));
            }
            for (members[i].Transitions) |*transition_snapshot| {
                try transition_list.append(self.allocator, try cloneTransitionSnapshot(self.allocator, transition_snapshot));
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
            .Transitions = try transition_list.toOwnedSlice(self.allocator),
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
pub const NewGroup = makeGroup;

/// Start a state machine with flat element model
pub fn start(ctx: *Context, instance: anytype, model: anytype) !*StateMachine {
    return try startWithConfig(ctx, instance, model, Config(.{}));
}

pub fn New(ctx: *Context, instance: anytype, model: anytype) !*StateMachine {
    return newWithConfig(ctx, instance, model, Config(.{}));
}

pub fn NewWithConfig(ctx: *Context, instance: anytype, model: anytype, config: RuntimeConfig) !*StateMachine {
    return newWithConfig(ctx, instance, model, config);
}

pub fn startWithConfig(ctx: *Context, instance: anytype, model: anytype, config: RuntimeConfig) !*StateMachine {
    const ModelArg = @TypeOf(model);
    if (ModelArg == type) {
        const owned_model = try ctx.allocator.create(Model);
        errdefer ctx.allocator.destroy(owned_model);
        owned_model.* = try model.build(ctx.allocator);
        errdefer owned_model.deinit();

        const sm = try startWithBuiltModel(ctx, instance, owned_model, config, true);
        const owner = runtimeOwner(sm) orelse return error.RuntimeOwnerMissing;
        owner.owned_model = owned_model;
        return sm;
    }

    return try startWithBuiltModel(ctx, instance, model, config, true);
}

fn newWithConfig(ctx: *Context, instance: anytype, model: anytype, config: RuntimeConfig) !*StateMachine {
    const ModelArg = @TypeOf(model);
    if (ModelArg == type) {
        const owned_model = try ctx.allocator.create(Model);
        errdefer ctx.allocator.destroy(owned_model);
        owned_model.* = try model.build(ctx.allocator);
        errdefer owned_model.deinit();

        const sm = try startWithBuiltModel(ctx, instance, owned_model, config, false);
        const owner = runtimeOwner(sm) orelse return error.RuntimeOwnerMissing;
        owner.owned_model = owned_model;
        return sm;
    }

    return try startWithBuiltModel(ctx, instance, model, config, false);
}

fn startWithBuiltModel(ctx: *Context, instance: anytype, model: *const Model, config: RuntimeConfig, start_machine: bool) !*StateMachine {
    const model_name = model.name;
    const root_state_name = try std.fmt.allocPrint(ctx.allocator, "/{s}", .{model_name});
    defer ctx.allocator.free(root_state_name);
    _ = getState(model, root_state_name) orelse return error.NoRootState;

    const owned_queue = if (config.Queue == null) try InternalRuntimeQueue.init(ctx.allocator) else null;
    var queue_needs_cleanup = true;
    defer if (queue_needs_cleanup) if (owned_queue) |queue| queue.deinit();

    const runtime_name = if (config.Name) |name| try ctx.allocator.dupe(u8, name) else null;
    var identity_needs_cleanup = true;
    defer if (identity_needs_cleanup) {
        if (runtime_name) |name| ctx.allocator.free(name);
    };

    const configured_id = config.ID orelse "";
    const runtime_id = if (configured_id.len > 0) try ctx.allocator.dupe(u8, configured_id) else blk: {
        const sequence = runtime_id_sequence.fetchAdd(1, .monotonic);
        break :blk try std.fmt.allocPrint(ctx.allocator, "{s}_{d}", .{ runtime_name orelse model_name, sequence });
    };
    defer if (identity_needs_cleanup) ctx.allocator.free(runtime_id);

    const machine = StateMachine{
        .model = model,
        .instance = instance,
        ._context = ctx,
        .current_state = canonicalStateName(model, root_state_name),
        .active_states = try std.ArrayList([]const u8).initCapacity(ctx.allocator, 0),
        .active_activities = std.StringHashMap(ActivityHandle).init(ctx.allocator),
        .active_timers = std.StringHashMap(TimerHandle).init(ctx.allocator),
        .history_value = std.StringHashMap([]const u8).init(ctx.allocator),
        .deferred_queue = try EventQueue.init(ctx.allocator),
        .attributes = std.StringHashMap(RuntimeAttributeValue).init(ctx.allocator),
        .runtime_id = runtime_id,
        .runtime_name = runtime_name,
        .runtime_data = config.Data,
        .clock = config.Clock orelse DefaultClock,
        .regular_queue = if (owned_queue) |queue| &queue.runtime_queue else config.Queue,
        .activity_timeout_ns = if (config.ActivityTimeoutNs == 0) 5 * std.time.ns_per_s else config.ActivityTimeoutNs,
        .stopped = true,
        .owned_model = null,
        .allocator = ctx.allocator,
    };

    const owner = try ctx.allocator.create(RuntimeOwner);
    owner.* = .{
        .machine = machine,
        .owned_model = null,
        .owned_queue = owned_queue,
        .transition_depth = std.atomic.Value(usize).init(0),
        .operation_depth = std.atomic.Value(usize).init(0),
        .allocator = ctx.allocator,
    };
    errdefer {
        owner.machine.deinit();
    }
    queue_needs_cleanup = false;

    const sm = &owner.machine;
    sm.owned_model = @ptrCast(owner);
    // The owner now exclusively owns the identity allocations. Any later
    // failure tears them down through owner.machine.deinit().
    identity_needs_cleanup = false;
    try registerLifecycleGate(sm);

    if (modelHasHistory(model)) try sm.history_value.ensureTotalCapacity(1);
    if (modelHasTimers(model)) try sm.active_timers.ensureTotalCapacity(1);
    try sm.initializeAttributes();

    if (start_machine) try sm.start();

    return sm;
}

pub const Start = start;
pub const StartWithConfig = startWithConfig;

/// Start a state machine and return its owning public handle.
pub fn Started(ctx: *Context, instance: anytype, model: anytype) !*StateMachine {
    return start(ctx, instance, model);
}

/// Start a state machine with explicit runtime configuration.
pub fn StartedWithConfig(ctx: *Context, instance: anytype, model: anytype, config: RuntimeConfig) !*StateMachine {
    return startWithConfig(ctx, instance, model, config);
}

pub fn Get(machine: *StateMachine, name: []const u8) !?*anyopaque {
    return try machine.Get(name);
}

pub fn Set(machine: *StateMachine, ctx: *Context, name: []const u8, value: anytype) !void {
    try machine.Set(ctx, name, value);
}

pub fn Call(machine: *StateMachine, ctx: *Context, name: []const u8) !void {
    try machine.Call(ctx, name);
}

pub fn CallWithData(machine: *StateMachine, ctx: *Context, name: []const u8, data: ?*anyopaque) !void {
    try machine.CallWithData(ctx, name, data);
}

pub fn CallWithArgs(machine: *StateMachine, ctx: *Context, name: []const u8, args: anytype) !void {
    try machine.CallWithArgs(ctx, name, args);
}

pub fn TakeSnapshot(machine: *StateMachine) !Snapshot {
    return try machine.TakeSnapshot();
}

/// Stop a state machine
pub fn stop(sm: *StateMachine) !void {
    try sm.stop();
}

pub fn restart(sm: *StateMachine) !void {
    try sm.restart();
}

pub fn Dispatch(machine: *StateMachine, ctx: *Context, event: Event) !void {
    try machine.dispatch(ctx, event);
}

pub fn Stop(machine: *StateMachine) !void {
    try machine.stop();
}

/// Stop active work and re-enter the model's initial state through the
/// existing owner-backed machine value.
pub fn Restart(machine: *StateMachine) !void {
    return restart(machine);
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
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

    const has_null_default = comptime has_default and @TypeOf(default_value) == @TypeOf(null);
    const ValueType = if (maybe_type) |T| T else if (has_default and !has_null_default) @TypeOf(default_value) else void;
    var stored_default: ?*anyopaque = null;
    errdefer if (stored_default) |value| dropTypedValue(ValueType)(model.allocator, value);

    if (has_default and !has_null_default) {
        if (maybe_type) |T| {
            if (@TypeOf(default_value) != T) return error.AttributeTypeMismatch;
        }
        stored_default = (try makeUnregisteredAttributeValue(model.allocator, default_value)).value;
    }

    const key = try model.allocator.dupe(u8, qualified_name);
    errdefer model.allocator.free(key);

    try model.attributes.put(key, AttributeElement{
        .name = try model.allocator.dupe(u8, name),
        .qualified_name = qualified_name,
        .type_name = if (maybe_type) |_| @typeName(ValueType) else null,
        .default_value = stored_default,
        .clone_fn = if (maybe_type != null or (has_default and !has_null_default)) cloneTypedValue(ValueType) else null,
        .drop_fn = if (maybe_type != null or (has_default and !has_null_default)) dropTypedValue(ValueType) else null,
    });
}

fn ensureImplicitAttribute(model: *Model, name: []const u8) !void {
    const qualified_name = try qualifyModelMemberName(model.allocator, model.name, name);
    defer model.allocator.free(qualified_name);

    if (model.attributes.contains(qualified_name)) return;
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

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
pub fn addState(model: *Model, qualified_name: []const u8, kind: ElementType) !*StateElement {
    var member_key = qualified_name;
    var duplicate_key: ?[]const u8 = null;
    if (model.members.contains(qualified_name)) {
        duplicate_key = try std.fmt.allocPrint(model.allocator, "{s}#duplicate_{}", .{ qualified_name, model.members.count() });
        member_key = duplicate_key.?;
    }
    errdefer if (duplicate_key) |key| model.allocator.free(key);

    const state_element = try model.allocator.create(StateElement);
    errdefer model.allocator.destroy(state_element);
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

    if (duplicate_key == null) member_key = state_element.element.qualified_name;
    try model.members.put(member_key, @ptrCast(state_element));
    duplicate_key = null;
    return state_element;
}

/// Add a transient entry or exit connection point to the flat model index.
pub fn addConnectionPoint(model: *Model, qualified_name: []const u8, kind: ElementType) !*ConnectionPointElement {
    if (kind != .entry_point and kind != .exit_point) return ValidationError.InvalidTransitionTarget;
    var member_key = qualified_name;
    var duplicate_key: ?[]const u8 = null;
    if (model.members.contains(qualified_name)) {
        duplicate_key = try std.fmt.allocPrint(model.allocator, "{s}#duplicate_{}", .{ qualified_name, model.members.count() });
        member_key = duplicate_key.?;
    }
    errdefer if (duplicate_key) |key| model.allocator.free(key);

    const point = try model.allocator.create(ConnectionPointElement);
    errdefer model.allocator.destroy(point);
    point.* = .{
        .element = .{
            .kind = kind,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .transitions = &[_][]const u8{},
    };
    errdefer {
        model.allocator.free(point.element.qualified_name);
        model.allocator.free(point.element.id);
    }
    if (duplicate_key == null) member_key = point.element.qualified_name;
    try model.members.put(member_key, @ptrCast(point));
    duplicate_key = null;
    return point;
}

/// Add a behavior element to the model
pub fn addBehavior(model: *Model, qualified_name: []const u8, function_ptr: *const anyopaque) !*BehaviorElement {
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

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
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

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
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

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
    if (model.members.contains(qualified_name)) {
        return ValidationError.DuplicateMemberName;
    }

    const transition_element = try model.allocator.create(TransitionElement);
    transition_element.* = TransitionElement{
        .element = Element{
            .kind = .transition,
            .qualified_name = try model.allocator.dupe(u8, qualified_name),
            .id = try model.allocator.dupe(u8, std.fs.path.basename(qualified_name)),
        },
        .kind = TransitionKind,
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

pub fn setTransitionKind(transition_element: *TransitionElement, kind: u64) !void {
    if (!isKind(kind, TransitionKind)) return error.InvalidTransitionKind;
    transition_element.kind = kind;
}

pub const SetTransitionKind = setTransitionKind;

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
        return element.kind == .state or element.kind == .submachine or element.kind == .model or element.kind == .final or element.kind == .choice or element.kind == .history or
            element.kind == .entry_point or element.kind == .exit_point;
    }
    return false;
}

fn sourceExists(model: *const Model, candidate: []const u8) bool {
    if (model.members.get(candidate)) |element| {
        return element.kind == .state or element.kind == .submachine or element.kind == .model or element.kind == .choice or
            element.kind == .history or element.kind == .entry_point or element.kind == .exit_point;
    }
    return false;
}

fn firstExistingTarget(model: *const Model, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (targetExists(model, candidate)) return candidate;
    }
    return null;
}

fn canonicalizeTransitionSource(model: *const Model, allocator: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    const normalized_source = try normalizePath(allocator, source_path);
    defer allocator.free(normalized_source);

    if (!sourceExists(model, normalized_source)) return error.InvalidTransitionSource;
    return try allocator.dupe(u8, normalized_source);
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
        const canonical_source = try canonicalizeTransitionSource(model, model.allocator, trans.source);
        model.allocator.free(trans.source);
        trans.source = canonical_source;
        if (trans.target) |target_path| {
            var canonical: []const u8 = undefined;
            var entry_effects: ?[][]const u8 = null;
            defer if (entry_effects) |effects| model.allocator.free(effects);
            if (std.mem.startsWith(u8, target_path, entryPointTargetMarker)) {
                const encoded = target_path[entryPointTargetMarker.len..];
                const separator = std.mem.lastIndexOfScalar(u8, encoded, '|') orelse return ValidationError.InvalidTransitionTarget;
                const raw_target = encoded[0..separator];
                const point_name = encoded[separator + 1 ..];
                const boundary = try canonicalizeTransitionTarget(model, model.allocator, trans.source, raw_target);
                defer model.allocator.free(boundary);
                const boundary_element = model.members.get(boundary) orelse return ValidationError.InvalidTransitionTarget;
                if (boundary_element.kind != .submachine) return ValidationError.InvalidTransitionTarget;
                const point_path = try std.fmt.allocPrint(model.allocator, "{s}/{s}", .{ boundary, point_name });
                defer model.allocator.free(point_path);
                const point_element = model.members.get(point_path) orelse return ValidationError.InvalidTransitionTarget;
                if (point_element.kind != .entry_point) return ValidationError.InvalidTransitionTarget;
                const point = @as(*ConnectionPointElement, @ptrCast(@alignCast(point_element)));
                if (point.transitions.len != 1) return ValidationError.InvalidTransitionTarget;
                const point_transition = getTransition(model, point.transitions[0]) orelse return ValidationError.InvalidTransitionTarget;
                if (point_transition.target == null) return ValidationError.InvalidTransitionTarget;
                // Keep the point as the transition target.  The runtime then
                // enters it after the transition effects, preserving the
                // point's boundary semantics.
                canonical = try model.allocator.dupe(u8, point_path);
                if (point_transition.effects.len > 0) {
                    entry_effects = try model.allocator.alloc([]const u8, point_transition.effects.len);
                    for (point_transition.effects, 0..) |effect_name, index| {
                        entry_effects.?[index] = try model.allocator.dupe(u8, effect_name);
                    }
                }
            } else {
                canonical = try canonicalizeTransitionTarget(model, model.allocator, trans.source, target_path);
            }
            model.allocator.free(target_path);
            trans.target = canonical;
            if (entry_effects) |point_effects| {
                const old_effects = trans.effects;
                const combined = try model.allocator.alloc([]const u8, old_effects.len + point_effects.len);
                @memcpy(combined[0..old_effects.len], old_effects);
                @memcpy(combined[old_effects.len..], point_effects);
                if (old_effects.len > 0) model.allocator.free(old_effects);
                trans.effects = combined;
            }
        }
    }
}

fn finalizeTransitionKinds(model: *Model) void {
    var iterator = model.members.iterator();
    while (iterator.next()) |member_entry| {
        if (member_entry.value_ptr.*.kind != .transition) continue;
        const trans = @as(*TransitionElement, @ptrCast(@alignCast(member_entry.value_ptr.*)));
        if (trans.kind != TransitionKind) continue;

        if (trans.target) |target_path| {
            const target_element = model.members.get(target_path);
            if (target_element != null and target_element.?.kind == .entry_point and
                std.mem.eql(u8, trans.source, target_element.?.owner()))
            {
                trans.kind = ExternalKind;
            } else if (std.mem.eql(u8, trans.source, target_path)) {
                trans.kind = SelfKind;
            } else if (isAncestor(trans.source, target_path)) {
                trans.kind = LocalKind;
            } else {
                trans.kind = ExternalKind;
            }
        } else {
            trans.kind = InternalKind;
        }
    }
}

pub const FinalizeTransitionKinds = finalizeTransitionKinds;

fn appendTransitionIndex(
    allocator: std.mem.Allocator,
    event_map: *std.StringHashMap([][]const u8),
    event_name: []const u8,
    transition_name: []const u8,
) !void {
    if (event_map.getPtr(event_name)) |transition_list| {
        const old_list = transition_list.*;
        const new_list = try allocator.alloc([]const u8, old_list.len + 1);
        errdefer allocator.free(new_list);
        @memcpy(new_list[0..old_list.len], old_list);
        new_list[old_list.len] = try allocator.dupe(u8, transition_name);
        transition_list.* = new_list;
        allocator.free(old_list);
        return;
    }

    const event_key = try allocator.dupe(u8, event_name);
    errdefer allocator.free(event_key);
    const transition_list = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(transition_list);
    transition_list[0] = try allocator.dupe(u8, transition_name);
    try event_map.put(event_key, transition_list);
}

fn appendTimerTransitionIndex(
    allocator: std.mem.Allocator,
    event_map: *std.StringHashMap([][]const u8),
    trans: *const TransitionElement,
) !void {
    const prefix = if (trans.timer_kind == .every) "_periodic:" else "_timeout:";
    const event_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, trans.element.qualified_name });
    defer allocator.free(event_name);
    try appendTransitionIndex(allocator, event_map, event_name, trans.element.qualified_name);
}

fn historyDefaultOrdinal(transition_name: []const u8) ?usize {
    const marker = "/__history_default_";
    const marker_index = std.mem.lastIndexOf(u8, transition_name, marker) orelse return null;
    const digits = transition_name[marker_index + marker.len ..];
    if (digits.len == 0) return null;
    var ordinal: usize = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return null;
        ordinal = std.math.mul(usize, ordinal, 10) catch return null;
        ordinal = std.math.add(usize, ordinal, digit - '0') catch return null;
    }
    return ordinal;
}

fn historyDefaultLessThan(_: void, left: []const u8, right: []const u8) bool {
    const left_ordinal = historyDefaultOrdinal(left) orelse std.math.maxInt(usize);
    const right_ordinal = historyDefaultOrdinal(right) orelse std.math.maxInt(usize);
    if (left_ordinal != right_ordinal) return left_ordinal < right_ordinal;
    return std.mem.order(u8, left, right) == .lt;
}

fn appendExitPointAliases(
    model: *Model,
    event_map: *std.StringHashMap([][]const u8),
    trans: *TransitionElement,
) !void {
    const event_name = trans.event_name orelse return;
    if (!std.mem.startsWith(u8, event_name, "hsm_exit:")) return;
    const separator = std.mem.lastIndexOfScalar(u8, event_name, '/') orelse return;
    const point_name = event_name[separator + 1 ..];
    var iter = model.members.iterator();
    while (iter.next()) |member_entry| {
        const element = member_entry.value_ptr.*;
        if (element.kind != .exit_point or !std.mem.eql(u8, element.name(), point_name)) continue;
        const owner = element.owner();
        if (std.mem.eql(u8, owner, trans.source) or !stateMatchesOrIsDescendant(owner, trans.source)) continue;
        const alias = try exitPointEventName(model.allocator, owner, point_name);
        defer model.allocator.free(alias);
        try appendTransitionIndex(model.allocator, event_map, alias, trans.element.qualified_name);
    }
}

fn deinitTransitionMap(
    allocator: std.mem.Allocator,
    transition_map: *std.StringHashMap(std.StringHashMap([][]const u8)),
) void {
    var state_iter = transition_map.iterator();
    while (state_iter.next()) |state_entry| {
        allocator.free(state_entry.key_ptr.*);
        var event_iter = state_entry.value_ptr.iterator();
        while (event_iter.next()) |event_entry| {
            allocator.free(event_entry.key_ptr.*);
            for (event_entry.value_ptr.*) |transition_name| {
                allocator.free(transition_name);
            }
            allocator.free(event_entry.value_ptr.*);
        }
        state_entry.value_ptr.deinit();
    }
    transition_map.deinit();
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

    const self_transition = trans.kind == SelfKind;
    const local_transition = trans.kind == LocalKind;
    if (trans.kind != InternalKind) {
        if (trans.target) |target_path| {
            // Resolve the target path relative to source
            const resolved_target = try resolveTargetPath(model.allocator, source_state, target_path);
            defer model.allocator.free(resolved_target);
            const target_is_entry_point = if (model.members.get(resolved_target)) |target_element|
                target_element.kind == .entry_point
            else
                false;

            // A transition declared on a composite state with target(".") has an
            // effective source and target that are the same state. When it is
            // dispatched from a child, the child must be exited and the effective
            // source re-entered so its initial transition runs. This is distinct
            // from a child-owned target(".."), whose effective source and target
            // differ and which intentionally lands on the parent.
            if (std.mem.eql(u8, trans.source, trans.target.?)) {
                if (std.mem.eql(u8, source_state, trans.source)) {
                    try exit_states.append(model.allocator, try model.allocator.dupe(u8, source_state));
                } else if (stateMatchesOrIsDescendant(source_state, trans.source)) {
                    try exit_states.append(model.allocator, try model.allocator.dupe(u8, trans.source));
                    try appendPathAncestors(model.allocator, &exit_states, source_state, trans.source);
                }
                try enter_states.append(model.allocator, try model.allocator.dupe(u8, trans.source));
            } else if (target_is_entry_point) {
                // Entry-point targets are transient vertices under a submachine
                // boundary.  Enter the boundary and then the point so the point
                // handler selects the nested target without falling through the
                // boundary's initial transition.
                const boundary = model.members.get(resolved_target).?.owner();
                const common_ancestor = if (self_transition)
                    try model.allocator.dupe(u8, pathDir(trans.source))
                else if (std.mem.eql(u8, trans.source, boundary))
                    try model.allocator.dupe(u8, std.fs.path.dirname(boundary) orelse "")
                else
                    try commonAncestorPath(model.allocator, source_state, boundary);
                defer model.allocator.free(common_ancestor);
                try appendPathAncestors(model.allocator, &exit_states, source_state, common_ancestor);
                try appendDescendantPath(model.allocator, &enter_states, common_ancestor, resolved_target);
            } else if (std.mem.eql(u8, source_state, resolved_target)) {
                // Direct self transition: exit and re-enter the active state.
                try exit_states.append(model.allocator, try model.allocator.dupe(u8, source_state));
                try enter_states.append(model.allocator, try model.allocator.dupe(u8, resolved_target));
            } else {
                const common_ancestor = if (self_transition)
                    try model.allocator.dupe(u8, pathDir(trans.source))
                else if (local_transition and
                    model.members.get(resolved_target) != null and
                    model.members.get(resolved_target).?.kind == .submachine and
                    stateMatchesOrIsDescendant(source_state, resolved_target))
                    try model.allocator.dupe(u8, pathDir(resolved_target))
                else
                    try commonAncestorPath(model.allocator, source_state, resolved_target);
                defer model.allocator.free(common_ancestor);
                try appendPathAncestors(model.allocator, &exit_states, source_state, common_ancestor);
                try appendDescendantPath(model.allocator, &enter_states, common_ancestor, resolved_target);
                if (std.mem.eql(u8, common_ancestor, resolved_target)) {
                    try enter_states.append(model.allocator, try model.allocator.dupe(u8, resolved_target));
                }
            }
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
    deinitTransitionMap(model.allocator, &model.transition_map);
    model.transition_map = std.StringHashMap(std.StringHashMap([][]const u8)).init(model.allocator);

    var indexed_transitions = std.StringHashMap(void).init(model.allocator);
    defer indexed_transitions.deinit();

    // Iterate through each state's transition list to preserve declaration order.
    var members_iter = model.members.iterator();
    while (members_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .state and element.kind != .submachine and element.kind != .model and element.kind != .choice and element.kind != .final) continue;

        const state_elem: *StateElement = @ptrCast(@alignCast(element));

        // Preserve a map bucket for every dispatchable state, including states
        // with no locally declared transitions.
        if (model.transition_map.getPtr(state_elem.element.qualified_name) == null) {
            const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
            try model.transition_map.put(try model.allocator.dupe(u8, state_elem.element.qualified_name), new_event_map);
        }

        for (state_elem.transitions) |transition_name| {
            const trans = getTransition(model, transition_name) orelse continue;
            if (indexed_transitions.contains(trans.element.qualified_name)) continue;
            try indexed_transitions.put(trans.element.qualified_name, {});

            const source_state = trans.source;

            // Get or create event map for the transition's effective source.
            var event_map = model.transition_map.getPtr(source_state);
            if (event_map == null) {
                const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
                try model.transition_map.put(try model.allocator.dupe(u8, source_state), new_event_map);
                event_map = model.transition_map.getPtr(source_state);
            }

            if (trans.event_name) |event_name| {
                try appendTransitionIndex(model.allocator, event_map.?, event_name, trans.element.qualified_name);
                try appendExitPointAliases(model, event_map.?, trans);
            }
            if (trans.timer_fn != null and trans.event_name == null) {
                try appendTimerTransitionIndex(model.allocator, event_map.?, trans);
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
        if (indexed_transitions.contains(trans.element.qualified_name)) continue;
        try indexed_transitions.put(trans.element.qualified_name, {});

        var event_map = model.transition_map.getPtr(trans.source);
        if (event_map == null) {
            const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
            try model.transition_map.put(try model.allocator.dupe(u8, trans.source), new_event_map);
            event_map = model.transition_map.getPtr(trans.source);
        }

        if (trans.event_name) |event_name| {
            if (!std.mem.endsWith(u8, trans.element.qualified_name, "/.initial")) {
                try appendTransitionIndex(model.allocator, event_map.?, event_name, trans.element.qualified_name);
                try appendExitPointAliases(model, event_map.?, trans);
            }
        } else if (trans.timer_fn != null and trans.event_name == null) {
            try appendTimerTransitionIndex(model.allocator, event_map.?, trans);
        } else if (model.members.get(trans.source)) |source_element| {
            if (source_element.kind == .history) {
                try appendTransitionIndex(model.allocator, event_map.?, "", trans.element.qualified_name);
            }
        }
        try computeTransitionPaths(model, trans, trans.source);
    }

    // The JSON runner names history defaults with their declaration ordinal.
    // The member index is a hash map, so restore that explicit order before
    // the history bucket is copied into the expanded average O(1) dispatch map.
    var history_defaults_iter = model.transition_map.iterator();
    while (history_defaults_iter.next()) |state_entry| {
        const state_element = model.members.get(state_entry.key_ptr.*) orelse continue;
        if (state_element.kind != .history) continue;
        if (state_entry.value_ptr.getPtr("")) |transition_names| {
            std.sort.block([]const u8, transition_names.*, {}, historyDefaultLessThan);
        }
    }

    // Ancestor transitions are indexed into descendant state buckets. Prepare
    // the corresponding exit/entry paths for those descendants as well, so
    // timer and other bubbled dispatches retain average O(1) runtime path lookup.
    var ancestor_transition_iter = model.members.iterator();
    while (ancestor_transition_iter.next()) |transition_entry| {
        const element = transition_entry.value_ptr.*;
        if (element.kind != .transition) continue;
        const trans: *TransitionElement = @ptrCast(@alignCast(element));

        var descendant_iter = model.members.iterator();
        while (descendant_iter.next()) |state_entry| {
            const state_element = state_entry.value_ptr.*;
            if (state_element.kind != .state and state_element.kind != .submachine and
                state_element.kind != .model and state_element.kind != .choice and
                state_element.kind != .final) continue;
            const descendant_path = state_element.qualified_name;
            if (std.mem.eql(u8, descendant_path, trans.source) or
                !stateMatchesOrIsDescendant(descendant_path, trans.source)) continue;
            try computeTransitionPaths(model, trans, descendant_path);
        }
    }

    // Expand each dispatchable state's local event buckets with its ancestor
    // buckets. Local transitions are appended first, then immediate-parent and
    // higher-ancestor transitions, preserving declaration order within each
    // source while making ordinary dispatch a single current-state lookup.
    var expanded_map = std.StringHashMap(std.StringHashMap([][]const u8)).init(model.allocator);
    var expanded_map_installed = false;
    errdefer if (!expanded_map_installed) deinitTransitionMap(model.allocator, &expanded_map);

    var state_iter = model.members.iterator();
    while (state_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .state and element.kind != .submachine and element.kind != .model and element.kind != .choice and element.kind != .final) continue;

        const state_elem: *StateElement = @ptrCast(@alignCast(element));
        var expanded_event_map = std.StringHashMap([][]const u8).init(model.allocator);
        var event_map_installed = false;
        errdefer if (!event_map_installed) {
            var event_iter = expanded_event_map.iterator();
            while (event_iter.next()) |event_entry| {
                model.allocator.free(event_entry.key_ptr.*);
                for (event_entry.value_ptr.*) |transition_name| {
                    model.allocator.free(transition_name);
                }
                model.allocator.free(event_entry.value_ptr.*);
            }
            expanded_event_map.deinit();
        };

        var source_path = state_elem.element.qualified_name;
        while (true) {
            if (model.transition_map.get(source_path)) |local_event_map| {
                var event_iter = local_event_map.iterator();
                while (event_iter.next()) |event_entry| {
                    for (event_entry.value_ptr.*) |transition_name| {
                        try appendTransitionIndex(model.allocator, &expanded_event_map, event_entry.key_ptr.*, transition_name);
                    }
                }
            }

            if (std.mem.eql(u8, source_path, "/")) break;
            source_path = std.fs.path.dirname(source_path) orelse break;
        }

        const state_key = try model.allocator.dupe(u8, state_elem.element.qualified_name);
        errdefer model.allocator.free(state_key);
        try expanded_map.put(state_key, expanded_event_map);
        event_map_installed = true;
    }

    var history_iter = model.members.iterator();
    while (history_iter.next()) |history_entry| {
        if (history_entry.value_ptr.*.kind != .history) continue;
        const history_path = history_entry.value_ptr.*.qualified_name;
        const source_event_map = model.transition_map.get(history_path) orelse continue;
        var history_event_map = std.StringHashMap([][]const u8).init(model.allocator);
        var event_iter = source_event_map.iterator();
        while (event_iter.next()) |event_entry| {
            for (event_entry.value_ptr.*) |transition_name| {
                try appendTransitionIndex(model.allocator, &history_event_map, event_entry.key_ptr.*, transition_name);
            }
        }
        try expanded_map.put(try model.allocator.dupe(u8, history_path), history_event_map);
    }

    // Inherited transitions must have paths for every dispatchable descendant
    // before the model becomes visible to runtimes. Runtime dispatch remains a
    // read-only average O(1) lookup instead of lazily mutating shared model storage.
    var expanded_state_iter = expanded_map.iterator();
    while (expanded_state_iter.next()) |state_entry| {
        var expanded_event_iter = state_entry.value_ptr.iterator();
        while (expanded_event_iter.next()) |event_entry| {
            for (event_entry.value_ptr.*) |transition_name| {
                const trans = getTransition(model, transition_name) orelse continue;
                if (trans.paths.get(state_entry.key_ptr.*) == null) {
                    try computeTransitionPaths(model, trans, state_entry.key_ptr.*);
                }
            }
        }
    }

    deinitTransitionMap(model.allocator, &model.transition_map);
    model.transition_map = expanded_map;
    expanded_map_installed = true;
}

/// Build deferred event map for average O(1) deferred event lookup
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
        if (element.kind != .state and element.kind != .submachine and element.kind != .model) continue;

        const state_elem: *StateElement = @ptrCast(@alignCast(element));
        const state_name = state_elem.element.qualified_name;

        // Create event map for this state
        var event_map = std.StringHashMap(bool).init(model.allocator);

        // Collect deferred events from this state and all parent states
        var current_path = state_name;
        while (current_path.len > 0) {
            if (model.members.get(current_path)) |current_element| {
                if (current_element.kind == .state or current_element.kind == .submachine or current_element.kind == .model) {
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

test "runtime constructors return the owning StateMachine pointer" {
    const model_type = comptime Define("PointerOwnedMachine", .{
        Initial(Target("idle")),
        State("idle", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var context = Context.init(testing.allocator);
    var instance = Instance.init();
    defer instance.deinit();

    const machine = try Start(&context, &instance, &model);
    try testing.expect(@TypeOf(machine) == *StateMachine);
    try testing.expect(&runtimeOwner(machine).?.machine == machine);

    machine.deinit();
    try testing.expect(fromContext(&context) == null);
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

test "EventQueue preserves FIFO order across wrapped growth" {
    var queue = try EventQueue.init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(Event.init(testing.allocator, "first"));
    try queue.enqueue(Event.init(testing.allocator, "second"));
    try queue.enqueue(Event.init(testing.allocator, "third"));

    var first = queue.dequeue().?;
    defer first.deinit();
    try testing.expectEqualStrings("first", first.name);

    try queue.enqueue(Event.init(testing.allocator, "fourth"));
    try queue.enqueue(Event.init(testing.allocator, "fifth"));
    try queue.enqueue(Event.init(testing.allocator, "sixth"));

    var second = queue.dequeue().?;
    defer second.deinit();
    try testing.expectEqualStrings("second", second.name);

    var third = queue.dequeue().?;
    defer third.deinit();
    try testing.expectEqualStrings("third", third.name);

    var fourth = queue.dequeue().?;
    defer fourth.deinit();
    try testing.expectEqualStrings("fourth", fourth.name);

    var fifth = queue.dequeue().?;
    defer fifth.deinit();
    try testing.expectEqualStrings("fifth", fifth.name);

    var sixth = queue.dequeue().?;
    defer sixth.deinit();
    try testing.expectEqualStrings("sixth", sixth.name);

    try testing.expect(queue.isEmpty());
}

test "deferred replay preserves FIFO order" {
    const model_type = comptime Define("DeferredReplayModel", .{
        Initial(Target("waiting")),
        State("waiting", .{
            DeferEvents(.{ "first", "second" }),
            Transition(.{ On("release"), Target("../ready") }),
        }),
        State("ready", .{
            Transition(.{ On("first"), Target("../after_first") }),
        }),
        State("after_first", .{
            Transition(.{ On("second"), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    var ctx = Context.init(testing.allocator);
    var inst = Instance.init();
    var sm = try Start(&ctx, &inst, &model);
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "first"));
    try sm.Dispatch(&ctx, Event.init(testing.allocator, "second"));
    try testing.expectEqualStrings("/DeferredReplayModel/waiting", sm.state());

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "release"));
    try testing.expectEqualStrings("/DeferredReplayModel/done", sm.state());
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

fn snapshotTimerFn(ctx: *Context, inst: *Instance, event: Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return 60_000_000_000;
}

fn shortTimerFn(ctx: *Context, inst: *Instance, event: Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return std.time.ns_per_ms;
}

fn deinitFromTimer(ctx: *Context, inst: *Instance, event: Event) void {
    _ = inst;
    _ = event;
    if ((fromContextLease(ctx) catch null)) |lease_value| {
        var lease = lease_value;
        defer lease.release();
        lease.Machine().deinit();
    }
}

const LifecycleRaceInstance = struct {
    base: Instance = Instance.init(),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn lifecycleRaceEffect(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *LifecycleRaceInstance = @ptrCast(@alignCast(inst));
    test_inst.entered.store(true, .release);
    std.Thread.sleep(20 * std.time.ns_per_ms);
    test_inst.completed.store(true, .release);
}

const LifecycleDispatchArgs = struct {
    machine: *StateMachine,
    context: *Context,
    event: *Event,
};

fn lifecycleDispatchThread(args: LifecycleDispatchArgs) void {
    _ = args.machine.dispatch(args.context, args.event.*) catch {};
}

var concurrent_deinit_exit_entered = std.atomic.Value(bool).init(false);
var concurrent_deinit_exit_release = std.atomic.Value(bool).init(false);

fn concurrentDeinitExit(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    concurrent_deinit_exit_entered.store(true, .release);
    while (!concurrent_deinit_exit_release.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn concurrentDeinitThread(machine: *StateMachine) void {
    machine.deinit();
}

fn releaseConcurrentDeinitExit() void {
    std.Thread.sleep(std.time.ns_per_ms);
    concurrent_deinit_exit_release.store(true, .release);
}

const QueueTestInstance = struct {
    base: Instance = Instance.init(),
    hit: bool = false,
};

var queue_stop_exit_count = std.atomic.Value(usize).init(0);

fn queueStopExit(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    _ = queue_stop_exit_count.fetchAdd(1, .acq_rel);
}

var timeout_activity_started = std.atomic.Value(bool).init(false);
var timeout_activity_release = std.atomic.Value(bool).init(false);

fn nonCooperativeActivity(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    timeout_activity_started.store(true, .release);
    while (!timeout_activity_release.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

const AttributeTestInstance = struct {
    base: Instance = Instance.init(),
};

var last_change_event_kind: u64 = 0;
var last_change_event_name: []const u8 = "";
var last_change_event_source: []const u8 = "";

fn recordChangeEvent(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = inst;
    last_change_event_kind = event.kind;
    last_change_event_source = event.source orelse "";
    last_change_event_name = event.name;
}

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
    saw_call_kind: bool = false,
};

fn recordOperation(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    const test_inst: *OperationTestInstance = @ptrCast(@alignCast(inst));
    test_inst.calls += 1;
    test_inst.saw_call_event = std.mem.eql(u8, event.name, "hsm_call:/OperationModel/record");
    test_inst.saw_call_kind = event.kind == CallEventKind;
}

fn recordCallEffect(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    const test_inst: *OperationTestInstance = @ptrCast(@alignCast(inst));
    test_inst.effects += 1;
    test_inst.saw_call_event = std.mem.eql(u8, event.name, "hsm_call:/OperationModel/record");
    test_inst.saw_call_kind = event.kind == CallEventKind;
}

const RecordingQueue = struct {
    events: EventQueue,
    pushes: usize = 0,
    pops: usize = 0,
    lens: usize = 0,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .events = try EventQueue.init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.events.deinit();
    }

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pushes += 1;
        try self.events.enqueue(event);
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) anyerror!?Event {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pops += 1;
        return self.events.dequeue();
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) anyerror!usize {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.lens += 1;
        return self.events.len();
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

const FailingLenQueue = struct {
    len_calls: usize = 0,

    const Self = @This();

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void {
        _ = context;
        _ = runtime_context;
        _ = event;
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) anyerror!?Event {
        _ = context;
        _ = runtime_context;
        return null;
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) anyerror!usize {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.len_calls += 1;
        return error.QueueLenFailed;
    }
};

const FailingPopQueue = struct {
    events: EventQueue,
    pops: usize = 0,
    persistent: bool,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, persistent: bool) !Self {
        return .{
            .events = try EventQueue.init(allocator),
            .persistent = persistent,
        };
    }

    fn deinit(self: *Self) void {
        self.events.deinit();
    }

    fn push(context: ?*anyopaque, runtime_context: *Context, event: Event) anyerror!void {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        try self.events.enqueue(event);
    }

    fn pop(context: ?*anyopaque, runtime_context: *Context) anyerror!?Event {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        self.pops += 1;
        if (self.persistent or self.pops == 1) return error.QueuePopFailed;
        return self.events.dequeue();
    }

    fn len(context: ?*anyopaque, runtime_context: *Context) anyerror!usize {
        _ = runtime_context;
        const self: *Self = @ptrCast(@alignCast(context.?));
        return self.events.len();
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
    try Call(sm, &ctx, "record");

    try testing.expectEqual(@as(usize, 1), inst.calls);
    try testing.expect(inst.saw_call_event);
    try testing.expect(inst.saw_call_kind);
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

test "composite entry starts its timers once after initial entry" {
    const model_type = comptime Define("CompositeTimerModel", .{
        Initial(Target("composite")),
        State("composite", .{
            Initial(Target("leaf")),
            Transition(.{ After(atDeadline), Effect(noopBehavior) }),
            State("leaf", .{}),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    const composite_state = getState(&model, "/CompositeTimerModel/composite").?;
    try testing.expect(composite_state.initial_transition != null);
    try testing.expectEqual(@as(usize, 1), composite_state.transitions.len);
    try testing.expect(getTransition(&model, composite_state.transitions[0]).?.timer_fn != null);
    const root_state = getState(&model, "/CompositeTimerModel").?;
    const root_initial = getTransition(&model, root_state.initial_transition.?).?;
    try testing.expectEqualStrings("/CompositeTimerModel/composite", root_initial.target.?);

    var ctx = Context.init(testing.allocator);
    var inst = AtTestInstance{ .deadline_ns = 60 * std.time.ns_per_s };
    var sm = try Start(&ctx, &inst, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/CompositeTimerModel/composite/leaf", sm.state());
    try testing.expect(sm.active_timers.capacity() > 0);
    try testing.expectEqual(@as(u64, 1), inst.timer_calls.load(.acquire));
}

test "At timer uses absolute Clock.Now deadline" {
    const model_type = comptime Define("AtTimerModel", .{
        Initial(Target("waiting")),
        State("waiting", .{
            Transition(.{ At(atDeadline), Effect(noopBehavior) }),
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
        Initial(Target("idle")),
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
            Transition(.{ On(ErrorEventName), Target("../failed") }),
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

test "custom queue pop errors retry once and bound persistent failures" {
    queue_stop_exit_count.store(0, .release);
    const model_type = comptime Define("QueuePopErrorModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Exit(queueStopExit),
            Transition(.{ On(ErrorEventName), Target("../failed") }),
        }),
        State("failed", .{Exit(queueStopExit)}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var failing = try FailingPopQueue.init(testing.allocator, false);
    defer failing.deinit();
    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&failing)),
        .Push = FailingPopQueue.push,
        .Pop = FailingPopQueue.pop,
        .Len = FailingPopQueue.len,
    });

    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .Queue = &queue }));
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/QueuePopErrorModel/failed", sm.state());
    try testing.expectEqual(@as(usize, 3), failing.pops);
    try testing.expectEqual(@as(usize, 0), failing.events.len());
    try sm.stop();
    queue_stop_exit_count.store(0, .release);

    var persistent = try FailingPopQueue.init(testing.allocator, true);
    defer persistent.deinit();
    var persistent_queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&persistent)),
        .Push = FailingPopQueue.push,
        .Pop = FailingPopQueue.pop,
        .Len = FailingPopQueue.len,
    });

    var persistent_ctx = Context.init(testing.allocator);
    var persistent_inst = QueueTestInstance{};
    var persistent_sm = try StartWithConfig(&persistent_ctx, &persistent_inst.base, &model, Config(.{ .Queue = &persistent_queue }));
    defer persistent_sm.deinit();

    try persistent_sm.Dispatch(&persistent_ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/QueuePopErrorModel/failed", persistent_sm.state());
    try testing.expectEqual(@as(usize, 2), persistent.pops);
    try testing.expectEqual(@as(usize, 1), queue_stop_exit_count.load(.acquire));
    try testing.expectError(error.QueuePopFailed, persistent_sm.stop());
    try testing.expectEqual(@as(usize, 1), persistent.events.len());
    try testing.expectEqual(@as(usize, 1), queue_stop_exit_count.load(.acquire));
    persistent.persistent = false;
    try persistent_sm.stop();
    try testing.expectEqual(@as(usize, 0), persistent.events.len());
    try testing.expectEqual(@as(usize, 2), queue_stop_exit_count.load(.acquire));
}

test "snapshot Len failure cleans partially allocated snapshot fields" {
    const model_type = comptime Define("SnapshotLenErrorModel", .{
        Initial(Target("idle")),
        State("idle", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var failing = FailingLenQueue{};
    var queue = Queue(.{
        .Context = @as(?*anyopaque, @ptrCast(&failing)),
        .Push = FailingLenQueue.push,
        .Pop = FailingLenQueue.pop,
        .Len = FailingLenQueue.len,
    });
    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .ID = "snapshot-id", .Queue = &queue }));
    defer sm.deinit();

    try testing.expectError(error.QueueLenFailed, sm.TakeSnapshot());
    try testing.expectEqual(@as(usize, 1), failing.len_calls);
}

test "activity teardown reports a bounded timeout and can be retried" {
    timeout_activity_started.store(false, .release);
    timeout_activity_release.store(false, .release);
    const model_type = comptime Define("ActivityTimeoutModel", .{
        Initial(Target("working")),
        State("working", .{Activity(nonCooperativeActivity)}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    var ctx = Context.init(testing.allocator);
    var inst = QueueTestInstance{};
    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .ActivityTimeoutNs = std.time.ns_per_ms }));
    defer {
        timeout_activity_release.store(true, .release);
        sm.deinit();
    }

    var attempts: usize = 0;
    while (!timeout_activity_started.load(.acquire) and attempts < 1_000) : (attempts += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expect(timeout_activity_started.load(.acquire));
    try testing.expectError(error.ActivityTimeout, sm.stop());
    try testing.expectError(error.ActivityTimeout, sm.restart());
    timeout_activity_release.store(true, .release);
    try sm.stop();
    try testing.expect(sm.IsStopped());
}

test "stop drains pending events owned by a custom queue" {
    const model_type = comptime Define("CustomQueueStopDrainModel", .{
        Initial(Target("idle")),
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

    var sm = try StartWithConfig(&ctx, &inst.base, &model, Config(.{ .Queue = &queue }));
    defer sm.deinit();

    const pending = Event.init(testing.allocator, "pending");
    try queue.Push(&ctx, pending);
    try testing.expectEqual(@as(usize, 1), recording.events.len());

    try sm.stop();
    try testing.expectEqual(@as(usize, 0), recording.events.len());
}

test "stop allocation preflight preserves an active machine on failure" {
    const model_type = comptime Define("StopPreflightModel", .{
        Initial(Target("idle")),
        State("idle", .{}),
    });

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var model = try model_type.build(allocator);
    defer model.deinit();

    var ctx = Context.init(allocator);
    var inst = QueueTestInstance{};
    var sm = try Start(&ctx, &inst.base, &model);
    defer sm.deinit();
    const state_before = sm.state();

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, sm.stop());
    try testing.expect(!sm.IsStopped());
    try testing.expectEqualStrings(state_before, sm.state());

    failing.fail_index = std.math.maxInt(usize);
    try sm.stop();
}

test "Attribute Set emits OnSet transition and validates type" {
    last_change_event_kind = 0;
    last_change_event_name = "";
    last_change_event_source = "";
    const model_type = comptime Define("AttributeSetModel", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ OnSet("count"), Effect(recordChangeEvent), Target("../done") }),
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

    try testing.expectError(error.AttributeTypeMismatch, sm.Set(&ctx, "count", @as(u32, 1)));
    try testing.expectEqualStrings("/AttributeSetModel/idle", sm.state());

    try sm.Set(&ctx, "count", @as(i32, 7));
    try testing.expectEqualStrings("/AttributeSetModel/done", sm.state());
    try testing.expectEqual(ChangeEventKind, last_change_event_kind);
    try testing.expectEqualStrings("/AttributeSetModel/count", last_change_event_name);
    try testing.expectEqualStrings("/AttributeSetModel/count", last_change_event_source);

    const updated_value = (try Get(sm, "/AttributeSetModel/count")).?;
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

test "Attribute Set leaves the old value when change-event preparation fails" {
    const model_type = comptime Define("AttributeSetFailureModel", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var saw_precommit_failure = false;
    var allocation_offset: usize = 3;
    while (allocation_offset < 9) : (allocation_offset += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var context = Context.init(failing.allocator());
        var instance = Instance.init();
        var machine = try Start(&context, &instance, &model);

        failing.fail_index = failing.alloc_index + allocation_offset;
        const set_result = machine.Set(&context, "count", @as(i32, 7));
        failing.fail_index = std.math.maxInt(usize);
        if (set_result) |_| {
            machine.deinit();
            continue;
        } else |_| {
            const value = (try machine.Get("count")).?;
            const count: *const i32 = @ptrCast(@alignCast(value));
            try testing.expectEqual(@as(i32, 0), count.*);
            machine.deinit();
            saw_precommit_failure = true;
            break;
        }
    }

    try testing.expect(saw_precommit_failure);
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

    try recording.events.enqueue(Event.init(testing.allocator, "queued"));

    var snapshot = try TakeSnapshot(sm);
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
    try testing.expectEqual(@as(usize, 1), snapshot.Transitions.len);
    try testing.expectEqual(ExternalKind, snapshot.Transitions[0].Kind);
    try testing.expectEqualStrings("/SnapshotModel/idle", snapshot.Transitions[0].Source);
    try testing.expectEqualStrings("/SnapshotModel/done", snapshot.Transitions[0].Target.?);
    try testing.expectEqual(@as(usize, 1), snapshot.Transitions[0].Events.len);
    try testing.expectEqualStrings("go", snapshot.Transitions[0].Events[0]);
    try testing.expect(!snapshot.Transitions[0].Guard);

    const snap_value = snapshot.Attributes.get("/SnapshotModel/count").?;
    const snap_count = snap_value.as(i32).?;
    try testing.expectEqual(@as(i32, 4), snap_count.*);

    const mutable_snap_count: *i32 = @constCast(snap_count);
    mutable_snap_count.* = 99;

    const runtime_value = (try sm.Get("count")).?;
    const runtime_count: *i32 = @ptrCast(@alignCast(runtime_value));
    try testing.expectEqual(@as(i32, 4), runtime_count.*);
}

test "TakeSnapshot includes timer transition details" {
    const model_type = comptime Define("SnapshotTimerModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ After(snapshotTimerFn), Target("../done") }),
        }),
        Final("done"),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = Instance.init();
    defer inst.deinit();
    var sm = try Start(&ctx, &inst, &model);
    defer sm.deinit();

    var snapshot = try sm.TakeSnapshot();
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 1), snapshot.Transitions.len);
    try testing.expectEqualStrings("/SnapshotTimerModel/idle", snapshot.Transitions[0].Source);
    try testing.expectEqualStrings("/SnapshotTimerModel/done", snapshot.Transitions[0].Target.?);
    try testing.expectEqual(@as(usize, 1), snapshot.Transitions[0].Events.len);
    try testing.expect(std.mem.endsWith(u8, snapshot.Transitions[0].Events[0], "/duration"));
    try testing.expect(snapshot.Transitions[0].Guard);
}

test "timer callback defers owner cleanup until its thread exits" {
    const model_type = comptime Define("DeferredTimerDeinitModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ After(shortTimerFn), Effect(deinitFromTimer) }),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var inst = Instance.init();
    _ = try Start(&ctx, &inst, &model);
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

test "deinit waits for an active direct dispatch" {
    const model_type = comptime Define("LifecycleGateModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("block"), Effect(lifecycleRaceEffect) }),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var context = Context.init(testing.allocator);
    var instance = LifecycleRaceInstance{};
    var machine = try Start(&context, &instance.base, &model);
    var event = Event.init(testing.allocator, "block");
    defer event.deinit();

    const thread = try std.Thread.spawn(.{}, lifecycleDispatchThread, .{
        LifecycleDispatchArgs{ .machine = machine, .context = &context, .event = &event },
    });
    while (!instance.entered.load(.acquire)) std.Thread.yield() catch {};
    machine.deinit();
    thread.join();

    try testing.expect(instance.completed.load(.acquire));
}

test "concurrent deinit admits only one collection teardown" {
    concurrent_deinit_exit_entered.store(false, .release);
    concurrent_deinit_exit_release.store(false, .release);

    const model_type = comptime Define("ConcurrentDeinitModel", .{
        Initial(Target("active")),
        State("active", .{Exit(concurrentDeinitExit)}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var context = Context.init(testing.allocator);
    var instance = Instance.init();
    var machine = try Start(&context, &instance, &model);

    const secondary = try std.Thread.spawn(.{}, concurrentDeinitThread, .{machine});
    while (!concurrent_deinit_exit_entered.load(.acquire)) std.Thread.yield() catch {};
    const releaser = try std.Thread.spawn(.{}, releaseConcurrentDeinitExit, .{});

    machine.deinit();
    secondary.join();
    releaser.join();
}

test "MakeGroup dispatch set call and snapshot aggregate machines" {
    const dispatch_model_type = comptime Define("GroupParity", .{
        Attribute("count", @as(i32, 0)),
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("go"), Target("../done") }),
            Transition(.{ OnSet("count"), Effect(recordChangeEvent) }),
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

    var pair = try MakeGroup(testing.allocator, .{ first, second });
    defer pair.deinit();
    try testing.expectEqual(@as(usize, 2), pair.machines.len);

    try pair.Set(&ctx, "count", @as(i32, 9));
    const first_count_value = (try first.Get("count")).?;
    const first_count: *i32 = @ptrCast(@alignCast(first_count_value));
    const second_count_value = (try second.Get("count")).?;
    const second_count: *i32 = @ptrCast(@alignCast(second_count_value));
    try testing.expectEqual(@as(i32, 9), first_count.*);
    try testing.expectEqual(@as(i32, 9), second_count.*);
    try testing.expectError(error.UnknownAttribute, pair.Set(&ctx, "missing", @as(i32, 1)));

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
            Transition(.{ OnCall("record"), Effect(noopBehavior) }),
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

    var call_group = try makeGroup(testing.allocator, .{ first_call, second_call });
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

test "Source-qualified parent transition dispatches from its child" {
    const model_type = comptime Define("SourceQualifiedModel", .{
        Initial(Target("parent/child")),
        State("parent", .{
            Transition(.{ Source("child"), On("go"), Target("done") }),
            State("child", .{}),
            State("done", .{}),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const parent = getState(&model, "/SourceQualifiedModel/parent").?;
    try testing.expectEqual(@as(usize, 1), parent.transitions.len);
    const trans = getTransition(&model, parent.transitions[0]).?;
    try testing.expectEqualStrings("/SourceQualifiedModel/parent/child", trans.source);
    try testing.expectEqualStrings("/SourceQualifiedModel/parent/done", trans.target.?);

    const child_events = model.transition_map.get("/SourceQualifiedModel/parent/child").?;
    try testing.expectEqual(@as(usize, 1), child_events.get("go").?.len);
    try testing.expectEqualStrings(trans.element.qualified_name, child_events.get("go").?[0]);

    const parent_events = model.transition_map.get("/SourceQualifiedModel/parent").?;
    try testing.expect(parent_events.get("go") == null);
    try testing.expect(trans.paths.get("/SourceQualifiedModel/parent/child") != null);
    try testing.expect(trans.paths.get("/SourceQualifiedModel/parent") == null);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/SourceQualifiedModel/parent/child", sm.state());
    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/SourceQualifiedModel/parent/done", sm.state());
}

test "Parent-owned transition is indexed for child dispatch" {
    const model_type = comptime Define("InheritedTransitionModel", .{
        Initial(Target("parent/child")),
        State("parent", .{
            Transition(.{ On("go"), Target("../done") }),
            State("child", .{}),
        }),
        State("done", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const parent_events = model.transition_map.get("/InheritedTransitionModel/parent").?;
    const child_events = model.transition_map.get("/InheritedTransitionModel/parent/child").?;
    const parent_transition = parent_events.get("go").?;
    const child_transition = child_events.get("go").?;
    try testing.expectEqual(@as(usize, 1), parent_transition.len);
    try testing.expectEqual(@as(usize, 1), child_transition.len);
    try testing.expectEqualStrings(parent_transition[0], child_transition[0]);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/InheritedTransitionModel/parent/child", sm.state());
    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/InheritedTransitionModel/done", sm.state());
}

test "Ordinary transitions remain indexed under their containing state" {
    const model_type = comptime Define("OrdinaryTransitionModel", .{
        Initial(Target("idle")),
        State("idle", .{
            Transition(.{ On("go"), Target("done") }),
        }),
        State("done", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const idle = getState(&model, "/OrdinaryTransitionModel/idle").?;
    const trans = getTransition(&model, idle.transitions[0]).?;
    try testing.expectEqualStrings("/OrdinaryTransitionModel/idle", trans.source);
    try testing.expectEqualStrings("/OrdinaryTransitionModel/done", trans.target.?);

    const idle_events = model.transition_map.get("/OrdinaryTransitionModel/idle").?;
    try testing.expectEqual(@as(usize, 1), idle_events.get("go").?.len);
    try testing.expectEqualStrings(trans.element.qualified_name, idle_events.get("go").?[0]);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/OrdinaryTransitionModel/done", sm.state());
}

const ParentTransitionTestInstance = struct {
    base: Instance,
    current_path: []const u8 = "none",
};

fn parentTransitionParentEntry(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ParentTransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.current_path = "parent";
}

fn parentTransitionChildEntry(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ParentTransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.current_path = "child";
}

fn parentTransitionEffect(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ParentTransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.current_path = "effect";
}

test "ancestor targets remain at the requested active ancestor" {
    const model_type = comptime Define("AncestorSelfReentryModel", .{
        Initial(Target("parent")),
        State("parent", .{
            Entry(parentTransitionParentEntry),
            Initial(Target("child")),
            Transition(.{ On("reset"), Effect(parentTransitionEffect), Target(".") }),
            State("child", .{
                Entry(parentTransitionChildEntry),
                Transition(.{ On("up"), Target("..") }),
            }),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    var ctx = Context.init(testing.allocator);
    var instance = ParentTransitionTestInstance{ .base = Instance.init() };
    defer instance.base.deinit();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/AncestorSelfReentryModel/parent/child", sm.state());
    try testing.expectEqualStrings("child", instance.current_path);

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "reset"));
    try testing.expectEqualStrings("/AncestorSelfReentryModel/parent/child", sm.state());
    try testing.expectEqualStrings("child", instance.current_path);

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "up"));
    try testing.expectEqualStrings("/AncestorSelfReentryModel/parent", sm.state());
    try testing.expectEqualStrings("parent", instance.current_path);
}

test "enabled child transitions win over inherited deferral" {
    const model_type = comptime Define("DeferredPrecedenceModel", .{
        Initial(Target("parent")),
        State("parent", .{
            Initial(Target("child")),
            DeferEvents(.{"go"}),
            State("child", .{
                Transition(.{ On("go"), Target("../done") }),
            }),
            State("done", .{}),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    try validate(&model);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    defer instance.deinit();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try sm.Dispatch(&ctx, Event.init(testing.allocator, "go"));
    try testing.expectEqualStrings("/DeferredPrecedenceModel/parent/done", sm.state());
}

test "final state emits a parent completion transition" {
    const model_type = comptime Define("FinalCompletionModel", .{
        Initial(Target("parent")),
        State("parent", .{
            Initial(Target("finished")),
            Transition(.{ On(FinalEventName), Target("../done") }),
            Final("finished"),
        }),
        State("done", .{}),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();
    try validate(&model);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    try testing.expectEqualStrings("/FinalCompletionModel/done", sm.state());
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

test "Parent deferral is indexed for child dispatch" {
    const model_type = comptime Define("InheritedDeferModel", .{
        Initial(Target("parent/child")),
        State("parent", .{
            DeferEvents(.{"hold"}),
            State("child", .{}),
        }),
    });

    var model = try model_type.build(testing.allocator);
    defer model.deinit();

    const child_events = model.deferred_map.get("/InheritedDeferModel/parent/child").?;
    try testing.expect(child_events.get("hold").?);

    var ctx = Context.init(testing.allocator);
    var instance = Instance.init();
    var sm = try Start(&ctx, &instance, &model);
    defer sm.deinit();

    const result = try sm.dispatchResult(&ctx, Event.init(testing.allocator, "hold"));
    try testing.expectEqual(dispatch_status_deferred, result);
    try testing.expectEqual(@as(usize, 1), canonicalMachine(sm).deferred_queue.len());
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
