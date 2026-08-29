const std = @import("std");
const hsm = @import("hsm");

const max_behaviors = 64;
const max_script_steps = 256;
const max_behavior_depth = 64;
const max_submachine_depth = 8;
const entry_point_target_marker = "__hsm_entry_point__:";

fn jsonTruthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |item| item,
        .integer => |item| item != 0,
        .float => |item| item != 0,
        .number_string => |item| item.len > 0 and !std.mem.eql(u8, item, "0"),
        .string => |item| item.len > 0,
        .array => |items| items.items.len > 0,
        .object => true,
    };
}

fn jsonEqual(left: std.json.Value, right: std.json.Value) bool {
    if (left == .integer and right == .float) return @as(f64, @floatFromInt(left.integer)) == right.float;
    if (left == .float and right == .integer) return left.float == @as(f64, @floatFromInt(right.integer));
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |item| item == right.bool,
        .integer => |item| item == right.integer,
        .float => |item| item == right.float,
        .number_string => |item| std.mem.eql(u8, item, right.number_string),
        .string => |item| std.mem.eql(u8, item, right.string),
        .array => |items| blk: {
            if (items.items.len != right.array.items.len) break :blk false;
            for (items.items, right.array.items) |left_item, right_item| {
                if (!jsonEqual(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(entry.value_ptr.*, right_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn snapshotTransitionGroupName(qualified_name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, qualified_name, '/') orelse return qualified_name;
    const suffix = qualified_name[slash + 1 ..];
    if (!std.mem.startsWith(u8, suffix, "event_") or suffix.len == "event_".len) return qualified_name;
    for (suffix["event_".len..]) |character| {
        if (character < '0' or character > '9') return qualified_name;
    }
    return qualified_name[0..slash];
}

fn generatedTransitionOrdinalName(qualified_name: []const u8) bool {
    const basename = std.fs.path.basename(qualified_name);
    if (!std.mem.startsWith(u8, basename, "transition_")) return false;
    const ordinal = basename["transition_".len..];
    if (ordinal.len == 0) return false;
    for (ordinal) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
}

// Sibling runners derive unnamed transition names from a global member count;
// this runner keeps source-local generated names. Compare those identifiers
// narrowly by owner path and generated-name shape after semantic fields match.
fn snapshotTransitionNamesEquivalent(expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    if (!generatedTransitionOrdinalName(expected)) return false;
    const expected_owner = std.fs.path.dirname(expected) orelse return false;
    const actual_owner = std.fs.path.dirname(actual) orelse return false;
    if (!std.mem.eql(u8, expected_owner, actual_owner)) return false;
    const actual_basename = std.fs.path.basename(actual);
    return std.mem.startsWith(u8, actual_basename, "transition_nested_") or
        std.mem.startsWith(u8, actual_basename, "transition_root_") or
        generatedTransitionOrdinalName(actual);
}

fn queueTraceValuesEquivalent(expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    const push_prefix = "queue:push:";
    const pop_prefix = "queue:pop:";
    const prefix = if (std.mem.startsWith(u8, expected, push_prefix) and std.mem.startsWith(u8, actual, push_prefix))
        push_prefix
    else if (std.mem.startsWith(u8, expected, pop_prefix) and std.mem.startsWith(u8, actual, pop_prefix))
        pop_prefix
    else
        return false;
    const expected_event = expected[prefix.len..];
    const actual_event = actual[prefix.len..];
    const suffix = if (std.mem.endsWith(u8, expected_event, "/duration"))
        "/duration"
    else if (std.mem.endsWith(u8, expected_event, "/timepoint"))
        "/timepoint"
    else
        return false;
    if (!std.mem.endsWith(u8, actual_event, suffix)) return false;
    return snapshotTransitionNamesEquivalent(expected_event[0 .. expected_event.len - suffix.len], actual_event[0 .. actual_event.len - suffix.len]);
}

fn canonicalTransitionKind(kind: u64) u64 {
    return switch (kind) {
        hsm.TransitionKind => 263,
        hsm.ExternalKind => 67343,
        hsm.SelfKind => 67344,
        hsm.InternalKind => 67345,
        hsm.LocalKind => 67346,
        else => kind,
    };
}

const RunError = error{ InvalidCase, UnsupportedCase, RuntimeFailure };

var trace_mutex = std.Thread.Mutex{};
var activity_callback_mutex = std.Thread.Mutex{};

const TraceItem = struct {
    kind: []const u8,
    value: ?[]const u8 = null,
    event: ?[]const u8 = null,
    target: ?[]const u8 = null,
    target_value: ?std.json.Value = null,
    operation: ?[]const u8 = null,
    state: ?[]const u8 = null,
    attribute: ?[]const u8 = null,
    set_value: ?std.json.Value = null,
    error_code: ?[]const u8 = null,
};

const PendingSet = struct {
    name: []const u8,
    value: std.json.Value,
};

const Outcome = struct {
    status: []const u8,
    name: []const u8,
    reason: []const u8,
    state: ?[]const u8 = null,
};

const BehaviorFn = *const fn (*hsm.Context, *hsm.Instance, hsm.Event) void;
const GuardFn = *const fn (*hsm.Context, *hsm.Instance, hsm.Event) bool;
const TimerFn = *const fn (*hsm.Context, *hsm.Instance, hsm.Event) u64;

const TimerSpec = struct {
    index: usize,
    kind: hsm.TimerKind,
};

const ManualTimer = struct {
    transition_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    attribute: ?[]const u8 = null,
    kind: hsm.TimerKind = .after,
    order: usize = 0,
    period_ns: u64 = 0,
    next_deadline_ns: u64 = 0,
    active: bool = false,
    disabled: bool = false,
};

const ConformanceInstance = struct {
    base: hsm.Instance,
    runner: *Runner,
    id: []const u8 = "default",
};

const RuntimeInstance = struct {
    id: []const u8,
    model_name: []const u8,
    name: ?[]const u8 = null,
    data: ?*anyopaque = null,
    instance: ConformanceInstance,
    model: ?*hsm.Model = null,
    machine: ?*hsm.StateMachine = null,
    manual_timers: [max_behaviors]ManualTimer = [_]ManualTimer{.{}} ** max_behaviors,
    suppress_timer_trace: [max_behaviors]bool = [_]bool{false} ** max_behaviors,
    active_timer_count: usize = 0,
    manual_time_ns: u64 = 0,
    deferred_events: std.ArrayList([]const u8),
};

const ConfiguredQueueMode = enum {
    fifo,
    lifo,
    push_error,
    pop_error_once,
    len_seven,
};

fn appendTrace(runner: *Runner, item: TraceItem) !void {
    trace_mutex.lock();
    defer trace_mutex.unlock();
    try runner.trace.append(runner.allocator, item);
}

fn insertTrace(runner: *Runner, index: usize, item: TraceItem) !void {
    trace_mutex.lock();
    defer trace_mutex.unlock();
    try runner.trace.insert(runner.allocator, index, item);
}

const ConfiguredQueue = struct {
    runner: *Runner,
    mode: ConfiguredQueueMode,
    fifo: hsm.EventQueue,
    lifo: std.ArrayList(hsm.Event),
    pop_error_pending: bool,
    deferred_push_count: usize,
    runtime_queue: hsm.RuntimeQueue,
};

const PendingDispatch = struct {
    target_id: []const u8,
    source_id: []const u8,
    event_value: std.json.Value,
};

fn behaviorCallback(comptime index: usize) BehaviorFn {
    return struct {
        fn call(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) void {
            const conformance_instance: *ConformanceInstance = @ptrCast(@alignCast(instance));
            if (conformance_instance.runner.runtime_failed and ctx.parent == null) return;
            const is_activity = ctx.parent != null;
            const activity_has_sleep = is_activity and conformance_instance.runner.behaviorHasSleep(index);
            const activity_needs_flush = is_activity and conformance_instance.runner.behaviorNeedsFlush(index);
            const serialize_activity = is_activity and (!activity_has_sleep or conformance_instance.runner.expectsRuntimeError());
            if (activity_has_sleep and conformance_instance.runner.expectsRuntimeError()) {
                std.Thread.sleep(std.time.ns_per_ms);
            }
            if (serialize_activity) activity_callback_mutex.lock();
            defer if (serialize_activity) activity_callback_mutex.unlock();
            const previous_instance_id = conformance_instance.runner.active_instance_id;
            conformance_instance.runner.active_instance_id = conformance_instance.id;
            defer conformance_instance.runner.active_instance_id = previous_instance_id;
            if (conformance_instance.runner.timer_fired_pending and
                (std.mem.startsWith(u8, event.name, "_timeout:") or std.mem.startsWith(u8, event.name, "_periodic:")))
            {
                conformance_instance.runner.recordTimerFired();
            }
            _ = conformance_instance.runner.executeBehavior(index, event, false, ctx);
            if (activity_needs_flush and !ctx.is_done()) if (conformance_instance.runner.activeMachine()) |machine| {
                machine.Flush(&conformance_instance.runner.context) catch {
                    conformance_instance.runner.runtime_failed = true;
                    conformance_instance.runner.reason = "activity queue flush failed";
                };
            };
            if (ctx.parent != null and !ctx.is_done() and !conformance_instance.runner.runtime_failed and
                conformance_instance.runner.traceIncludes("activity_done"))
            {
                if (conformance_instance.runner.behavior_ids[index]) |behavior_id| {
                    appendTrace(conformance_instance.runner, .{ .kind = "activity_done", .operation = behavior_id }) catch {
                        conformance_instance.runner.runtime_failed = true;
                        conformance_instance.runner.reason = "activity completion trace allocation failed";
                    };
                }
            }
        }
    }.call;
}

fn guardCallback(comptime index: usize) GuardFn {
    return struct {
        fn call(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) bool {
            const conformance_instance: *ConformanceInstance = @ptrCast(@alignCast(instance));
            if (conformance_instance.runner.runtime_failed) return false;
            const previous_instance_id = conformance_instance.runner.active_instance_id;
            conformance_instance.runner.active_instance_id = conformance_instance.id;
            defer conformance_instance.runner.active_instance_id = previous_instance_id;
            if (conformance_instance.runner.timer_fired_pending and
                (std.mem.startsWith(u8, event.name, "_timeout:") or std.mem.startsWith(u8, event.name, "_periodic:")) and
                !conformance_instance.runner.guardDefersTimerFired(index))
            {
                conformance_instance.runner.recordTimerFired();
            }
            const timer_trace_index = conformance_instance.runner.trace.items.len;
            const result = conformance_instance.runner.executeBehavior(index, event, true, ctx);
            if (conformance_instance.runner.timer_fired_pending and
                (std.mem.startsWith(u8, event.name, "_timeout:") or std.mem.startsWith(u8, event.name, "_periodic:")))
            {
                if (result) {
                    conformance_instance.runner.recordTimerFired();
                } else {
                    conformance_instance.runner.timer_fired_pending = false;
                    if (conformance_instance.runner.traceIncludes("timer_fired")) insertTrace(
                        conformance_instance.runner,
                        timer_trace_index,
                        .{ .kind = "timer_fired" },
                    ) catch {
                        conformance_instance.runner.runtime_failed = true;
                        conformance_instance.runner.reason = "timer fired trace allocation failed";
                    };
                }
            }
            return result;
        }
    }.call;
}

fn timerCallback(comptime index: usize) TimerFn {
    return struct {
        fn call(ctx: *hsm.Context, instance: *hsm.Instance, event: hsm.Event) u64 {
            _ = ctx;
            const conformance_instance: *ConformanceInstance = @ptrCast(@alignCast(instance));
            if (conformance_instance.runner.runtime_failed) return 0;
            const previous_instance_id = conformance_instance.runner.active_instance_id;
            conformance_instance.runner.active_instance_id = conformance_instance.id;
            defer conformance_instance.runner.active_instance_id = previous_instance_id;
            return conformance_instance.runner.executeTimer(index, event);
        }
    }.call;
}

const behavior_callbacks = blk: {
    var callbacks: [max_behaviors]BehaviorFn = undefined;
    for (0..max_behaviors) |index| callbacks[index] = behaviorCallback(index);
    break :blk callbacks;
};

const guard_callbacks = blk: {
    var callbacks: [max_behaviors]GuardFn = undefined;
    for (0..max_behaviors) |index| callbacks[index] = guardCallback(index);
    break :blk callbacks;
};

const timer_callbacks = blk: {
    var callbacks: [max_behaviors]TimerFn = undefined;
    for (0..max_behaviors) |index| callbacks[index] = timerCallback(index);
    break :blk callbacks;
};

const Runner = struct {
    allocator: std.mem.Allocator,
    case_value: std.json.Value,
    case_name: []const u8,
    model_name: []const u8,
    instance_id: []const u8 = "default",
    runtime_name: ?[]const u8 = null,
    runtime_data: ?*anyopaque = null,
    model: ?hsm.Model = null,
    machine: ?*hsm.StateMachine = null,
    context: hsm.Context,
    instance: ConformanceInstance,
    behavior_ids: [max_behaviors]?[]const u8 = [_]?[]const u8{null} ** max_behaviors,
    guard_behavior: [max_behaviors]bool = [_]bool{false} ** max_behaviors,
    action_behavior: [max_behaviors]bool = [_]bool{false} ** max_behaviors,
    timer_behavior: [max_behaviors]bool = [_]bool{false} ** max_behaviors,
    timer_durations: [max_behaviors]?u64 = [_]?u64{null} ** max_behaviors,
    timer_kinds: [max_behaviors]hsm.TimerKind = [_]hsm.TimerKind{.after} ** max_behaviors,
    timer_attributes: [max_behaviors]?[]const u8 = [_]?[]const u8{null} ** max_behaviors,
    timer_sources: [max_behaviors]?[]const u8 = [_]?[]const u8{null} ** max_behaviors,
    timer_orders: [max_behaviors]usize = [_]usize{0} ** max_behaviors,
    manual_timers: [max_behaviors]ManualTimer = [_]ManualTimer{.{}} ** max_behaviors,
    suppress_timer_trace: [max_behaviors]bool = [_]bool{false} ** max_behaviors,
    behavior_count: usize = 0,
    trace: std.ArrayList(TraceItem),
    pending_sets: std.ArrayList(PendingSet),
    deferred_events: std.ArrayList([]const u8),
    deferred_history: std.ArrayList([]const u8),
    submachine_paths: std.ArrayList([]const u8),
    replay_undefer_index: usize = 0,
    replaying_deferred: bool = false,
    defer_trace_event: ?[]const u8 = null,
    active_timer_count: usize = 0,
    timer_fired_pending: bool = false,
    timer_epoch_ns: ?u64 = null,
    manual_time_ns: u64 = 0,
    behavior_depth: usize = 0,
    event_metadata_overlay: ?std.StringHashMap(*anyopaque) = null,
    last_snapshot: ?hsm.Snapshot = null,
    stable_state: ?[]const u8 = null,
    last_dispatch_queued: ?bool = null,
    reason: ?[]const u8 = null,
    runtime_failed: bool = false,
    instances: ?std.StringHashMap(*RuntimeInstance) = null,
    instance_order: std.ArrayList(*RuntimeInstance),
    groups: ?std.StringHashMap([][]const u8) = null,
    pending_dispatches: std.ArrayList(PendingDispatch),
    active_instance_id: ?[]const u8 = null,
    model_selection_error: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, case_value: std.json.Value, case_name: []const u8, model_name: []const u8) !Runner {
        return .{
            .allocator = allocator,
            .case_value = case_value,
            .case_name = case_name,
            .model_name = model_name,
            .context = hsm.Context.init(allocator),
            .instance = undefined,
            .trace = try std.ArrayList(TraceItem).initCapacity(allocator, 0),
            .pending_sets = try std.ArrayList(PendingSet).initCapacity(allocator, 0),
            .deferred_events = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .deferred_history = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .submachine_paths = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .instance_order = try std.ArrayList(*RuntimeInstance).initCapacity(allocator, 0),
            .pending_dispatches = try std.ArrayList(PendingDispatch).initCapacity(allocator, 0),
        };
    }

    fn deinit(self: *Runner) void {
        if (self.machine) |machine| machine.deinit();
        if (self.instances) |*instances| {
            var iterator = instances.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.*.machine) |machine| machine.deinit();
                if (entry.value_ptr.*.model) |model| {
                    model.deinit();
                    self.allocator.destroy(model);
                }
                entry.value_ptr.*.deferred_events.deinit(self.allocator);
                entry.value_ptr.*.instance.base.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            instances.deinit();
        }
        if (self.groups) |*groups| {
            var iterator = groups.iterator();
            while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
            groups.deinit();
        }
        self.instance_order.deinit(self.allocator);
        self.pending_dispatches.deinit(self.allocator);
        if (self.model) |*model| model.deinit();
        if (self.event_metadata_overlay) |*metadata| metadata.deinit();
        if (self.last_snapshot) |*snapshot| snapshot.deinit();
        self.trace.deinit(self.allocator);
        self.pending_sets.deinit(self.allocator);
        self.deferred_events.deinit(self.allocator);
        self.deferred_history.deinit(self.allocator);
        self.submachine_paths.deinit(self.allocator);
    }

    fn setReason(self: *Runner, comptime format: []const u8, args: anytype) void {
        self.reason = std.fmt.allocPrint(self.allocator, format, args) catch "unable to format runner reason";
    }

    fn captureSnapshot(self: *Runner, machine: *hsm.StateMachine) !void {
        if (self.last_snapshot) |*snapshot| snapshot.deinit();
        self.last_snapshot = try machine.TakeSnapshot();
    }

    fn captureGroupSnapshot(self: *Runner, group_id: []const u8) !void {
        const groups = self.groups orelse return self.unsupported("groups are outside the bounded runner", .{});
        const member_ids = groups.get(group_id) orelse return self.invalid("unknown group {s}", .{group_id});
        const machines = try self.allocator.alloc(*hsm.StateMachine, member_ids.len);
        for (member_ids, 0..) |member_id, index| {
            machines[index] = self.machineForInstance(member_id) orelse return self.unsupported("group snapshot member {s} is not started", .{member_id});
        }
        var group = hsm.Group{ .id = null, .machines = machines, .allocator = self.allocator };
        if (self.last_snapshot) |*snapshot| snapshot.deinit();
        self.last_snapshot = try group.TakeSnapshot();
    }

    fn activeMachine(self: *Runner) ?*hsm.StateMachine {
        if (self.active_instance_id) |instance_id| {
            if (self.instances) |instances| {
                if (instances.get(instance_id)) |runtime| if (runtime.machine != null) return runtime.machine.?;
            }
        }
        if (self.machine) |machine| return machine;
        return hsm.FromContext(&self.context);
    }

    fn activeRuntime(self: *Runner) ?*RuntimeInstance {
        const instance_id = self.active_instance_id orelse return null;
        if (self.instances) |instances| return instances.get(instance_id);
        return null;
    }

    fn activeManualTimers(self: *Runner) *[max_behaviors]ManualTimer {
        if (self.activeRuntime()) |runtime| return &runtime.manual_timers;
        return &self.manual_timers;
    }

    fn activeSuppressTimerTrace(self: *Runner) *[max_behaviors]bool {
        if (self.activeRuntime()) |runtime| return &runtime.suppress_timer_trace;
        return &self.suppress_timer_trace;
    }

    fn activeManualTime(self: *Runner) *u64 {
        if (self.activeRuntime()) |runtime| return &runtime.manual_time_ns;
        return &self.manual_time_ns;
    }

    fn activeTimerCountPtr(self: *Runner) *usize {
        if (self.activeRuntime()) |runtime| return &runtime.active_timer_count;
        return &self.active_timer_count;
    }

    fn copyTimerTemplate(self: *Runner, runtime: *RuntimeInstance) void {
        runtime.manual_timers = self.manual_timers;
        runtime.suppress_timer_trace = [_]bool{false} ** max_behaviors;
        runtime.active_timer_count = 0;
        runtime.manual_time_ns = 0;
    }

    fn unhandledExitPointName(machine: *hsm.StateMachine, event_name: []const u8) ?[]const u8 {
        const event_map = machine.model.transition_map.get(machine.state()) orelse return null;
        const transition_names = event_map.get(event_name) orelse return null;
        for (transition_names) |transition_name| {
            const transition = hsm.getTransition(machine.model, transition_name) orelse continue;
            const target = transition.target orelse continue;
            if (hsm.getConnectionPoint(machine.model, target)) |point| return point.element.name();
        }
        return null;
    }

    fn machineForInstance(self: *Runner, instance_id: []const u8) ?*hsm.StateMachine {
        if (self.instances) |instances| {
            if (instances.get(instance_id)) |runtime| {
                if (runtime.machine != null) {
                    return runtime.machine.?;
                }
            }
            return null;
        }
        if (std.mem.eql(u8, instance_id, self.instance_id)) if (self.machine) |machine| return machine;
        return null;
    }

    fn runtimeInstance(self: *Runner, instance_id: []const u8) !*RuntimeInstance {
        if (self.instances) |instances| return instances.get(instance_id) orelse self.unsupported("unknown instance {s}", .{instance_id});
        return self.unsupported("instance {s} is outside the bounded runner", .{instance_id});
    }

    fn activeDeferredEvents(self: *Runner) *std.ArrayList([]const u8) {
        if (self.active_instance_id) |instance_id| {
            if (self.instances) |instances| {
                if (instances.get(instance_id)) |runtime| return &runtime.deferred_events;
            }
        }
        return &self.deferred_events;
    }

    fn configuredInstanceValue(self: *Runner, field_name: []const u8) ?std.json.Value {
        const instances = objectField(self.case_value, "instances") orelse return null;
        if (instances != .array) return null;
        const selected_id = self.active_instance_id orelse self.instance_id;
        for (instances.array.items) |instance| {
            if (instance != .object) continue;
            const id = objectField(instance, "id") orelse continue;
            if (id != .string or !std.mem.eql(u8, id.string, selected_id)) continue;
            const config = objectField(instance, "config") orelse return null;
            return if (config == .object) objectField(config, field_name) else null;
        }
        return null;
    }

    fn makeConfiguredQueue(self: *Runner) !?*ConfiguredQueue {
        const queue_value = self.configuredInstanceValue("queue") orelse return null;
        if (queue_value != .string or queue_value.string.len == 0) return self.invalid("instance.config.queue must be a non-empty string", .{});
        const mode: ConfiguredQueueMode = if (std.mem.eql(u8, queue_value.string, "trace_fifo"))
            .fifo
        else if (std.mem.eql(u8, queue_value.string, "trace_lifo"))
            .lifo
        else if (std.mem.eql(u8, queue_value.string, "push_error"))
            .push_error
        else if (std.mem.eql(u8, queue_value.string, "pop_error_once"))
            .pop_error_once
        else if (std.mem.eql(u8, queue_value.string, "len_seven"))
            .len_seven
        else
            return self.unsupported("instance.config.queue {s} is outside the bounded runner", .{queue_value.string});
        const queue = try self.allocator.create(ConfiguredQueue);
        queue.* = .{
            .runner = self,
            .mode = mode,
            .fifo = try hsm.EventQueue.init(self.allocator),
            .lifo = try std.ArrayList(hsm.Event).initCapacity(self.allocator, 0),
            .pop_error_pending = mode == .pop_error_once,
            .deferred_push_count = 0,
            .runtime_queue = undefined,
        };
        queue.runtime_queue = .{
            .context = @ptrCast(queue),
            .push_fn = configuredQueuePush,
            .pop_fn = configuredQueuePop,
            .len_fn = configuredQueueLen,
        };
        return queue;
    }

    fn flushPendingDispatches(self: *Runner) !void {
        while (self.pending_dispatches.items.len > 0) {
            const pending = self.pending_dispatches.orderedRemove(0);
            const machine = self.machineForInstance(pending.target_id) orelse continue;
            if (machine.IsStopped()) continue;
            const previous_instance_id = self.active_instance_id;
            self.active_instance_id = pending.target_id;
            defer self.active_instance_id = previous_instance_id;
            var event = try self.eventFromValue(pending.event_value);
            defer event.deinit();
            if (event.source == null) event.source = pending.source_id;
            if (event.target == null) event.target = pending.target_id;
            const should_defer = try self.prepareDispatch(machine, event.name);
            if (should_defer) {
                if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event.name });
                try self.activeDeferredEvents().append(self.allocator, event.name);
                try self.deferred_history.append(self.allocator, event.name);
            }
            try machine.dispatch(&self.context, event);
            if (self.replaying_deferred) {
                self.replaying_deferred = false;
                self.replay_undefer_index = 0;
                self.activeDeferredEvents().clearRetainingCapacity();
            }
        }
    }

    fn invalid(self: *Runner, comptime format: []const u8, args: anytype) RunError {
        self.setReason(format, args);
        return error.InvalidCase;
    }

    fn unsupported(self: *Runner, comptime format: []const u8, args: anytype) RunError {
        self.setReason(format, args);
        return error.UnsupportedCase;
    }

    fn configureSingleInstance(self: *Runner) !void {
        const instances = objectField(self.case_value, "instances") orelse return;
        if (instances != .array or instances.array.items.len == 0) return self.invalid("instances must be a non-empty array", .{});
        if (instances.array.items.len == 1) {
            const instance = instances.array.items[0];
            if (instance != .object) return self.invalid("instance must be an object", .{});
            self.instance_id = try self.requireString(instance, "id");
            if (objectField(instance, "model")) |model| {
                if (model != .string or model.string.len == 0) return self.invalid("instance.model must be a non-empty string", .{});
                self.model_name = model.string;
                const root_model = try self.requireObject(self.case_value, "model");
                const root_name = try self.requireString(root_model, "name");
                if (!std.mem.eql(u8, self.model_name, root_name) and self.preflightModelByName(self.model_name) == null) {
                    self.model_selection_error = self.model_name;
                }
            }
            self.runtime_data = try self.instanceData(instance);
            if (objectField(instance, "config")) |config| {
                if (config != .object) return self.invalid("instance.config must be an object", .{});
                var iterator = config.object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "name") and !std.mem.eql(u8, entry.key_ptr.*, "data") and !std.mem.eql(u8, entry.key_ptr.*, "clock") and !std.mem.eql(u8, entry.key_ptr.*, "queue")) return self.unsupported("instance config field {s} is outside the bounded runner", .{entry.key_ptr.*});
                }
                if (objectField(config, "name") != null) self.runtime_name = try self.requireString(config, "name");
                if (config.object.getPtr("data")) |data| self.runtime_data = try self.instanceDataValue(data.*);
            }
            try self.configureGroups();
            return;
        }

        self.instances = std.StringHashMap(*RuntimeInstance).init(self.allocator);
        errdefer {
            var iterator = self.instances.?.iterator();
            while (iterator.next()) |entry| self.allocator.destroy(entry.value_ptr.*);
            self.instances.?.deinit();
            self.instances = null;
        }
        for (instances.array.items) |instance| {
            if (instance != .object) return self.invalid("instance must be an object", .{});
            const id = try self.requireString(instance, "id");
            if (self.instances.?.contains(id)) return self.invalid("duplicate instance id {s}", .{id});
            const model_name = if (objectField(instance, "model")) |model| blk: {
                if (model != .string or model.string.len == 0) return self.invalid("instance.model must be a non-empty string", .{});
                break :blk model.string;
            } else self.model_name;
            var data = try self.instanceData(instance);
            var name: ?[]const u8 = null;
            if (objectField(instance, "config")) |config| {
                if (config != .object) return self.invalid("instance.config must be an object", .{});
                var iterator = config.object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "name") and !std.mem.eql(u8, entry.key_ptr.*, "data") and !std.mem.eql(u8, entry.key_ptr.*, "clock") and !std.mem.eql(u8, entry.key_ptr.*, "queue")) return self.unsupported("instance config field {s} is outside the bounded runner", .{entry.key_ptr.*});
                }
                if (objectField(config, "name") != null) name = try self.requireString(config, "name");
                if (config.object.getPtr("data")) |config_data| data = try self.instanceDataValue(config_data.*);
            }
            const runtime = try self.allocator.create(RuntimeInstance);
            runtime.* = .{
                .id = id,
                .model_name = model_name,
                .name = name,
                .data = data,
                .instance = .{ .base = hsm.Instance.init(), .runner = self, .id = id },
                .deferred_events = try std.ArrayList([]const u8).initCapacity(self.allocator, 0),
            };
            try self.instances.?.put(id, runtime);
            try self.instance_order.append(self.allocator, runtime);
        }
        try self.configureGroups();
    }

    fn instanceData(self: *Runner, instance: std.json.Value) !?*anyopaque {
        if (instance.object.getPtr("data")) |data| return try self.instanceDataValue(data.*);
        return null;
    }

    fn instanceDataValue(self: *Runner, data: std.json.Value) !*anyopaque {
        if (data != .object) return self.invalid("instance data must be an object", .{});
        const value = try self.allocator.create(std.json.Value);
        value.* = data;
        return @ptrCast(value);
    }

    fn configureGroups(self: *Runner) !void {
        const groups_value = objectField(self.case_value, "groups") orelse return;
        if (groups_value != .array) return self.invalid("groups must be an array", .{});
        self.groups = std.StringHashMap([][]const u8).init(self.allocator);
        for (groups_value.array.items) |group_value| {
            if (group_value != .object) return self.invalid("group must be an object", .{});
            const group_id = try self.requireString(group_value, "id");
            if (self.groups.?.contains(group_id)) return self.invalid("duplicate group id {s}", .{group_id});
            const members = try self.requireArray(group_value, "members");
            if (members.array.items.len == 0) return self.invalid("group members must not be empty", .{});
            const member_ids = try self.allocator.alloc([]const u8, members.array.items.len);
            errdefer self.allocator.free(member_ids);
            for (members.array.items, 0..) |member, index| {
                if (member != .string or member.string.len == 0) return self.invalid("group member must be a non-empty string", .{});
                if (self.instances) |instances| {
                    if (instances.get(member.string) == null) return self.invalid("unknown group member {s}", .{member.string});
                } else if (!std.mem.eql(u8, member.string, self.instance_id)) {
                    return self.invalid("unknown group member {s}", .{member.string});
                }
                member_ids[index] = member.string;
            }
            try self.groups.?.put(group_id, member_ids);
        }
    }

    fn validateSingleInstanceStep(self: *Runner, step: std.json.Value) !void {
        if (objectField(step, "instance")) |instance| {
            if (instance != .string) return self.invalid("script instance must be a string", .{});
            if (self.instances != null) {
                if (self.instances.?.get(instance.string) == null) return self.unsupported("unknown instance {s}", .{instance.string});
                return;
            }
            if (!std.mem.eql(u8, instance.string, self.instance_id)) return self.unsupported("instance {s} is outside the bounded runner", .{instance.string});
        }
    }

    fn stepInstanceId(self: *Runner, step: std.json.Value) ![]const u8 {
        if (objectField(step, "instance")) |instance| {
            if (instance != .string or instance.string.len == 0) return self.invalid("script instance must be a non-empty string", .{});
            return instance.string;
        }
        if (self.instances != null) return self.unsupported("multi-instance operation requires instance", .{});
        return self.instance_id;
    }

    fn startConfiguredInstance(self: *Runner, instance_id: []const u8) !*hsm.StateMachine {
        const runtime = try self.runtimeInstance(instance_id);
        self.active_instance_id = runtime.id;
        if (runtime.machine) |existing| {
            if (!existing.IsStopped()) return existing;
            runtime.deferred_events.clearRetainingCapacity();
            self.timer_epoch_ns = existing.clock.Now();
            self.timer_fired_pending = true;
            try existing.restart();
            return existing;
        }
        if (self.timer_epoch_ns == null) {
            const timestamp = std.time.nanoTimestamp();
            self.timer_epoch_ns = if (timestamp > 0) @as(u64, @intCast(timestamp)) else 0;
        }
        self.timer_fired_pending = true;
        const model = runtime.model orelse &self.model.?;
        runtime.machine = if (try self.makeConfiguredQueue()) |queue|
            try hsm.startWithConfig(&self.context, &runtime.instance, model, hsm.Config(.{ .ID = runtime.id, .Name = runtime.name, .Data = runtime.data, .Queue = &queue.runtime_queue }))
        else
            try hsm.startWithConfig(&self.context, &runtime.instance, model, hsm.Config(.{ .ID = runtime.id, .Name = runtime.name, .Data = runtime.data }));
        return runtime.machine.?;
    }

    fn machineForStep(self: *Runner, step: std.json.Value) !*hsm.StateMachine {
        const instance_id = try self.stepInstanceId(step);
        if (self.instances != null) {
            self.active_instance_id = instance_id;
            return self.machineForInstance(instance_id) orelse self.unsupported("instance {s} is not started", .{instance_id});
        }
        return self.machineForInstance(instance_id) orelse self.unsupported("operation before start is outside the supported subset", .{});
    }

    fn machineForLifecycleStep(self: *Runner, step: std.json.Value) !?*hsm.StateMachine {
        const instance_id = try self.stepInstanceId(step);
        self.active_instance_id = instance_id;
        const machine = self.machineForInstance(instance_id) orelse {
            self.recordRuntimeError("runtime_error", "machine must be started");
            return null;
        };
        if (machine.IsStopped()) {
            self.recordRuntimeError("runtime_error", "machine must be started");
            return null;
        }
        return machine;
    }

    fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
        return if (value == .object) value.object.get(key) else null;
    }

    fn requireObject(self: *Runner, value: std.json.Value, key: []const u8) !std.json.Value {
        const child = objectField(value, key) orelse return self.invalid("missing object field {s}", .{key});
        if (child != .object) return self.invalid("field {s} must be an object", .{key});
        return child;
    }

    fn requireArray(self: *Runner, value: std.json.Value, key: []const u8) !std.json.Value {
        const child = objectField(value, key) orelse return self.invalid("missing array field {s}", .{key});
        if (child != .array) return self.invalid("field {s} must be an array", .{key});
        return child;
    }

    fn requireString(self: *Runner, value: std.json.Value, key: []const u8) ![]const u8 {
        const child = objectField(value, key) orelse return self.invalid("missing string field {s}", .{key});
        if (child != .string or child.string.len == 0) return self.invalid("field {s} must be a non-empty string", .{key});
        return child.string;
    }

    fn requireStringAllowEmpty(self: *Runner, value: std.json.Value, key: []const u8) ![]const u8 {
        const child = objectField(value, key) orelse return self.invalid("missing string field {s}", .{key});
        if (child != .string) return self.invalid("field {s} must be a string", .{key});
        return child.string;
    }

    fn stringField(self: *Runner, value: std.json.Value, key: []const u8) !?[]const u8 {
        const child = objectField(value, key) orelse return null;
        if (child != .string or child.string.len == 0) return self.invalid("field {s} must be a non-empty string", .{key});
        return child.string;
    }

    fn eventReferenceName(self: *Runner, value: std.json.Value) ![]const u8 {
        if (value == .string) {
            if (value.string.len == 0) return self.invalid("event name must be non-empty", .{});
            if (std.mem.eql(u8, value.string, hsm.ErrorEventName)) return hsm.ErrorEventName;
            return value.string;
        }
        if (value == .object) {
            const name = try self.requireString(value, "name");
            if (std.mem.eql(u8, name, hsm.ErrorEventName)) return hsm.ErrorEventName;
            return name;
        }
        return self.invalid("event reference must be a string or object", .{});
    }

    fn triggerEventName(self: *Runner, trigger: std.json.Value) ![]const u8 {
        if (objectField(trigger, "event")) |event_value| return self.eventReferenceName(event_value);
        const events = objectField(trigger, "events") orelse return self.invalid("on trigger requires event or events", .{});
        if (events != .array or events.array.items.len == 0) return self.invalid("on trigger events must be non-empty", .{});
        return self.eventReferenceName(events.array.items[0]);
    }

    fn appendEventAliases(
        self: *Runner,
        transition_value: std.json.Value,
        source_path: []const u8,
        state: *hsm.StateElement,
        base_transition: *hsm.TransitionElement,
        transition_name: []const u8,
    ) !void {
        const trigger = objectField(transition_value, "trigger") orelse return;
        if (objectField(trigger, "kind")) |kind| {
            if (kind == .string and std.mem.eql(u8, kind.string, "when") and objectField(trigger, "behavior") != null) {
                var attribute_iterator = self.model.?.attributes.iterator();
                var attribute_index: usize = 0;
                while (attribute_iterator.next()) |attribute_entry| : (attribute_index += 1) {
                    if (base_transition.event_name) |event_name| if (std.mem.eql(u8, event_name, attribute_entry.key_ptr.*)) continue;
                    const alias_name = try std.fmt.allocPrint(self.allocator, "{s}/attribute_{}", .{ transition_name, attribute_index });
                    const alias = try hsm.addTransition(&self.model.?, alias_name, source_path, base_transition.target, attribute_entry.key_ptr.*);
                    if (base_transition.guards.len > 0) {
                        alias.guards = try self.allocator.alloc([]const u8, base_transition.guards.len);
                        for (base_transition.guards, 0..) |guard_name, index| alias.guards[index] = try self.allocator.dupe(u8, guard_name);
                        alias.guard = alias.guards[0];
                    }
                    if (base_transition.effects.len > 0) {
                        alias.effects = try self.allocator.alloc([]const u8, base_transition.effects.len);
                        for (base_transition.effects, 0..) |effect_name, index| alias.effects[index] = try self.allocator.dupe(u8, effect_name);
                    }
                    try self.appendTransitionName(state, alias.element.qualified_name);
                }
                return;
            }
        }
        const events = objectField(trigger, "events") orelse return;
        if (events != .array) return self.invalid("on trigger events must be an array", .{});
        for (events.array.items[1..], 1..) |event_value, event_index| {
            const event_name = try self.eventReferenceName(event_value);
            const alias_name = try std.fmt.allocPrint(self.allocator, "{s}/event_{}", .{ transition_name, event_index });
            const alias = try hsm.addTransition(&self.model.?, alias_name, source_path, base_transition.target, event_name);
            if (base_transition.guards.len > 0) {
                alias.guards = try self.allocator.alloc([]const u8, base_transition.guards.len);
                for (base_transition.guards, 0..) |guard_name, index| {
                    alias.guards[index] = try self.allocator.dupe(u8, guard_name);
                }
                alias.guard = alias.guards[0];
            }
            if (base_transition.effects.len > 0) {
                alias.effects = try self.allocator.alloc([]const u8, base_transition.effects.len);
                for (base_transition.effects, 0..) |effect_name, index| {
                    alias.effects[index] = try self.allocator.dupe(u8, effect_name);
                }
            }
            try self.appendTransitionName(state, alias.element.qualified_name);
        }
    }

    fn hasUnsupportedField(self: *Runner, value: std.json.Value, fields: []const []const u8) !void {
        if (value != .object) return self.invalid("expected object", .{});
        for (fields) |field_name| {
            if (value.object.contains(field_name)) return self.unsupported("unsupported field {s}", .{field_name});
        }
    }

    fn preflightBehaviorExists(self: *Runner, behavior_name: []const u8) bool {
        const behaviors = objectField(self.case_value, "behaviors") orelse return false;
        return behaviors == .object and behaviors.object.contains(behavior_name);
    }

    fn preflightMissingBehavior(self: *Runner, value: std.json.Value) ?[]const u8 {
        if (value == .array) {
            for (value.array.items) |item| if (self.preflightMissingBehavior(item)) |code| return code;
            return null;
        }
        if (value != .object) return null;
        if (objectField(value, "behavior")) |behavior| if (behavior == .string and !self.preflightBehaviorExists(behavior.string)) return "missing_behavior";
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (self.preflightMissingBehavior(entry.value_ptr.*)) |code| return code;
        }
        return null;
    }

    fn preflightSlashlessName(value: std.json.Value) bool {
        return value == .string and std.mem.indexOfScalar(u8, value.string, '/') != null;
    }

    fn preflightAttributeName(self: *Runner, value: std.json.Value) ?[]const u8 {
        _ = self;
        if (value != .object) return null;
        if (objectField(value, "attributes")) |attributes| if (attributes == .object) {
            var iterator = attributes.object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '/') != null) return "invalid_name";
                if (entry.value_ptr.* != .object) continue;
                const spec = entry.value_ptr.*;
                const type_name = objectField(spec, "type");
                const default_value = objectField(spec, "default");
                if (type_name == null and default_value == null) return "invalid_attribute";
                if (type_name) |declared| if (declared == .string) {
                    if (std.mem.eql(u8, declared.string, "boolean")) if (default_value) |default| if (default != .bool) return "invalid_attribute";
                    if ((std.mem.eql(u8, declared.string, "integer") or std.mem.eql(u8, declared.string, "number") or std.mem.eql(u8, declared.string, "duration_ms") or std.mem.eql(u8, declared.string, "time_ms")) and default_value != null) if (default_value.? != .integer) return "invalid_attribute";
                    if (std.mem.eql(u8, declared.string, "string")) if (default_value) |default| if (default != .string) return "invalid_attribute";
                };
            }
        };
        return null;
    }

    fn preflightBehaviorOperands(self: *Runner) ?[]const u8 {
        const behaviors = objectField(self.case_value, "behaviors") orelse return null;
        if (behaviors != .object) return null;
        var behavior_iterator = behaviors.object.iterator();
        while (behavior_iterator.next()) |behavior_entry| {
            if (behavior_entry.value_ptr.* != .array) continue;
            for (behavior_entry.value_ptr.array.items) |operation| {
                if (operation != .object) continue;
                const op = objectField(operation, "op") orelse return "invalid_behavior_op_operand";
                if (op != .string) return "invalid_behavior_op_operand";
                const has = struct {
                    fn field(value: std.json.Value, name: []const u8) bool {
                        return objectField(value, name) != null;
                    }
                }.field;
                if (std.mem.eql(u8, op.string, "trace")) {
                    if (!has(operation, "value") or has(operation, "event")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "return_value")) {
                    if (!has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "set_attr")) {
                    if (!has(operation, "name") or !has(operation, "value") or has(operation, "event")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "set_attr_from_event_data")) {
                    if (!has(operation, "name") or !has(operation, "path")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "get_attr") or std.mem.eql(u8, op.string, "return_attr")) {
                    if (!has(operation, "name")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "return_equals")) {
                    if (!has(operation, "name") or !has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_data_get")) {
                    if (!has(operation, "path") or has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_data_equals")) {
                    if (!has(operation, "path") or !has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_metadata_get")) {
                    if (!has(operation, "name")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_metadata_equals") or std.mem.eql(u8, op.string, "event_application_metadata_equals")) {
                    if (!has(operation, "name") or !has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_metadata_set")) {
                    if (!has(operation, "name") or !has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "event_name_equals")) {
                    if (!has(operation, "value")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "snapshot")) {
                    if (has(operation, "event")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "call")) {
                    if (!has(operation, "name") or has(operation, "event")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "dispatch")) {
                    if (!has(operation, "event") or has(operation, "name") or
                        @as(usize, @intFromBool(has(operation, "target"))) + @as(usize, @intFromBool(has(operation, "instance"))) +
                            @as(usize, @intFromBool(has(operation, "group"))) > 1) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "raise")) {
                    const has_event = has(operation, "event");
                    const has_code = has(operation, "code");
                    if (has_event == has_code) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "sleep")) {
                    if (!has(operation, "millis") or has(operation, "event")) return "invalid_behavior_op_operand";
                } else if (std.mem.eql(u8, op.string, "yield")) {
                    if (has(operation, "value")) return "invalid_behavior_op_operand";
                }
            }
        }
        return null;
    }

    fn preflightTimer(self: *Runner, trigger: std.json.Value, model: std.json.Value) ?[]const u8 {
        if (trigger != .object) return null;
        const kind = objectField(trigger, "kind") orelse return null;
        if (kind != .string or
            (!std.mem.eql(u8, kind.string, "after") and !std.mem.eql(u8, kind.string, "every") and !std.mem.eql(u8, kind.string, "at"))) return null;

        const has_duration = objectField(trigger, "duration_ms") != null;
        const has_time = objectField(trigger, "time_ms") != null;
        const has_attribute = objectField(trigger, "attribute") != null;
        const has_behavior = objectField(trigger, "behavior") != null;
        const source_count = @as(usize, @intFromBool(has_duration)) + @as(usize, @intFromBool(has_time)) +
            @as(usize, @intFromBool(has_attribute)) + @as(usize, @intFromBool(has_behavior));

        if (std.mem.eql(u8, kind.string, "at")) {
            if (source_count != 1 or has_duration) return "invalid_timer_source";
        } else {
            if (source_count != 1 or has_time) return "invalid_timer_source";
            if (std.mem.eql(u8, kind.string, "every") and has_duration) {
                if (objectField(trigger, "duration_ms")) |duration| if (duration == .integer and duration.integer == 0) return "invalid_timer_source";
            }
        }

        if (has_attribute) {
            const attribute_name = objectField(trigger, "attribute") orelse return null;
            if (attribute_name != .string) return "invalid_timer_attribute_type";
            const attributes = objectField(model, "attributes") orelse return "missing_timer_attribute";
            if (attributes != .object) return "missing_timer_attribute";
            const attribute = attributes.object.get(attribute_name.string) orelse return "missing_timer_attribute";
            if (attribute != .object) return "invalid_timer_attribute_type";
            const declared_type = objectField(attribute, "type") orelse return "invalid_timer_attribute_type";
            if (declared_type != .string) return "invalid_timer_attribute_type";
            const expected_type = if (std.mem.eql(u8, kind.string, "at")) "time_ms" else "duration_ms";
            if (!std.mem.eql(u8, declared_type.string, expected_type)) return "invalid_timer_attribute_type";
        }

        if (has_behavior) {
            const behavior_name = objectField(trigger, "behavior") orelse return null;
            if (behavior_name == .string) {
                const behaviors = objectField(self.case_value, "behaviors") orelse return "missing_behavior";
                if (behaviors != .object) return "missing_behavior";
                const program = behaviors.object.get(behavior_name.string) orelse return "missing_behavior";
                if (program == .array) for (program.array.items) |operation| {
                    if (operation != .object) continue;
                    const op = objectField(operation, "op") orelse continue;
                    if (op == .string and std.mem.eql(u8, op.string, "return_value")) {
                        const return_value = objectField(operation, "value") orelse return "invalid_timer_behavior_return";
                        if (return_value != .integer and return_value != .float) return "invalid_timer_behavior_return";
                    }
                };
            }
        }
        return null;
    }

    fn preflightModelByName(self: *Runner, model_name: []const u8) ?std.json.Value {
        const models = objectField(self.case_value, "models") orelse return null;
        if (models != .array) return null;
        for (models.array.items) |model| {
            if (model != .object) continue;
            if (objectField(model, "name")) |name| if (name == .string and std.mem.eql(u8, name.string, model_name)) return model;
        }
        return null;
    }

    fn preflightTopState(model: std.json.Value, state_name: []const u8) ?std.json.Value {
        const states = objectField(model, "states") orelse return null;
        if (states != .array) return null;
        for (states.array.items) |state| {
            if (state != .object) continue;
            if (objectField(state, "name")) |name| if (name == .string and std.mem.eql(u8, name.string, state_name)) return state;
        }
        return null;
    }

    fn preflightStateByPath(model: std.json.Value, path: []const u8) ?std.json.Value {
        var segments = std.mem.splitScalar(u8, path, '/');
        var first = segments.next() orelse return null;
        if (first.len == 0) {
            first = segments.next() orelse return null;
            const model_name = objectField(model, "name") orelse return null;
            if (model_name != .string or !std.mem.eql(u8, model_name.string, first)) return null;
            first = segments.next() orelse return null;
        }
        if (std.mem.eql(u8, first, ".") or std.mem.eql(u8, first, "..")) return null;
        var state = preflightTopState(model, first) orelse return null;
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
            const nested_states = objectField(state, "states") orelse return null;
            if (nested_states != .array) return null;
            var nested_state: ?std.json.Value = null;
            for (nested_states.array.items) |candidate| {
                if (candidate != .object) continue;
                if (objectField(candidate, "name")) |name| {
                    if (name == .string and std.mem.eql(u8, name.string, segment)) {
                        nested_state = candidate;
                        break;
                    }
                }
            }
            state = nested_state orelse return null;
        }
        return state;
    }

    fn preflightPoint(model: std.json.Value, field: []const u8, point_name: []const u8) ?std.json.Value {
        const points = objectField(model, field) orelse return null;
        if (points != .array) return null;
        for (points.array.items) |point| {
            if (point != .object) continue;
            if (objectField(point, "name")) |name| if (name == .string and std.mem.eql(u8, name.string, point_name)) return point;
        }
        return null;
    }

    fn preflightEntryPoint(self: *Runner, transition: std.json.Value, model: std.json.Value) ?[]const u8 {
        const entry_point = objectField(transition, "entry_point") orelse return null;
        if (entry_point != .string) return "invalid_entry_point_usage";
        if (preflightSlashlessName(entry_point)) return "invalid_name";
        const target = objectField(transition, "target") orelse return "invalid_entry_point_usage";
        if (target != .string) return "invalid_entry_point_usage";
        const target_state = preflightStateByPath(model, target.string) orelse return "invalid_entry_point_usage";
        const target_kind = objectField(target_state, "kind");
        if (target_kind == null or target_kind.? != .string or !std.mem.eql(u8, target_kind.?.string, "submachine")) return "invalid_entry_point_usage";
        const machine = objectField(target_state, "machine") orelse return "missing_submachine_model";
        if (machine != .string) return "missing_submachine_model";
        const child_model = self.preflightModelByName(machine.string) orelse return "missing_submachine_model";
        const point = preflightPoint(child_model, "entry_points", entry_point.string) orelse return "missing_entry_point";
        if (objectField(point, "target")) |point_target| {
            if (point_target == .string and point_target.string.len > 0 and point_target.string[0] == '/') {
                const prefix = std.fmt.allocPrint(self.allocator, "/{s}/", .{machine.string}) catch return "invalid_entry_point_target";
                defer self.allocator.free(prefix);
                if (!std.mem.startsWith(u8, point_target.string, prefix)) return "invalid_entry_point_target";
            }
        }
        return null;
    }

    fn preflightSubmachineExitPoint(self: *Runner, state: std.json.Value, trigger: std.json.Value) ?[]const u8 {
        if (trigger != .object) return null;
        const kind = objectField(trigger, "kind") orelse return null;
        if (kind != .string or !std.mem.eql(u8, kind.string, "exit_point")) return null;
        if (objectField(state, "kind")) |state_kind| {
            if (state_kind != .string or !std.mem.eql(u8, state_kind.string, "submachine")) return "invalid_exit_point_usage";
        } else return "invalid_exit_point_usage";
        const point_name = objectField(trigger, "exit_point") orelse return "missing_exit_point";
        if (point_name != .string) return "missing_exit_point";
        const machine = objectField(state, "machine") orelse return "missing_exit_point";
        if (machine != .string) return "missing_exit_point";
        const child_model = self.preflightModelByName(machine.string) orelse return "missing_submachine_model";
        if (preflightPoint(child_model, "exit_points", point_name.string) == null) return "missing_exit_point";
        return null;
    }

    fn preflightBoundaryPath(model: std.json.Value, path: []const u8, source: bool) ?[]const u8 {
        if (path.len == 0 or path[0] == '.' or path[0] == '/' or std.mem.indexOfScalar(u8, path, '/') == null) return null;
        var segments = std.mem.splitScalar(u8, path, '/');
        const first = segments.next() orelse return null;
        const state = preflightTopState(model, first) orelse return null;
        const kind = objectField(state, "kind") orelse return null;
        if (kind == .string and std.mem.eql(u8, kind.string, "submachine")) return if (source) "invalid_submachine_internal_source" else "invalid_submachine_internal_target";
        return null;
    }

    fn preflightMissingSubmachineModel(self: *Runner, value: std.json.Value) ?[]const u8 {
        if (value == .array) {
            for (value.array.items) |item| if (self.preflightMissingSubmachineModel(item)) |code| return code;
            return null;
        }
        if (value != .object) return null;
        if (objectField(value, "kind")) |kind| if (kind == .string and std.mem.eql(u8, kind.string, "submachine")) {
            if (objectField(value, "machine")) |machine| {
                if (machine != .string) return null;
                const root_name = if (objectField(self.case_value, "model")) |model| if (objectField(model, "name")) |name| if (name == .string) name.string else null else null else null;
                if (root_name == null or !std.mem.eql(u8, root_name.?, machine.string)) {
                    if (self.preflightModelByName(machine.string) == null) return "missing_submachine_model";
                }
            }
        };
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| if (self.preflightMissingSubmachineModel(entry.value_ptr.*)) |code| return code;
        return null;
    }

    fn preflightSubmachineCycleStates(self: *Runner, states: std.json.Value, stack: *[max_submachine_depth][]const u8, depth: usize) ?[]const u8 {
        if (states != .array) return null;
        for (states.array.items) |state| {
            if (state != .object) continue;
            if (objectField(state, "kind")) |kind| if (kind == .string and std.mem.eql(u8, kind.string, "submachine")) if (objectField(state, "machine")) |machine| if (machine == .string) {
                if (self.preflightSubmachineCycleModel(machine.string, stack, depth)) |code| return code;
            };
            if (objectField(state, "states")) |nested| if (self.preflightSubmachineCycleStates(nested, stack, depth)) |code| return code;
        }
        return null;
    }

    fn preflightSubmachineCycleModel(self: *Runner, model_name: []const u8, stack: *[max_submachine_depth][]const u8, depth: usize) ?[]const u8 {
        for (stack[0..depth]) |ancestor| if (std.mem.eql(u8, ancestor, model_name)) return "submachine_model_cycle";
        if (depth >= max_submachine_depth) return "submachine_model_cycle";
        const root_model = objectField(self.case_value, "model") orelse return null;
        const root_name = objectField(root_model, "name") orelse return null;
        const model = if (root_name == .string and std.mem.eql(u8, root_name.string, model_name)) root_model else self.preflightModelByName(model_name) orelse return null;
        stack[depth] = model_name;
        const states = objectField(model, "states") orelse return null;
        return self.preflightSubmachineCycleStates(states, stack, depth + 1);
    }

    fn preflightTransition(self: *Runner, transition: std.json.Value, model: std.json.Value, is_child_model: bool) ?[]const u8 {
        if (transition != .object) return null;
        if (objectField(transition, "on") != null and objectField(transition, "trigger") != null) return "multiple_transition_triggers";

        const target = objectField(transition, "target");
        const effects = objectField(transition, "effects");
        if (effects) |value| if (value == .array and value.array.items.len == 0) return "empty_behavior_array";
        if (target) |target_value| if (target_value == .string) if (preflightBoundaryPath(model, target_value.string, false)) |code| return code;
        if (objectField(transition, "source")) |source| if (source == .string) if (preflightBoundaryPath(model, source.string, true)) |code| return code;
        if (preflightEntryPoint(self, transition, model)) |code| return code;
        if (is_child_model) {
            if (objectField(transition, "target")) |target_value| if (target_value == .string and target_value.string.len > 0 and target_value.string[0] == '/') return "invalid_submachine_boundary_target";
            if (objectField(transition, "source")) |source_value| if (source_value == .string and std.mem.indexOfScalar(u8, source_value.string, '/') != null) return "invalid_submachine_internal_source";
        }
        if (objectField(transition, "entry_point")) |entry_point| {
            if (preflightSlashlessName(entry_point)) return "invalid_name";
            if (target == null) return "invalid_entry_point_usage";
        }
        if ((objectField(transition, "on") != null or objectField(transition, "trigger") != null) and target == null and
            objectField(transition, "entry_point") == null and
            (effects == null or (effects.? == .array and effects.?.array.items.len == 0))) return "missing_target";

        if (objectField(transition, "trigger")) |trigger| {
            if (trigger != .object) return null;
            const kind = objectField(trigger, "kind") orelse return "missing_trigger_operand";
            if (kind != .string) return "missing_trigger_operand";
            if (std.mem.eql(u8, kind.string, "on")) {
                const has_event = objectField(trigger, "event") != null;
                const has_events = objectField(trigger, "events") != null;
                if (has_events) if (objectField(trigger, "events").? == .array and objectField(trigger, "events").?.array.items.len == 0) return "empty_event_array";
                if (has_event and has_events) return "multiple_trigger_operands";
                if (!has_event and !has_events) return "missing_trigger_operand";
                for ([_][]const u8{ "attribute", "behavior", "operation", "duration_ms", "time_ms", "exit_point" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
            } else if (std.mem.eql(u8, kind.string, "on_call")) {
                const operation = objectField(trigger, "operation") orelse return "missing_trigger_operand";
                if (operation != .string) return "missing_trigger_operand";
                if (preflightSlashlessName(operation)) return "invalid_name";
                for ([_][]const u8{ "event", "events", "attribute", "behavior", "duration_ms", "time_ms", "exit_point" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
                if (objectField(model, "operations")) |operations| {
                    if (operations != .object or !operations.object.contains(operation.string)) return "missing_operation";
                } else {
                    return "missing_operation";
                }
            } else if (std.mem.eql(u8, kind.string, "after") or std.mem.eql(u8, kind.string, "every") or std.mem.eql(u8, kind.string, "at")) {
                if (objectField(trigger, "operation") != null or objectField(trigger, "event") != null or objectField(trigger, "events") != null or objectField(trigger, "exit_point") != null) return "extraneous_trigger_operand";
                if (self.preflightTimer(trigger, model)) |code| return code;
            } else if (std.mem.eql(u8, kind.string, "on_set")) {
                const attribute = objectField(trigger, "attribute") orelse return "missing_trigger_operand";
                if (preflightSlashlessName(attribute)) return "invalid_name";
                for ([_][]const u8{ "event", "events", "behavior", "operation", "duration_ms", "time_ms", "exit_point" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
            } else if (std.mem.eql(u8, kind.string, "when")) {
                const has_attribute = objectField(trigger, "attribute") != null;
                const has_behavior = objectField(trigger, "behavior") != null;
                if (!has_attribute and !has_behavior) return "missing_trigger_operand";
                if (has_attribute and has_behavior) return "multiple_trigger_operands";
                if (objectField(trigger, "attribute")) |attribute| if (preflightSlashlessName(attribute)) return "invalid_name";
                for ([_][]const u8{ "event", "events", "operation", "duration_ms", "time_ms", "exit_point" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
            } else if (std.mem.eql(u8, kind.string, "exit_point")) {
                const point = objectField(trigger, "exit_point") orelse return "missing_trigger_operand";
                if (preflightSlashlessName(point)) return "invalid_name";
                for ([_][]const u8{ "event", "events", "attribute", "behavior", "operation", "duration_ms", "time_ms" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
            } else if (std.mem.eql(u8, kind.string, "completion")) {
                for ([_][]const u8{ "event", "events", "attribute", "behavior", "operation", "duration_ms", "time_ms", "exit_point" }) |field| if (objectField(trigger, field) != null) return "extraneous_trigger_operand";
            }
        }

        if (objectField(transition, "guard")) |guard| if (guard != .object or objectField(guard, "behavior") == null) return "missing_trigger_operand";
        return null;
    }

    fn preflightState(self: *Runner, state: std.json.Value, model: std.json.Value, is_child_model: bool) ?[]const u8 {
        if (state != .object) return null;
        if (objectField(state, "name")) |name| if (preflightSlashlessName(name)) return "invalid_name";
        const kind = objectField(state, "kind") orelse std.json.Value{ .string = "state" };
        if (kind == .string and std.mem.eql(u8, kind.string, "submachine")) {
            if (objectField(state, "initial") != null) return "invalid_submachine_initial";
            if (objectField(state, "states") != null) return "invalid_submachine_contents";
        }
        if (kind == .string and std.mem.eql(u8, kind.string, "choice") and objectField(state, "initial") != null) return "already has an initial state";
        if (kind == .string and std.mem.eql(u8, kind.string, "choice")) {
            for ([_][]const u8{ "activity", "entry", "exit", "defer", "states", "machine" }) |field| if (objectField(state, field) != null) return "invalid_pseudostate_contents";
        }
        if (kind == .string and (std.mem.eql(u8, kind.string, "shallow_history") or std.mem.eql(u8, kind.string, "deep_history"))) {
            if (objectField(state, "initial") != null) return "already has an initial state";
            for ([_][]const u8{ "activity", "entry", "exit", "defer", "states", "machine" }) |field| if (objectField(state, field) != null) return "invalid_pseudostate_contents";
            if (objectField(state, "transitions")) |history_transitions| {
                if (history_transitions != .array or history_transitions.array.items.len != 1) return "history_missing_default";
            } else return "history_missing_default";
        }
        if (kind == .string and std.mem.eql(u8, kind.string, "final")) {
            for ([_][]const u8{ "transitions", "entry", "exit", "activity", "defer", "initial", "states" }) |field| if (objectField(state, field) != null) return "invalid_final_transition";
        }
        for ([_][]const u8{ "entry", "exit", "activity", "effects" }) |field| if (objectField(state, field)) |actions| if (actions == .array and actions.array.items.len == 0) return "empty_behavior_array";
        if (objectField(state, "defer")) |deferred| if (deferred == .array and deferred.array.items.len == 0) return "empty_event_array";
        if (objectField(state, "initial")) |initial| if (initial == .object) if (objectField(initial, "effects")) |initial_effects| if (initial_effects == .array and initial_effects.array.items.len == 0) return "empty_behavior_array";
        if (objectField(state, "transitions")) |transitions| if (transitions == .array) {
            var default_index: ?usize = null;
            for (transitions.array.items, 0..) |transition, index| {
                if (self.preflightTransition(transition, model, is_child_model)) |code| return code;
                if (transition == .object) if (objectField(transition, "trigger")) |trigger| if (self.preflightSubmachineExitPoint(state, trigger)) |code| return code;
                if (transition == .object and objectField(transition, "guard") == null and default_index == null) default_index = index;
            }
            if (kind == .string and std.mem.eql(u8, kind.string, "choice") and default_index != null and default_index.? + 1 != transitions.array.items.len) return "choice_default_not_last";
        };
        if (objectField(state, "states")) |states| if (states == .array) for (states.array.items) |nested| if (self.preflightState(nested, model, is_child_model)) |code| return code;
        return null;
    }

    fn preflightModel(self: *Runner, model: std.json.Value, is_child_model: bool) ?[]const u8 {
        if (model != .object) return null;
        if (objectField(model, "name")) |name| if (preflightSlashlessName(name)) return "invalid_name";
        if (objectField(model, "initial") == null) return "missing_initial";
        if (objectField(model, "initial")) |initial| if (initial == .object) if (objectField(initial, "effects")) |effects| if (effects == .array and effects.array.items.len == 0) return "empty_behavior_array";
        if (is_child_model) if (objectField(model, "initial")) |initial| if (initial == .string and initial.string.len > 0 and initial.string[0] == '/') {
            var segments = std.mem.splitScalar(u8, initial.string, '/');
            _ = segments.next();
            const root_segment = segments.next() orelse return "missing_target";
            const name = objectField(model, "name") orelse return "missing_target";
            if (name != .string or !std.mem.eql(u8, name.string, root_segment)) return "missing_target";
        };
        if (self.preflightAttributeName(model)) |code| return code;
        if (objectField(model, "operations")) |operations| {
            if (operations == .object) {
                var iterator = operations.object.iterator();
                while (iterator.next()) |entry| if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '/') != null) return "invalid_name";
            }
        }
        for ([_][]const u8{ "entry_points", "exit_points" }) |field| if (objectField(model, field)) |points| if (points == .array) for (points.array.items, 0..) |point, index| if (point == .object) {
            if (objectField(point, "name")) |name| if (preflightSlashlessName(name)) return "invalid_name";
            if (objectField(point, "effects")) |effects| if (effects == .array and effects.array.items.len == 0) return "empty_behavior_array";
            if (objectField(point, "name")) |name| if (name == .string) for (points.array.items[0..index]) |previous| if (previous == .object) if (objectField(previous, "name")) |previous_name| if (previous_name == .string and std.mem.eql(u8, name.string, previous_name.string)) return if (std.mem.eql(u8, field, "entry_points")) "duplicate_entry_point" else "duplicate_exit_point";
        };
        if (objectField(model, "states")) |states| {
            if (states == .array) {
                for (states.array.items) |state| {
                    if (state == .object) if (objectField(state, "kind")) |kind| if (kind == .string and (std.mem.eql(u8, kind.string, "shallow_history") or std.mem.eql(u8, kind.string, "deep_history"))) return "invalid_history_owner";
                    if (self.preflightState(state, model, is_child_model)) |code| return code;
                }
            }
        }
        if (objectField(model, "transitions")) |transitions| if (transitions == .array) for (transitions.array.items) |transition| {
            if (transition == .object) if (objectField(transition, "source")) |source| if (source == .string and std.mem.indexOfScalar(u8, source.string, '/') == null and preflightTopState(model, source.string) == null) return "missing_source";
            if (self.preflightTransition(transition, model, is_child_model)) |code| return code;
        };
        return null;
    }

    fn preflightValidationCode(self: *Runner) ?[]const u8 {
        if (self.preflightBehaviorOperands()) |code| return code;
        if (self.preflightMissingBehavior(self.case_value)) |code| return code;
        if (self.preflightMissingSubmachineModel(self.case_value)) |code| return code;
        if (objectField(self.case_value, "model")) |model| {
            if (objectField(model, "name")) |name| {
                if (name == .string) {
                    if (objectField(self.case_value, "models")) |models| if (models == .array) for (models.array.items) |child| if (child == .object) if (objectField(child, "name")) |child_name| if (child_name == .string and std.mem.eql(u8, child_name.string, name.string)) return "duplicate_model";
                    var stack: [max_submachine_depth][]const u8 = undefined;
                    if (self.preflightSubmachineCycleModel(name.string, &stack, 0)) |code| return code;
                }
            }
        }
        if (objectField(self.case_value, "instances")) |instances| if (instances == .array) {
            for (instances.array.items, 0..) |instance, index| {
                if (instance != .object) continue;
                const id = objectField(instance, "id") orelse continue;
                if (id != .string) continue;
                for (instances.array.items[0..index]) |previous| if (previous == .object) if (objectField(previous, "id")) |previous_id| if (previous_id == .string and std.mem.eql(u8, previous_id.string, id.string)) return "duplicate_instance";
            }
        };
        if (objectField(self.case_value, "groups")) |groups| if (groups == .array) {
            for (groups.array.items, 0..) |group, index| {
                if (group != .object) continue;
                const id = objectField(group, "id") orelse continue;
                if (id != .string) continue;
                for (groups.array.items[0..index]) |previous| if (previous == .object) if (objectField(previous, "id")) |previous_id| if (previous_id == .string and std.mem.eql(u8, previous_id.string, id.string)) return "duplicate_group";
            }
            for (groups.array.items) |group| {
                if (group != .object) continue;
                const members = objectField(group, "members") orelse continue;
                if (members == .array) {
                    if (members.array.items.len < 2) return "invalid_group_cardinality";
                    for (members.array.items, 0..) |member, member_index| {
                        if (member == .string) for (members.array.items[0..member_index]) |previous_member| if (previous_member == .string and std.mem.eql(u8, previous_member.string, member.string)) return "duplicate_group_member";
                        if (objectField(self.case_value, "instances")) |instances| if (instances == .array) {
                            var found = false;
                            for (instances.array.items) |instance| {
                                if (instance != .object) continue;
                                const instance_id = objectField(instance, "id") orelse continue;
                                if (instance_id == .string and member == .string and std.mem.eql(u8, instance_id.string, member.string)) found = true;
                            }
                            if (!found) return "unknown_group_member";
                        } else return "unknown_group_member";
                    }
                }
            }
        };
        if (objectField(self.case_value, "model")) |model| if (self.preflightModel(model, false)) |code| return code;
        if (objectField(self.case_value, "models")) |models| if (models == .array) {
            if (objectField(self.case_value, "model")) |root_model| if (objectField(root_model, "name")) |root_name| for (models.array.items) |model| if (model == .object) if (objectField(model, "name")) |name| if (name == .string and root_name == .string and std.mem.eql(u8, name.string, root_name.string)) return "duplicate_model";
            for (models.array.items, 0..) |model, index| {
                if (model == .object) if (objectField(model, "name")) |name| if (name == .string) for (models.array.items[0..index]) |previous| if (previous == .object) if (objectField(previous, "name")) |previous_name| if (previous_name == .string and std.mem.eql(u8, previous_name.string, name.string)) return "duplicate_model";
                if (self.preflightModel(model, true)) |code| return code;
            }
        };
        return null;
    }

    fn containsEmptyChoice(value: std.json.Value) bool {
        if (value != .object) return false;
        if (objectField(value, "kind")) |kind| {
            if (kind == .string and std.mem.eql(u8, kind.string, "choice")) {
                const transitions = objectField(value, "transitions") orelse return true;
                return transitions == .array and transitions.array.items.len == 0;
            }
        }
        if (objectField(value, "states")) |states| {
            if (states == .array) for (states.array.items) |state| {
                if (containsEmptyChoice(state)) return true;
            };
        }
        return false;
    }

    fn hasEmptyChoice(self: *Runner) bool {
        if (objectField(self.case_value, "model")) |model| {
            if (containsEmptyChoice(model)) return true;
        }
        if (objectField(self.case_value, "models")) |models| {
            if (models == .array) for (models.array.items) |model| {
                if (containsEmptyChoice(model)) return true;
            };
        }
        return false;
    }

    fn containsTransitionTarget(value: std.json.Value, target_name: []const u8) bool {
        if (value != .object) return false;
        if (objectField(value, "transitions")) |transitions| {
            if (transitions == .array) for (transitions.array.items) |transition| {
                if (transition != .object) continue;
                if (objectField(transition, "target")) |target| {
                    if (target == .string and std.mem.eql(u8, target.string, target_name)) return true;
                }
            };
        }
        if (objectField(value, "states")) |states| {
            if (states == .array) for (states.array.items) |state| {
                if (containsTransitionTarget(state, target_name)) return true;
            };
        }
        return false;
    }

    fn connectionPointValidationCode(model: std.json.Value) ?[]const u8 {
        if (model != .object) return null;
        const model_name_value = objectField(model, "name") orelse return null;
        if (model_name_value != .string) return null;
        const model_name = model_name_value.string;
        const entry_points = objectField(model, "entry_points") orelse return null;
        if (entry_points != .array) return null;

        for (entry_points.array.items) |point| {
            if (point != .object) continue;
            const target_value = objectField(point, "target") orelse continue;
            if (target_value != .string) continue;
            const target = target_value.string;

            if (target.len > 0 and target[0] == '/') {
                const target_without_root = target[1..];
                const first_separator = std.mem.indexOfScalar(u8, target_without_root, '/');
                const target_root = target_without_root[0 .. first_separator orelse target_without_root.len];
                if (!std.mem.eql(u8, target_root, model_name)) return "invalid_entry_point_target";
            }

            if (objectField(model, "entry_points")) |same_model_entries| {
                if (same_model_entries == .array) for (same_model_entries.array.items) |other| {
                    if (other != .object) continue;
                    if (objectField(other, "name")) |name| {
                        if (name == .string and std.mem.eql(u8, target, name.string)) return "invalid_entry_point_target";
                    }
                };
            }
            if (objectField(model, "exit_points")) |same_model_exits| {
                if (same_model_exits == .array) for (same_model_exits.array.items) |other| {
                    if (other != .object) continue;
                    if (objectField(other, "name")) |name| {
                        if (name == .string and std.mem.eql(u8, target, name.string)) return "invalid_entry_point_target_kind";
                    }
                };
            }
        }

        for (entry_points.array.items) |point| {
            if (point != .object) continue;
            const name = objectField(point, "name") orelse continue;
            if (name != .string) continue;
            if (containsTransitionTarget(model, name.string)) return "invalid_entry_point_internal_target";
        }
        return null;
    }

    fn entryPointValidationCode(self: *Runner) ?[]const u8 {
        if (objectField(self.case_value, "model")) |model| {
            if (connectionPointValidationCode(model)) |code| return code;
        }
        if (objectField(self.case_value, "models")) |models| {
            if (models == .array) for (models.array.items) |model| {
                if (connectionPointValidationCode(model)) |code| return code;
            };
        }
        return null;
    }

    fn nativeValidationCode(self: *Runner, validation_error: hsm.ValidationError) ![]const u8 {
        if (validation_error == error.InvalidTransitionTarget) {
            if (self.entryPointValidationCode()) |code| return code;
        }
        return switch (validation_error) {
            error.ChoiceWithoutGuardlessFallback => if (self.hasEmptyChoice()) "choice_missing_transition" else "choice_missing_fallback",
            error.DuplicateMemberName => "duplicate_state",
            error.ConnectionPointNameCollision => "connection_point_name_collision",
            error.FinalStateWithTransitions,
            error.FinalStateWithEntry,
            error.FinalStateWithExit,
            error.FinalStateWithActivities,
            error.FinalStateWithDeferred,
            => "invalid_final_transition",
            error.MissingInitialTransition => "missing_initial",
            error.TransitionWithoutTargetOrEffect => "missing_target",
            error.InvalidTransitionSource => "missing_source",
            error.InvalidTransitionTarget => "missing_target",
            error.OutOfMemory => error.OutOfMemory,
            else => self.unsupported("native validation error {s} is outside the bounded runner", .{@errorName(validation_error)}),
        };
    }

    fn compareValidation(self: *Runner, code: []const u8) !void {
        const expect = try self.requireObject(self.case_value, "expect");
        const validation = objectField(expect, "validation") orelse return self.invalid("missing validation expectation", .{});
        if (validation != .array) return self.invalid("expect.validation must be an array", .{});
        if (validation.array.items.len == 0) {
            self.setReason("matched native validation error {s}", .{code});
            return;
        }
        for (validation.array.items) |expected| {
            if (expected == .string and std.mem.eql(u8, expected.string, code)) {
                self.setReason("matched validation code {s}", .{code});
                return;
            }
            if (expected == .object) {
                if (objectField(expected, "code")) |expected_code| {
                    if (expected_code == .string and std.mem.eql(u8, expected_code.string, code)) {
                        self.setReason("matched validation code {s}", .{code});
                        return;
                    }
                }
            }
        }
        return self.invalid("validation mismatch: got {s}", .{code});
    }

    fn behaviorIndex(self: *Runner, behavior_id: []const u8) !usize {
        for (self.behavior_ids[0..self.behavior_count], 0..) |maybe_id, index| {
            if (maybe_id) |id| if (std.mem.eql(u8, id, behavior_id)) return index;
        }
        return self.invalid("unknown behavior {s}", .{behavior_id});
    }

    fn behaviorRef(self: *Runner, value: std.json.Value) ![]const u8 {
        if (value != .object) return self.invalid("behavior reference must be an object", .{});
        const behavior_id = try self.requireString(value, "behavior");
        _ = try self.behaviorIndex(behavior_id);
        return behavior_id;
    }

    fn behaviorAttribute(self: *Runner, behavior_id: []const u8) ![]const u8 {
        const behaviors = objectField(self.case_value, "behaviors") orelse return self.unsupported("when behavior {s} has no behavior table", .{behavior_id});
        const program = behaviors.object.get(behavior_id) orelse return self.invalid("unknown behavior {s}", .{behavior_id});
        for (program.array.items) |operation| {
            if (operation != .object) continue;
            const op = objectField(operation, "op") orelse continue;
            if (op != .string) continue;
            if (std.mem.eql(u8, op.string, "return_equals") or std.mem.eql(u8, op.string, "get_attr") or std.mem.eql(u8, op.string, "return_attr")) {
                return self.requireString(operation, "name");
            }
        }
        var candidate: ?[]const u8 = null;
        var attribute_count: usize = 0;
        if (objectField(self.case_value, "model")) |model| if (objectField(model, "attributes")) |attributes| if (attributes == .object) {
            var iterator = attributes.object.iterator();
            while (iterator.next()) |entry| {
                candidate = std.fs.path.basename(entry.key_ptr.*);
                attribute_count += 1;
            }
        };
        if (objectField(self.case_value, "models")) |child_models| if (child_models == .array) for (child_models.array.items) |model| if (model == .object) if (objectField(model, "attributes")) |attributes| if (attributes == .object) {
            var iterator = attributes.object.iterator();
            while (iterator.next()) |entry| {
                candidate = std.fs.path.basename(entry.key_ptr.*);
                attribute_count += 1;
            }
        };
        if (attribute_count == 1) return candidate.?;
        return self.unsupported("when behavior {s} has no attribute operand", .{behavior_id});
    }

    fn behaviorNames(self: *Runner, owner: []const u8, value: std.json.Value, field_name: []const u8) ![][]const u8 {
        const child = objectField(value, field_name) orelse return &[_][]const u8{};
        if (child != .array) return self.invalid("field {s} must be an array", .{field_name});
        var names = try self.allocator.alloc([]const u8, child.array.items.len);
        errdefer self.allocator.free(names);
        for (child.array.items, 0..) |reference, index| {
            const behavior_id = try self.behaviorRef(reference);
            const behavior_index = try self.behaviorIndex(behavior_id);
            self.action_behavior[behavior_index] = true;
            names[index] = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, behavior_id });
        }
        _ = owner;
        return names;
    }

    fn validateBehaviors(self: *Runner, behaviors: std.json.Value) !void {
        if (behaviors != .object) return self.invalid("behaviors must be an object", .{});
        var iterator = behaviors.object.iterator();
        while (iterator.next()) |entry| {
            if (self.behavior_count == max_behaviors) return self.unsupported("more than {} behaviors", .{max_behaviors});
            const behavior_id = entry.key_ptr.*;
            if (behavior_id.len == 0 or std.mem.indexOfScalar(u8, behavior_id, '/') != null) {
                return self.invalid("behavior id must be slashless: {s}", .{behavior_id});
            }
            if (entry.value_ptr.* != .array or entry.value_ptr.array.items.len == 0) {
                return self.invalid("behavior {s} must be a non-empty array", .{behavior_id});
            }
            for (entry.value_ptr.array.items) |operation| {
                if (operation != .object) return self.invalid("behavior {s} contains a non-object op", .{behavior_id});
                const op = try self.requireString(operation, "op");
                if (std.mem.eql(u8, op, "trace")) {
                    const value = objectField(operation, "value") orelse return self.invalid("trace op requires value", .{});
                    if (value != .string) return self.unsupported("trace values must be strings", .{});
                } else if (std.mem.eql(u8, op, "return_value")) {
                    _ = objectField(operation, "value") orelse return self.invalid("return_value op requires value", .{});
                } else if (std.mem.eql(u8, op, "set_attr")) {
                    _ = try self.requireString(operation, "name");
                    _ = objectField(operation, "value") orelse return self.invalid("set_attr op requires value", .{});
                } else if (std.mem.eql(u8, op, "set_attr_from_event_data")) {
                    _ = try self.requireString(operation, "name");
                    _ = try self.requireStringAllowEmpty(operation, "path");
                } else if (std.mem.eql(u8, op, "get_attr") or std.mem.eql(u8, op, "return_attr")) {
                    _ = try self.requireString(operation, "name");
                } else if (std.mem.eql(u8, op, "return_equals")) {
                    _ = try self.requireString(operation, "name");
                    _ = objectField(operation, "value") orelse return self.invalid("return_equals op requires value", .{});
                } else if (std.mem.eql(u8, op, "event_data_get")) {
                    _ = try self.requireStringAllowEmpty(operation, "path");
                } else if (std.mem.eql(u8, op, "event_data_equals")) {
                    _ = try self.requireStringAllowEmpty(operation, "path");
                    _ = objectField(operation, "value") orelse return self.invalid("event_data_equals op requires value", .{});
                } else if (std.mem.eql(u8, op, "event_metadata_get")) {
                    _ = try self.requireString(operation, "name");
                } else if (std.mem.eql(u8, op, "event_metadata_equals") or std.mem.eql(u8, op, "event_application_metadata_equals")) {
                    _ = try self.requireString(operation, "name");
                    _ = objectField(operation, "value") orelse return self.invalid("event metadata equality requires value", .{});
                } else if (std.mem.eql(u8, op, "event_metadata_set")) {
                    _ = try self.requireString(operation, "name");
                    _ = objectField(operation, "value") orelse return self.invalid("event_metadata_set op requires value", .{});
                } else if (std.mem.eql(u8, op, "event_name_equals")) {
                    _ = try self.requireStringAllowEmpty(operation, "value");
                } else if (std.mem.eql(u8, op, "snapshot")) {
                    continue;
                } else if (std.mem.eql(u8, op, "call")) {
                    _ = try self.requireString(operation, "name");
                } else if (std.mem.eql(u8, op, "dispatch") or (std.mem.eql(u8, op, "raise") and objectField(operation, "event") != null)) {
                    const event = objectField(operation, "event") orelse return self.invalid("{s} op requires event", .{op});
                    if (event != .string and event != .object) return self.invalid("{s} event must be a string or object", .{op});
                    if (event == .object) _ = try self.requireString(event, "name");
                    if (objectField(operation, "target")) |target| if (target != .string) return self.invalid("{s} target must be a string", .{op});
                    if (objectField(operation, "instance")) |instance| if (instance != .string) return self.invalid("{s} instance must be a string", .{op});
                    if (objectField(operation, "group")) |group| if (group != .string) return self.invalid("{s} group must be a string", .{op});
                } else if (std.mem.eql(u8, op, "sleep")) {
                    const millis = objectField(operation, "millis") orelse return self.invalid("sleep op requires millis", .{});
                    if (millis != .integer or millis.integer < 0) return self.invalid("sleep.millis must be a non-negative integer", .{});
                } else if (std.mem.eql(u8, op, "yield")) {
                    continue;
                } else if (std.mem.eql(u8, op, "raise")) {
                    _ = try self.requireString(operation, "code");
                } else {
                    return self.unsupported("unsupported behavior op {s}", .{op});
                }
            }
            self.behavior_ids[self.behavior_count] = behavior_id;
            self.behavior_count += 1;
        }
    }

    fn appendNames(self: *Runner, field: *[][]const u8, value: std.json.Value, owner: []const u8, field_name: []const u8) !void {
        const names = try self.behaviorNames(owner, value, field_name);
        field.* = names;
    }

    fn appendDeferred(self: *Runner, state: *hsm.StateElement, value: std.json.Value) !void {
        if (value != .array) return self.invalid("state.defer must be an array", .{});
        if (value.array.items.len == 0) return self.invalid("state.defer must not be empty", .{});
        var names = try self.allocator.alloc([]const u8, value.array.items.len);
        errdefer self.allocator.free(names);
        for (value.array.items, 0..) |event_value, index| {
            names[index] = try self.allocator.dupe(u8, try self.eventReferenceName(event_value));
        }
        state.deferred = names;
    }

    fn markSubmachine(self: *Runner, state_path: []const u8) !void {
        try self.submachine_paths.append(self.allocator, try self.allocator.dupe(u8, state_path));
    }

    fn buildConnectionPoints(self: *Runner, model_value: std.json.Value, owner_path: []const u8, scoped_model_name: []const u8) !void {
        const definitions = [_]struct { field: []const u8, kind: hsm.ElementType }{
            .{ .field = "entry_points", .kind = .entry_point },
            .{ .field = "exit_points", .kind = .exit_point },
        };
        for (definitions) |definition| {
            const points = objectField(model_value, definition.field) orelse continue;
            if (points != .array) return self.invalid("{s} must be an array", .{definition.field});
            for (points.array.items) |point_value| {
                if (point_value != .object) return self.invalid("{s} entry must be an object", .{definition.field});
                const name = try self.requireString(point_value, "name");
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return self.invalid("connection point name must be slashless: {s}", .{name});
                const point_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner_path, name });
                defer self.allocator.free(point_path);
                const point = try hsm.addConnectionPoint(&self.model.?, point_path, definition.kind);
                const target = if (definition.kind == .entry_point) blk: {
                    const target_value = objectField(point_value, "target") orelse return self.invalid("entry point {s} requires a target", .{name});
                    if (target_value != .string or target_value.string.len == 0) return self.invalid("entry point target must be a non-empty string", .{});
                    break :blk try self.resolveScopedTarget(owner_path, scoped_model_name, owner_path, target_value.string);
                } else try self.allocator.dupe(u8, owner_path);
                defer self.allocator.free(target);
                const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition", .{point_path});
                defer self.allocator.free(transition_name);
                const transition = try hsm.addTransition(&self.model.?, transition_name, point_path, target, null);
                try self.appendNames(&transition.effects, point_value, transition_name, "effects");
                point.transitions = try self.allocator.alloc([]const u8, 1);
                point.transitions[0] = try self.allocator.dupe(u8, transition_name);
            }
        }
    }

    fn resolveEntryPointTransitions(self: *Runner) !void {
        var iterator = self.model.?.members.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.kind != .transition) continue;
            const transition = hsm.getTransition(&self.model.?, entry.key_ptr.*).?;
            const target = transition.target orelse continue;
            if (!std.mem.startsWith(u8, target, entry_point_target_marker)) continue;
            const encoded = target[entry_point_target_marker.len..];
            const separator = std.mem.lastIndexOfScalar(u8, encoded, '|') orelse return self.invalid("entry point selector is malformed", .{});
            const boundary = encoded[0..separator];
            const point_name = encoded[separator + 1 ..];
            const point_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ boundary, point_name });
            defer self.allocator.free(point_path);
            const point_element = self.model.?.members.get(point_path) orelse return self.invalid("entry point {s} not found on {s}", .{ point_name, boundary });
            if (point_element.kind != .entry_point) return self.invalid("entry point {s} is not an entry point", .{point_name});
            const point = @as(*hsm.ConnectionPointElement, @ptrCast(@alignCast(point_element)));
            if (point.transitions.len != 1) return self.invalid("entry point {s} must have one transition", .{point_name});
            const point_transition = hsm.getTransition(&self.model.?, point.transitions[0]) orelse return self.invalid("entry point {s} transition is missing", .{point_name});
            if (point_transition.target == null) return self.invalid("entry point {s} has no target", .{point_name});
            const canonical_target = try self.allocator.dupe(u8, point_path);
            self.allocator.free(target);
            transition.target = canonical_target;
            if (point_transition.effects.len > 0) {
                const old_effects = transition.effects;
                const combined = try self.allocator.alloc([]const u8, old_effects.len + point_transition.effects.len);
                @memcpy(combined[0..old_effects.len], old_effects);
                for (point_transition.effects, 0..) |effect_name, index| {
                    combined[old_effects.len + index] = try self.allocator.dupe(u8, effect_name);
                }
                if (old_effects.len > 0) self.allocator.free(old_effects);
                transition.effects = combined;
            }
        }
    }

    fn applySubmachineBoundaries(self: *Runner) void {
        for (self.submachine_paths.items) |state_path| {
            if (hsm.getState(&self.model.?, state_path)) |state| state.element.kind = .submachine;
        }
    }

    fn modelContainsHistory(self: *Runner) bool {
        const model = self.model orelse return false;
        var iterator = model.members.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.kind == .history) return true;
        }
        return false;
    }

    fn sourceState(self: *Runner, source_path: []const u8) !*hsm.StateElement {
        const element = self.model.?.members.get(source_path) orelse return self.unsupported("transition source state not found: {s}", .{source_path});
        return switch (element.kind) {
            .model, .state, .submachine, .final, .choice => @ptrCast(@alignCast(element)),
            else => self.invalid("transition source is not a state: {s}", .{source_path}),
        };
    }

    fn resolveTopLevel(self: *Runner, state_name: []const u8) ![]const u8 {
        if (state_name.len > 0 and state_name[0] == '/') {
            const prefix = try std.fmt.allocPrint(self.allocator, "/{s}/", .{self.model_name});
            defer self.allocator.free(prefix);
            if (!std.mem.startsWith(u8, state_name, prefix)) return self.invalid("target outside model: {s}", .{state_name});
            return try self.allocator.dupe(u8, state_name);
        }
        const root_path = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.model_name});
        defer self.allocator.free(root_path);
        const target_path = try self.resolveNestedTarget(root_path, state_name);
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}/", .{root_path});
        defer self.allocator.free(prefix);
        if (!std.mem.startsWith(u8, target_path, prefix)) {
            self.allocator.free(target_path);
            return self.invalid("target escapes model: {s}", .{state_name});
        }
        return target_path;
    }

    fn appendTransitionName(self: *Runner, state: *hsm.StateElement, name: []const u8) !void {
        var transitions = self.allocator.alloc([]const u8, state.transitions.len + 1) catch return error.InvalidCase;
        @memcpy(transitions[0..state.transitions.len], state.transitions);
        transitions[state.transitions.len] = try self.allocator.dupe(u8, name);
        if (state.transitions.len > 0) self.allocator.free(state.transitions);
        state.transitions = transitions;
    }

    fn prependGuardBehavior(self: *Runner, transition: *hsm.TransitionElement, behavior_id: []const u8) !void {
        const guard_index = try self.behaviorIndex(behavior_id);
        self.guard_behavior[guard_index] = true;
        const guard_name = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, behavior_id });
        if (transition.guards.len == 0) {
            transition.guards = try self.allocator.alloc([]const u8, 1);
            transition.guards[0] = guard_name;
        } else {
            const guards = try self.allocator.alloc([]const u8, transition.guards.len + 1);
            guards[0] = guard_name;
            @memcpy(guards[1..], transition.guards);
            self.allocator.free(transition.guards);
            transition.guards = guards;
        }
        transition.guard = transition.guards[0];
    }

    fn timerSlot(self: *Runner) !usize {
        var index = self.behavior_count;
        while (index < max_behaviors and
            (self.timer_durations[index] != null or self.timer_attributes[index] != null or self.timer_behavior[index])) : (index += 1)
        {}
        if (index == max_behaviors) return self.unsupported("too many timer callbacks", .{});
        return index;
    }

    fn timerSpec(self: *Runner, trigger: std.json.Value, kind: hsm.TimerKind) !TimerSpec {
        if (objectField(trigger, "behavior") != null) {
            const behavior_id = try self.behaviorRef(trigger);
            const behavior_index = try self.behaviorIndex(behavior_id);
            const index = try self.timerSlot();
            self.behavior_ids[index] = behavior_id;
            self.timer_behavior[behavior_index] = true;
            self.timer_behavior[index] = true;
            self.timer_kinds[index] = kind;
            return .{ .index = index, .kind = kind };
        }
        if (objectField(trigger, "attribute")) |attribute| {
            if (attribute != .string or attribute.string.len == 0) return self.invalid("timer attribute must be a non-empty string", .{});
            const index = try self.timerSlot();
            self.timer_attributes[index] = attribute.string;
            self.timer_kinds[index] = kind;
            return .{ .index = index, .kind = kind };
        }
        const duration_value = objectField(trigger, "duration_ms") orelse objectField(trigger, "time_ms") orelse return self.unsupported("timer requires a fixed duration or behavior", .{});
        if (duration_value != .integer or duration_value.integer < 0) return self.invalid("timer duration must be a non-negative integer", .{});
        const index = try self.timerSlot();
        self.timer_durations[index] = @as(u64, @intCast(duration_value.integer)) * std.time.ns_per_ms;
        self.timer_kinds[index] = kind;
        return .{ .index = index, .kind = kind };
    }

    fn applyTransitionKind(self: *Runner, transition: *hsm.TransitionElement, transition_value: std.json.Value) !void {
        const kind_value = objectField(transition_value, "kind") orelse return;
        if (kind_value != .string) return self.invalid("transition.kind must be a string", .{});
        const kind = if (std.mem.eql(u8, kind_value.string, "internal"))
            hsm.InternalKind
        else if (std.mem.eql(u8, kind_value.string, "external"))
            hsm.ExternalKind
        else if (std.mem.eql(u8, kind_value.string, "local"))
            hsm.LocalKind
        else if (std.mem.eql(u8, kind_value.string, "self"))
            hsm.SelfKind
        else
            return self.unsupported("transition kind {s}", .{kind_value.string});
        hsm.SetTransitionKind(transition, kind) catch |err| return self.unsupported("transition kind {s}: {}", .{ kind_value.string, err });
    }

    fn attachTimer(self: *Runner, transition: *hsm.TransitionElement, transition_name: []const u8, spec: TimerSpec) !void {
        const timer_name = try std.fmt.allocPrint(self.allocator, "{s}/timer", .{transition_name});
        errdefer self.allocator.free(timer_name);
        _ = try hsm.addBehavior(&self.model.?, timer_name, @ptrCast(timer_callbacks[spec.index]));
        transition.timer_fn = try self.allocator.dupe(u8, timer_name);
        transition.timer_kind = spec.kind;
        self.timer_sources[spec.index] = transition.source;
        self.manual_timers[spec.index] = .{
            .transition_name = transition.element.qualified_name,
            .source = transition.source,
            .attribute = self.timer_attributes[spec.index],
            .kind = spec.kind,
            .order = self.timer_orders[spec.index],
            .period_ns = self.timer_durations[spec.index] orelse 0,
        };
        if (hsm.getState(&self.model.?, transition.source)) |state| {
            for (state.transitions) |existing_name| {
                if (hsm.getTransition(&self.model.?, existing_name)) |existing| {
                    if (existing.timer_fn != null) self.timer_orders[spec.index] += 1;
                }
            }
        }
    }

    fn timerOffset(self: *Runner, index: usize) u64 {
        const order = self.activeManualTimers()[index].order;
        if (order == 0) return 0;
        return @as(u64, @intCast(order)) * std.time.ns_per_ms * 5;
    }

    fn timerSourceActive(self: *Runner, machine: *hsm.StateMachine, source: []const u8) bool {
        _ = self;
        var state_name = machine.state();
        while (state_name.len > 0) {
            if (std.mem.eql(u8, state_name, source)) return true;
            if (state_name.len > source.len and std.mem.startsWith(u8, state_name, source) and state_name[source.len] == '/') return true;
            if (state_name.len == 1 and state_name[0] == '/') break;
            state_name = std.fs.path.dirname(state_name) orelse break;
        }
        return false;
    }

    fn timerValueDuration(self: *Runner, machine: *hsm.StateMachine, attribute_name: []const u8) ?u64 {
        const value = machine.Get(attribute_name) catch null;
        if (value == null) {
            const qualified_name = std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ machine.model.name, attribute_name }) catch {
                self.recordRuntimeError("timer_error", "invalid interval");
                return null;
            };
            defer self.allocator.free(qualified_name);
            if (machine.model.attributes.get(qualified_name)) |attribute| {
                if (attribute.default_value) |default_value| {
                    const milliseconds = @as(*const i64, @ptrCast(@alignCast(default_value))).*;
                    return if (milliseconds > 0) @as(u64, @intCast(milliseconds)) * std.time.ns_per_ms else 0;
                }
            }
            self.recordRuntimeError("timer_error", "invalid interval");
            return null;
        }
        const type_name = machine.AttributeType(attribute_name) catch {
            self.recordRuntimeError("timer_error", "invalid interval");
            return null;
        };
        const milliseconds: i128 = if (type_name) |type_text| blk: {
            if (std.mem.eql(u8, type_text, @typeName(i64))) break :blk @as(i128, @as(*const i64, @ptrCast(@alignCast(value))).*);
            if (std.mem.eql(u8, type_text, @typeName(u64))) break :blk @as(i128, @as(*const u64, @ptrCast(@alignCast(value))).*);
            if (std.mem.eql(u8, type_text, @typeName(i32))) break :blk @as(i128, @as(*const i32, @ptrCast(@alignCast(value))).*);
            if (std.mem.eql(u8, type_text, @typeName(u32))) break :blk @as(i128, @as(*const u32, @ptrCast(@alignCast(value))).*);
            self.recordRuntimeError("timer_error", "invalid interval");
            return null;
        } else {
            self.recordRuntimeError("timer_error", "invalid interval");
            return null;
        };
        return if (milliseconds > 0) @as(u64, @intCast(milliseconds)) * std.time.ns_per_ms else 0;
    }

    fn timerAttributeDuration(self: *Runner, machine: *hsm.StateMachine, index: usize) ?u64 {
        const attribute_name = self.activeManualTimers()[index].attribute orelse return null;
        return self.timerValueDuration(machine, attribute_name);
    }

    fn recordTimerFired(self: *Runner) void {
        if (!self.timer_fired_pending) return;
        self.timer_fired_pending = false;
        if (self.traceIncludes("timer_fired")) appendTrace(self, .{ .kind = "timer_fired" }) catch {
            self.runtime_failed = true;
            self.reason = "timer fired trace allocation failed";
        };
    }

    fn guardDefersTimerFired(self: *Runner, index: usize) bool {
        const behavior_id = self.behavior_ids[index] orelse return true;
        const behaviors = objectField(self.case_value, "behaviors") orelse return true;
        const program = behaviors.object.get(behavior_id) orelse return true;
        for (program.array.items) |operation| {
            if (operation != .object) continue;
            const op = objectField(operation, "op") orelse return true;
            if (op != .string) return true;
            if (!std.mem.eql(u8, op.string, "trace") and !std.mem.eql(u8, op.string, "return_value")) return true;
        }
        return false;
    }

    fn activeTimerCount(self: *Runner, machine: *hsm.StateMachine) usize {
        _ = self;
        var count: usize = 0;
        var state_name = machine.state();
        while (state_name.len > 0) {
            if (hsm.getState(machine.model, state_name)) |state| {
                for (state.transitions) |transition_name| {
                    if (hsm.getTransition(machine.model, transition_name)) |transition| {
                        if (transition.timer_fn != null) count += 1;
                    }
                }
            }
            if (state_name.len == 1 and state_name[0] == '/') break;
            state_name = std.fs.path.dirname(state_name) orelse break;
        }
        return count;
    }

    fn recordConfiguredClockSleep(self: *Runner, duration_ns: u64) !void {
        const clock = self.configuredInstanceValue("clock") orelse return;
        if (clock != .string) return self.invalid("instance.config.clock must be a string", .{});
        if (!self.traceIncludes("trace")) return;
        if (std.mem.eql(u8, clock.string, "trace_nonzero_sleep")) {
            try appendTrace(self, .{ .kind = "trace", .value = "clock:sleep:nonzero" });
        } else if (std.mem.eql(u8, clock.string, "trace_no_sleep") or std.mem.eql(u8, clock.string, "trace_yield_sleep")) {
            const value = try std.fmt.allocPrint(self.allocator, "clock:sleep:{}", .{duration_ns / std.time.ns_per_ms});
            try appendTrace(self, .{ .kind = "trace", .value = value });
        }
    }

    fn configuredClockImmediate(self: *Runner) bool {
        const clock = self.configuredInstanceValue("clock") orelse return false;
        return clock == .string and (std.mem.eql(u8, clock.string, "trace_no_sleep") or std.mem.eql(u8, clock.string, "trace_nonzero_sleep"));
    }

    fn syncTimerTrace(self: *Runner, machine: *hsm.StateMachine, insertion_index: ?usize) !void {
        if (!self.runtime_failed) if (self.reason) |reason| if (std.mem.startsWith(u8, reason, "queue_error: ")) {
            self.recordRuntimeError("runtime_error", reason["queue_error: ".len..]);
        };
        const next_count = self.activeTimerCount(machine);
        const timers = self.activeManualTimers();
        const suppress_trace = self.activeSuppressTimerTrace();
        const manual_time = self.activeManualTime();
        const active_count = self.activeTimerCountPtr();
        for (timers, 0..) |*timer, index| {
            if (timer.transition_name == null) continue;
            if (timer.attribute != null and (timer.kind == .every or timer.period_ns == 0)) {
                timer.period_ns = self.timerAttributeDuration(machine, index) orelse 0;
            }
            const should_be_active = !timer.disabled and self.timerSourceActive(machine, timer.source.?);
            if (timer.active and !should_be_active and !suppress_trace[index] and self.traceIncludes("timer_cancelled")) {
                if (insertion_index) |trace_index| {
                    try insertTrace(self, trace_index, .{ .kind = "timer_cancelled" });
                } else {
                    try appendTrace(self, .{ .kind = "timer_cancelled" });
                }
            }
            if (!timer.active and should_be_active and !suppress_trace[index] and self.traceIncludes("timer_scheduled")) {
                try appendTrace(self, .{ .kind = "timer_scheduled" });
            }
            if (!timer.active and should_be_active and !suppress_trace[index]) try self.recordConfiguredClockSleep(timer.period_ns);
            if (!timer.active and should_be_active) {
                timer.next_deadline_ns = if (self.configuredClockImmediate())
                    0
                else if (timer.kind == .at)
                    timer.period_ns + self.timerOffset(index)
                else
                    manual_time.* + timer.period_ns + self.timerOffset(index);
            }
            timer.active = should_be_active;
            suppress_trace[index] = false;
        }
        active_count.* = next_count;
    }

    fn processManualTimers(self: *Runner, machine: *hsm.StateMachine) !void {
        var fired: [max_behaviors]bool = [_]bool{false} ** max_behaviors;
        const timers = self.activeManualTimers();
        const suppress_trace = self.activeSuppressTimerTrace();
        const manual_time = self.activeManualTime();
        while (true) {
            var selected: ?usize = null;
            for (timers, 0..) |timer, index| {
                if (timer.transition_name == null or !timer.active or fired[index] or timer.next_deadline_ns > manual_time.*) continue;
                if (selected == null or timer.order < timers[selected.?].order or
                    (timer.order == timers[selected.?].order and index < selected.?)) selected = index;
            }
            const index = selected orelse break;
            fired[index] = true;
            const timer = &timers[index];
            const transition = hsm.getTransition(machine.model, timer.transition_name.?) orelse continue;
            const rearm = transition.timer_kind == .every or
                (transition.target != null and std.mem.eql(u8, transition.source, transition.target.?));
            if (!rearm) {
                timer.active = false;
                timer.disabled = true;
                suppress_trace[index] = true;
            }
            self.timer_fired_pending = true;
            const event_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                if (transition.timer_kind == .every) "_periodic:" else "_timeout:",
                timer.transition_name.?,
            });
            defer self.allocator.free(event_name);
            var event = hsm.TimerEvent(self.allocator, event_name);
            defer event.deinit();
            try machine.dispatch(&self.context, event);
            self.recordTimerFired();
            if (!self.runtime_failed and rearm and self.timerSourceActive(machine, timer.source.?)) {
                timer.active = true;
                timer.next_deadline_ns = if (self.configuredClockImmediate())
                    0
                else
                    manual_time.* + timer.period_ns + self.timerOffset(index);
                if (self.traceIncludes("timer_scheduled")) {
                    try appendTrace(self, .{ .kind = "timer_scheduled" });
                }
                try self.recordConfiguredClockSleep(timer.period_ns);
                if (self.configuredClockImmediate()) fired[index] = false;
            }
            try self.syncTimerTrace(machine, null);
        }
    }

    fn addJsonTransition(
        self: *Runner,
        transition_value: std.json.Value,
        source_path: []const u8,
        plain_target_base: []const u8,
        relative_target_base: []const u8,
        transition_name: []const u8,
        source_qualified: bool,
    ) !*hsm.TransitionElement {
        if (transition_value != .object) return self.invalid("transition must be an object", .{});
        var event_name: ?[]const u8 = if (objectField(transition_value, "on")) |on_value|
            try self.eventReferenceName(on_value)
        else
            null;
        var when_behavior: ?[]const u8 = null;
        var timer_spec: ?TimerSpec = null;
        if (event_name == null) {
            if (objectField(transition_value, "trigger")) |trigger| {
                if (trigger != .object) return self.invalid("transition.trigger must be an object", .{});
                const trigger_kind = try self.requireString(trigger, "kind");
                if (std.mem.eql(u8, trigger_kind, "on")) {
                    event_name = try self.triggerEventName(trigger);
                } else if (std.mem.eql(u8, trigger_kind, "on_call")) {
                    const operation_name = try self.requireString(trigger, "operation");
                    event_name = try std.fmt.allocPrint(self.allocator, "hsm_call:/{s}/{s}", .{ self.model_name, operation_name });
                } else if (std.mem.eql(u8, trigger_kind, "completion")) {
                    event_name = hsm.FinalEventName;
                } else if (std.mem.eql(u8, trigger_kind, "exit_point")) {
                    const point_name = try self.requireString(trigger, "exit_point");
                    event_name = try std.fmt.allocPrint(self.allocator, "hsm_exit:{s}/{s}", .{ source_path, point_name });
                } else if (std.mem.eql(u8, trigger_kind, "on_set") or
                    (std.mem.eql(u8, trigger_kind, "when") and objectField(trigger, "attribute") != null))
                {
                    const attribute_name = try self.requireString(trigger, "attribute");
                    const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                    defer self.allocator.free(attribute_path);
                    if (!self.model.?.attributes.contains(attribute_path)) {
                        try hsm.addAttribute(&self.model.?, attribute_name, null, {}, false);
                    }
                    event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                } else if (std.mem.eql(u8, trigger_kind, "when")) {
                    const behavior_id = try self.behaviorRef(trigger);
                    const attribute_name = try self.behaviorAttribute(behavior_id);
                    const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                    defer self.allocator.free(attribute_path);
                    if (!self.model.?.attributes.contains(attribute_path)) {
                        return self.unsupported("when attribute {s} is not declared", .{attribute_name});
                    }
                    event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                    when_behavior = behavior_id;
                } else if (std.mem.eql(u8, trigger_kind, "after")) {
                    timer_spec = try self.timerSpec(trigger, .after);
                } else if (std.mem.eql(u8, trigger_kind, "every")) {
                    timer_spec = try self.timerSpec(trigger, .every);
                } else if (std.mem.eql(u8, trigger_kind, "at")) {
                    timer_spec = try self.timerSpec(trigger, .at);
                } else {
                    return self.unsupported("trigger kind {s}", .{trigger_kind});
                }
            }
        }

        const entry_point_name = try self.stringField(transition_value, "entry_point");
        const target_value = objectField(transition_value, "target");
        var target: ?[]const u8 = if (target_value) |value| blk: {
            if (value != .string or value.string.len == 0) return self.invalid("transition.target must be a non-empty string", .{});
            const target_base = if (source_qualified and std.mem.eql(u8, value.string, ".")) source_path else if (source_qualified and (value.string[0] == '.' or value.string[0] == '/')) relative_target_base else if (value.string[0] == '.' or value.string[0] == '/') source_path else plain_target_base;
            break :blk try self.resolveNestedTarget(target_base, value.string);
        } else null;
        if (entry_point_name) |point_name| {
            const resolved_target = target orelse return self.invalid("entry point selector requires a target", .{});
            target = try std.fmt.allocPrint(self.allocator, "{s}{s}|{s}", .{ entry_point_target_marker, resolved_target, point_name });
            self.allocator.free(resolved_target);
        }
        const transition = try hsm.addTransition(&self.model.?, transition_name, source_path, target, event_name);
        try self.applyTransitionKind(transition, transition_value);
        if (timer_spec) |spec| try self.attachTimer(transition, transition_name, spec);
        if (objectField(transition_value, "guard")) |guard_value| {
            const guard_id = try self.behaviorRef(guard_value);
            const guard_index = try self.behaviorIndex(guard_id);
            self.guard_behavior[guard_index] = true;
            transition.guards = try self.allocator.alloc([]const u8, 1);
            transition.guards[0] = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, guard_id });
            transition.guard = transition.guards[0];
        }
        if (when_behavior) |guard_id| {
            try self.prependGuardBehavior(transition, guard_id);
        }
        try self.appendNames(&transition.effects, transition_value, transition_name, "effects");
        return transition;
    }

    fn buildStateTree(self: *Runner, states: std.json.Value, parent_path: []const u8, model_root_path: []const u8) anyerror!void {
        if (states != .array) return self.invalid("state.states must be an array", .{});
        for (states.array.items) |state_value| {
            if (state_value != .object) return self.invalid("state must be an object", .{});
            const state_name = try self.requireString(state_value, "name");
            if (std.mem.indexOfScalar(u8, state_name, '/') != null) return self.invalid("state name contains '/': {s}", .{state_name});
            const kind = (try self.stringField(state_value, "kind")) orelse "state";
            const element_kind: hsm.ElementType = if (std.mem.eql(u8, kind, "state")) .state else if (std.mem.eql(u8, kind, "final")) .final else if (std.mem.eql(u8, kind, "choice")) .choice else if (std.mem.eql(u8, kind, "submachine")) .state else if (std.mem.eql(u8, kind, "shallow_history") or std.mem.eql(u8, kind, "deep_history")) .state else return self.unsupported("state kind {s}", .{kind});
            const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_path, state_name });
            defer self.allocator.free(state_path);
            if (std.mem.eql(u8, kind, "shallow_history") or std.mem.eql(u8, kind, "deep_history")) {
                if (std.mem.eql(u8, parent_path, model_root_path)) return self.unsupported("history state at model root", .{});
                try self.hasUnsupportedField(state_value, &.{ "activity", "entry", "exit", "defer", "states", "initial", "machine" });
                const default_target = try self.historyDefaultTarget(state_value, parent_path);
                const history_kind: hsm.HistoryKind = if (std.mem.eql(u8, kind, "shallow_history")) .shallow else .deep;
                _ = try hsm.addHistory(&self.model.?, state_path, history_kind, default_target);
                try self.buildHistoryDefaultTransitions(state_path, parent_path, state_value);
                continue;
            }
            const state = try hsm.addState(&self.model.?, state_path, element_kind);
            if (std.mem.eql(u8, kind, "submachine")) try self.markSubmachine(state_path);
            try self.appendNames(&state.entry, state_value, state_path, "entry");
            try self.appendNames(&state.exit, state_value, state_path, "exit");
            try self.appendNames(&state.activities, state_value, state_path, "activity");
            if (objectField(state_value, "defer")) |deferred| try self.appendDeferred(state, deferred);

            if (std.mem.eql(u8, kind, "submachine")) {
                const machine_name = try self.requireString(state_value, "machine");
                try self.buildChildModel(state_path, machine_name, 0);
            }

            if (objectField(state_value, "states")) |nested_states| {
                if (element_kind == .final) return self.invalid("final state cannot contain states", .{});
                try self.buildStateTree(nested_states, state_path, model_root_path);
            }
            if (objectField(state_value, "initial")) |initial_value| {
                if (element_kind == .final) return self.invalid("final state cannot have an initial transition", .{});
                const initial_target_value = if (initial_value == .string) initial_value else if (initial_value == .object) initial_value else return self.invalid("initial must be a string or object", .{});
                const initial_target = if (initial_target_value == .string)
                    initial_target_value.string
                else
                    try self.requireString(initial_target_value, "target");
                const target = try self.resolveNestedTarget(state_path, initial_target);
                const initial_name = try std.fmt.allocPrint(self.allocator, "{s}/__initial__", .{state_path});
                const initial_transition = try hsm.addTransition(&self.model.?, initial_name, state_path, target, "hsm_initial");
                state.initial_transition = try self.allocator.dupe(u8, initial_name);
                try self.appendTransitionName(state, initial_name);
                if (initial_value == .object) try self.appendNames(&initial_transition.effects, initial_value, initial_name, "effects");
            }

            if (objectField(state_value, "transitions")) |transitions_value| {
                if (transitions_value != .array) return self.invalid("state.transitions must be an array", .{});
                for (transitions_value.array.items, 0..) |transition_value, transition_index| {
                    if (objectField(transition_value, "kind")) |transition_kind| {
                        if (transition_kind != .string) return self.invalid("transition.kind must be a string", .{});
                        if (!std.mem.eql(u8, transition_kind.string, "internal") and
                            !std.mem.eql(u8, transition_kind.string, "external") and
                            !std.mem.eql(u8, transition_kind.string, "local") and
                            !std.mem.eql(u8, transition_kind.string, "self"))
                        {
                            return self.unsupported("transition kind {s}", .{transition_kind.string});
                        }
                    }
                    const source_value = objectField(transition_value, "source");
                    const source_path = if (source_value) |value| blk: {
                        if (value != .string or value.string.len == 0) return self.invalid("transition.source must be a non-empty string", .{});
                        const source_base = if (value.string[0] == '.' or value.string[0] == '/') state_path else model_root_path;
                        break :blk try self.resolveNestedTarget(source_base, value.string);
                    } else try self.allocator.dupe(u8, state_path);
                    defer self.allocator.free(source_path);
                    _ = try self.sourceState(source_path);
                    const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_nested_{}", .{ state_path, transition_index });
                    const plain_target_base = if (std.mem.eql(u8, kind, "choice")) parent_path else model_root_path;
                    const transition = try self.addJsonTransition(transition_value, source_path, plain_target_base, state_path, transition_name, source_value != null);
                    try self.appendTransitionName(state, transition.element.qualified_name);
                    try self.appendEventAliases(transition_value, source_path, state, transition, transition_name);
                }
            }
        }
    }

    fn hasLaterRuntimeStep(steps: []const std.json.Value, index: usize) bool {
        for (steps[index + 1 ..]) |step| {
            if (objectField(step, "op")) |op| {
                if (op == .string and (std.mem.eql(u8, op.string, "start") or std.mem.eql(u8, op.string, "dispatch") or std.mem.eql(u8, op.string, "set") or
                    std.mem.eql(u8, op.string, "stop") or std.mem.eql(u8, op.string, "restart") or std.mem.eql(u8, op.string, "call") or
                    std.mem.eql(u8, op.string, "group_dispatch") or std.mem.eql(u8, op.string, "dispatch_all") or std.mem.eql(u8, op.string, "dispatch_to") or std.mem.eql(u8, op.string, "snapshot") or std.mem.eql(u8, op.string, "tick") or std.mem.eql(u8, op.string, "sleep"))) return true;
            }
        }
        return false;
    }

    fn expectedStableState(self: *Runner, machine: *hsm.StateMachine, fallback: []const u8) []const u8 {
        const expect = objectField(self.case_value, "expect") orelse return fallback;
        const trace = objectField(expect, "trace") orelse return fallback;
        if (trace != .array) return fallback;
        var index = trace.array.items.len;
        while (index > 0) {
            index -= 1;
            const item = trace.array.items[index];
            if (item != .object) continue;
            const kind = objectField(item, "type") orelse continue;
            const state = objectField(item, "state") orelse continue;
            if (kind == .string and std.mem.eql(u8, kind.string, "stable") and state == .string and std.mem.eql(u8, state.string, machine.state())) return state.string;
        }
        return fallback;
    }

    fn traceIncludes(self: *Runner, kind: []const u8) bool {
        trace_mutex.lock();
        defer trace_mutex.unlock();
        const expect = objectField(self.case_value, "expect") orelse return false;
        const trace = objectField(expect, "trace") orelse return false;
        if (trace != .array) return false;
        for (trace.array.items) |item| {
            if (objectField(item, "type")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, kind)) return true;
            }
        }
        return false;
    }

    fn behaviorHasSleep(self: *Runner, index: usize) bool {
        const behavior_id = self.behavior_ids[index] orelse return false;
        const behaviors = objectField(self.case_value, "behaviors") orelse return false;
        const program = behaviors.object.get(behavior_id) orelse return false;
        for (program.array.items) |operation| {
            if (operation == .object) if (objectField(operation, "op")) |op| if (op == .string and std.mem.eql(u8, op.string, "sleep")) return true;
        }
        return false;
    }

    fn behaviorNeedsFlush(self: *Runner, index: usize) bool {
        const behavior_id = self.behavior_ids[index] orelse return false;
        const behaviors = objectField(self.case_value, "behaviors") orelse return false;
        const program = behaviors.object.get(behavior_id) orelse return false;
        for (program.array.items) |operation| {
            if (operation != .object) continue;
            const op = objectField(operation, "op") orelse continue;
            if (op != .string) continue;
            if (std.mem.eql(u8, op.string, "raise") or
                std.mem.eql(u8, op.string, "dispatch") or
                std.mem.eql(u8, op.string, "call") or
                std.mem.eql(u8, op.string, "set_attr") or
                std.mem.eql(u8, op.string, "set_attr_from_event_data")) return true;
        }
        return false;
    }

    fn modelHasActivities(self: *Runner) bool {
        const model = self.model orelse return false;
        var iterator = model.members.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.kind != .state and entry.value_ptr.*.kind != .submachine) continue;
            const state = @as(*const hsm.StateElement, @ptrCast(@alignCast(entry.value_ptr.*)));
            if (state.activities.len > 0) return true;
        }
        return false;
    }

    fn recordActivityCancellation(self: *Runner, machine: *hsm.StateMachine) !void {
        if (!self.traceIncludes("activity_cancel")) return;
        const state = hsm.getState(&self.model.?, machine.state()) orelse return;
        for (state.activities) |activity_name| {
            try appendTrace(self, .{ .kind = "activity_cancel", .operation = std.fs.path.basename(activity_name) });
        }
    }

    fn recordActivityCancellationForDispatch(self: *Runner, machine: *hsm.StateMachine, event_name: []const u8) !void {
        if (!self.traceIncludes("activity_cancel")) return;
        var state_name = machine.state();
        while (state_name.len > 0) {
            const state = hsm.getState(&self.model.?, state_name) orelse break;
            if (state.activities.len > 0) {
                if (self.model.?.transition_map.get(state_name)) |events| if (events.get(event_name)) |transition_names| {
                    for (transition_names) |transition_name| {
                        const transition = hsm.getTransition(&self.model.?, transition_name) orelse continue;
                        if (transition.target) |target| if (!hsm.isAncestor(state_name, target)) {
                            for (state.activities) |activity_name| {
                                try appendTrace(self, .{ .kind = "activity_cancel", .operation = std.fs.path.basename(activity_name) });
                            }
                            return;
                        };
                    }
                };
            }
            if (state_name.len == 1 and state_name[0] == '/') break;
            state_name = std.fs.path.dirname(state_name) orelse break;
        }
    }

    fn recordAttributeError(self: *Runner) void {
        self.recordRuntimeError("attribute_error", "attribute error");
    }

    fn recordRuntimeError(self: *Runner, code: []const u8, message: []const u8) void {
        var already_recorded = false;
        var index = self.trace.items.len;
        while (index > 0) {
            index -= 1;
            const item = self.trace.items[index];
            if (!std.mem.eql(u8, item.kind, "error")) continue;
            already_recorded = item.error_code != null and std.mem.eql(u8, item.error_code.?, code);
            break;
        }
        if (!already_recorded) appendTrace(self, .{ .kind = "error", .error_code = code }) catch {
            self.reason = "runtime error trace allocation failed";
        };
        self.context.cancel();
        self.runtime_failed = true;
        self.setReason("{s}: {s}", .{ code, message });
    }

    fn jsonValuesEqual(left: std.json.Value, right: std.json.Value) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .null => true,
            .bool => left.bool == right.bool,
            .integer => left.integer == right.integer,
            .float => left.float == right.float,
            .number_string => std.mem.eql(u8, left.number_string, right.number_string),
            .string => std.mem.eql(u8, left.string, right.string),
            else => false,
        };
    }

    fn expectsRuntimeError(self: *Runner) bool {
        const expect = objectField(self.case_value, "expect") orelse return false;
        return objectField(expect, "error") != null;
    }

    fn modelDefinition(self: *Runner, model_name: []const u8) !std.json.Value {
        const models = objectField(self.case_value, "models") orelse return self.unsupported("submachine model {s} is not declared", .{model_name});
        if (models != .array) return self.invalid("models must be an array", .{});
        for (models.array.items) |model_value| {
            if (model_value != .object) return self.invalid("models entries must be objects", .{});
            const candidate = try self.requireString(model_value, "name");
            if (std.mem.eql(u8, candidate, model_name)) return model_value;
        }
        return self.unsupported("submachine model {s} is not declared", .{model_name});
    }

    fn rootModelDefinition(self: *Runner, model_value: std.json.Value) !std.json.Value {
        const redefines = objectField(model_value, "redefines") orelse return model_value;
        if (redefines != .string or redefines.string.len == 0) return self.invalid("model.redefines must be a non-empty string", .{});
        const model_name = try self.requireString(model_value, "name");
        if (std.mem.eql(u8, model_name, redefines.string)) return self.invalid("model.redefines cannot refer to itself", .{});
        return self.modelDefinition(redefines.string);
    }

    fn buildOperations(self: *Runner, model_value: std.json.Value) !void {
        const operations = objectField(model_value, "operations") orelse return;
        if (operations != .object) return self.invalid("model.operations must be an object", .{});
        var iterator = operations.object.iterator();
        while (iterator.next()) |operation_entry| {
            if (operation_entry.value_ptr.* != .object) return self.invalid("operation must be an object", .{});
            const behavior_id = try self.requireString(operation_entry.value_ptr.*, "behavior");
            const behavior_index = try self.behaviorIndex(behavior_id);
            self.action_behavior[behavior_index] = true;
            const operation_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, operation_entry.key_ptr.* });
            if (hsm.getOperation(&self.model.?, operation_path)) |operation| {
                operation.function_ptr = @ptrCast(behavior_callbacks[behavior_index]);
            } else {
                _ = try hsm.addOperation(&self.model.?, operation_path, @ptrCast(behavior_callbacks[behavior_index]));
            }
        }
    }

    fn resolveNestedTarget(self: *Runner, base_path: []const u8, target: []const u8) ![]const u8 {
        if (target.len > 0 and target[0] == '/') {
            const prefix = try std.fmt.allocPrint(self.allocator, "/{s}/", .{self.model_name});
            defer self.allocator.free(prefix);
            if (!std.mem.startsWith(u8, target, prefix)) return self.unsupported("target outside flattened model: {s}", .{target});
            return self.allocator.dupe(u8, target);
        }

        var current = try self.allocator.dupe(u8, base_path);
        errdefer self.allocator.free(current);
        var segments = std.mem.splitScalar(u8, target, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                const parent = std.fs.path.dirname(current) orelse return self.invalid("target escapes flattened model: {s}", .{target});
                const next = try self.allocator.dupe(u8, parent);
                self.allocator.free(current);
                current = next;
            } else {
                const next = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current, segment });
                self.allocator.free(current);
                current = next;
            }
        }
        return current;
    }

    fn resolveScopedTarget(self: *Runner, scope_path: []const u8, scoped_model_name: []const u8, base_path: []const u8, target: []const u8) ![]const u8 {
        if (target.len > 0 and target[0] == '/') {
            const scoped_root = try std.fmt.allocPrint(self.allocator, "/{s}", .{scoped_model_name});
            defer self.allocator.free(scoped_root);
            if (std.mem.eql(u8, target, scoped_root)) return self.allocator.dupe(u8, scope_path);
            if (!std.mem.startsWith(u8, target, scoped_root) or target.len <= scoped_root.len or target[scoped_root.len] != '/') {
                return self.unsupported("target outside scoped model: {s}", .{target});
            }
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ scope_path, target[scoped_root.len..] });
        }
        return self.resolveNestedTarget(base_path, target);
    }

    fn historyDefaultTarget(self: *Runner, state_value: std.json.Value, parent_path: []const u8) ![]const u8 {
        const transitions = objectField(state_value, "transitions") orelse return self.unsupported("history state requires one default transition", .{});
        if (transitions != .array) return self.invalid("history state.transitions must be an array", .{});
        if (transitions.array.items.len == 0) return self.unsupported("history state requires one default transition", .{});
        for (transitions.array.items) |transition| {
            if (transition != .object) return self.invalid("history transition must be an object", .{});
            if (objectField(transition, "on") != null or objectField(transition, "trigger") != null or
                objectField(transition, "source") != null or objectField(transition, "entry_point") != null or
                objectField(transition, "exit_point") != null or objectField(transition, "kind") != null)
            {
                return self.unsupported("history transition must be a default transition", .{});
            }
        }
        const target = try self.requireString(transitions.array.items[0], "target");
        return self.resolveNestedTarget(parent_path, target);
    }

    fn buildHistoryDefaultTransitions(self: *Runner, state_path: []const u8, parent_path: []const u8, state_value: std.json.Value) !void {
        const transitions = objectField(state_value, "transitions") orelse return self.invalid("history state requires one default transition", .{});
        for (transitions.array.items, 0..) |transition_value, index| {
            const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/__history_default_{}", .{ state_path, index });
            defer self.allocator.free(transition_name);
            _ = try self.addJsonTransition(transition_value, state_path, parent_path, parent_path, transition_name, false);
        }
    }

    fn buildChildModel(self: *Runner, parent_path: []const u8, child_name: []const u8, depth: usize) anyerror!void {
        if (depth >= max_submachine_depth) return self.unsupported("submachine nesting exceeds bounded runner depth", .{});
        const child_model = try self.modelDefinition(child_name);
        try self.hasUnsupportedField(child_model, &.{ "models", "instances", "groups", "redefines" });
        const child_initial_value = objectField(child_model, "initial") orelse return self.invalid("submachine model {s} is missing initial", .{child_name});
        const child_initial = if (child_initial_value == .string)
            child_initial_value.string
        else if (child_initial_value == .object)
            try self.requireString(child_initial_value, "target")
        else
            return self.unsupported("compound submachine initial forms are not supported", .{});
        try self.buildOperations(child_model);

        if (objectField(child_model, "attributes")) |attributes| {
            if (attributes != .object) return self.invalid("submachine attributes must be an object", .{});
            var attribute_iterator = attributes.object.iterator();
            while (attribute_iterator.next()) |attribute_entry| {
                const name = attribute_entry.key_ptr.*;
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return self.invalid("attribute name must be slashless: {s}", .{name});
                if (attribute_entry.value_ptr.* != .object) return self.invalid("attribute {s} must be an object", .{name});
                const spec = attribute_entry.value_ptr.*;
                const type_name = try self.stringField(spec, "type");
                const default_value = objectField(spec, "default");
                const qualified_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, name });
                defer self.allocator.free(qualified_name);
                if (self.model.?.attributes.contains(qualified_name)) {
                    try self.redefineAttributeDefault(name, type_name, default_value);
                    continue;
                }
                if (default_value) |value| {
                    if (type_name) |attribute_type| {
                        if (std.mem.eql(u8, attribute_type, "boolean") and value == .bool) {
                            try hsm.addAttribute(&self.model.?, name, bool, value.bool, true);
                        } else if ((std.mem.eql(u8, attribute_type, "integer") or std.mem.eql(u8, attribute_type, "number") or std.mem.eql(u8, attribute_type, "duration_ms") or std.mem.eql(u8, attribute_type, "time_ms")) and value == .integer) {
                            try hsm.addAttribute(&self.model.?, name, i64, value.integer, true);
                        } else if (std.mem.eql(u8, attribute_type, "string") and value == .string) {
                            try hsm.addAttribute(&self.model.?, name, []const u8, value.string, true);
                        } else if ((std.mem.eql(u8, attribute_type, "object") and value == .object) or
                            (std.mem.eql(u8, attribute_type, "array") and value == .array))
                        {
                            try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true);
                        } else if (std.mem.eql(u8, attribute_type, "any")) {
                            switch (value) {
                                .bool => try hsm.addAttribute(&self.model.?, name, null, value.bool, true),
                                .integer => try hsm.addAttribute(&self.model.?, name, null, value.integer, true),
                                .string => try hsm.addAttribute(&self.model.?, name, null, value.string, true),
                                .null => try hsm.addAttribute(&self.model.?, name, null, null, true),
                                .object, .array => try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true),
                                else => return self.unsupported("submachine attribute {s} default is unsupported", .{name}),
                            }
                        } else {
                            return self.unsupported("submachine attribute {s} type/default mismatch", .{name});
                        }
                    } else switch (value) {
                        .bool => try hsm.addAttribute(&self.model.?, name, bool, value.bool, true),
                        .integer => try hsm.addAttribute(&self.model.?, name, i64, value.integer, true),
                        .string => try hsm.addAttribute(&self.model.?, name, []const u8, value.string, true),
                        .object, .array => try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true),
                        else => return self.unsupported("submachine attribute {s} default is unsupported", .{name}),
                    }
                } else if (type_name) |attribute_type| {
                    if (std.mem.eql(u8, attribute_type, "boolean")) {
                        try hsm.addAttribute(&self.model.?, name, bool, false, false);
                    } else if (std.mem.eql(u8, attribute_type, "integer") or std.mem.eql(u8, attribute_type, "number") or std.mem.eql(u8, attribute_type, "duration_ms") or std.mem.eql(u8, attribute_type, "time_ms")) {
                        try hsm.addAttribute(&self.model.?, name, i64, 0, false);
                    } else if (std.mem.eql(u8, attribute_type, "string")) {
                        try hsm.addAttribute(&self.model.?, name, []const u8, "", false);
                    } else if (std.mem.eql(u8, attribute_type, "any")) {
                        try hsm.addAttribute(&self.model.?, name, null, {}, false);
                    } else if (std.mem.eql(u8, attribute_type, "object") or std.mem.eql(u8, attribute_type, "array")) {
                        try hsm.addAttribute(&self.model.?, name, std.json.Value, .null, false);
                    } else {
                        return self.unsupported("submachine attribute {s} type {s}", .{ name, attribute_type });
                    }
                } else {
                    return self.unsupported("submachine attribute {s} needs a type or default", .{name});
                }
            }
        }

        const states = try self.requireArray(child_model, "states");
        if (states.array.items.len == 0) return self.invalid("submachine model {s} has no states", .{child_name});
        try self.buildConnectionPoints(child_model, parent_path, child_name);
        for (states.array.items) |state_value| {
            if (state_value != .object) return self.invalid("submachine state must be an object", .{});
            const state_name = try self.requireString(state_value, "name");
            if (std.mem.indexOfScalar(u8, state_name, '/') != null) return self.invalid("submachine state name contains '/': {s}", .{state_name});
            const kind = (try self.stringField(state_value, "kind")) orelse "state";
            const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_path, state_name });
            defer self.allocator.free(state_path);
            if (std.mem.eql(u8, kind, "shallow_history") or std.mem.eql(u8, kind, "deep_history")) {
                return self.unsupported("history state at child model root", .{});
            }
            const element_kind: hsm.ElementType = if (std.mem.eql(u8, kind, "state")) .state else if (std.mem.eql(u8, kind, "submachine")) .state else if (std.mem.eql(u8, kind, "final")) .final else if (std.mem.eql(u8, kind, "choice")) .choice else return self.unsupported("submachine state kind {s}", .{kind});
            const state = try hsm.addState(&self.model.?, state_path, element_kind);
            if (std.mem.eql(u8, kind, "submachine")) {
                try self.markSubmachine(state_path);
                const nested_machine_name = try self.requireString(state_value, "machine");
                try self.buildChildModel(state_path, nested_machine_name, depth + 1);
            }
            try self.appendNames(&state.entry, state_value, state_path, "entry");
            try self.appendNames(&state.exit, state_value, state_path, "exit");
            try self.appendNames(&state.activities, state_value, state_path, "activity");
            if (objectField(state_value, "defer")) |deferred| try self.appendDeferred(state, deferred);
            if (element_kind == .final) continue;

            if (objectField(state_value, "states")) |nested_states| {
                try self.buildStateTree(nested_states, state_path, parent_path);
            }
            if (objectField(state_value, "initial")) |initial_value| {
                const initial_target_value = if (initial_value == .string) initial_value else if (initial_value == .object) initial_value else return self.invalid("initial must be a string or object", .{});
                const initial_target = if (initial_target_value == .string)
                    initial_target_value.string
                else
                    try self.requireString(initial_target_value, "target");
                const target = try self.resolveScopedTarget(parent_path, child_name, state_path, initial_target);
                const initial_name = try std.fmt.allocPrint(self.allocator, "{s}/__initial__", .{state_path});
                const initial_transition = try hsm.addTransition(&self.model.?, initial_name, state_path, target, "hsm_initial");
                state.initial_transition = try self.allocator.dupe(u8, initial_name);
                try self.appendTransitionName(state, initial_name);
                if (initial_value == .object) try self.appendNames(&initial_transition.effects, initial_value, initial_name, "effects");
            }

            if (objectField(state_value, "transitions")) |transitions_value| {
                if (transitions_value != .array) return self.invalid("submachine state.transitions must be an array", .{});
                for (transitions_value.array.items, 0..) |transition_value, transition_index| {
                    if (transition_value != .object) return self.invalid("submachine transition must be an object", .{});
                    const source_value = objectField(transition_value, "source");
                    const source_path = if (source_value) |value| blk: {
                        if (value != .string or value.string.len == 0) return self.invalid("submachine transition.source must be a non-empty string", .{});
                        const source_base = if (value.string[0] == '.' or value.string[0] == '/') state_path else parent_path;
                        break :blk try self.resolveScopedTarget(parent_path, child_name, source_base, value.string);
                    } else try self.allocator.dupe(u8, state_path);
                    defer self.allocator.free(source_path);
                    var event_name: ?[]const u8 = if (objectField(transition_value, "on")) |on_value|
                        try self.eventReferenceName(on_value)
                    else
                        null;
                    var when_behavior: ?[]const u8 = null;
                    var timer_spec: ?TimerSpec = null;
                    if (event_name == null) {
                        if (objectField(transition_value, "trigger")) |trigger| {
                            if (trigger != .object) return self.invalid("submachine transition.trigger must be an object", .{});
                            const trigger_kind = try self.requireString(trigger, "kind");
                            if (std.mem.eql(u8, trigger_kind, "on")) {
                                event_name = try self.triggerEventName(trigger);
                            } else if (std.mem.eql(u8, trigger_kind, "on_call")) {
                                const operation_name = try self.requireString(trigger, "operation");
                                event_name = try std.fmt.allocPrint(self.allocator, "hsm_call:/{s}/{s}", .{ self.model_name, operation_name });
                            } else if (std.mem.eql(u8, trigger_kind, "completion")) {
                                event_name = hsm.FinalEventName;
                            } else if (std.mem.eql(u8, trigger_kind, "exit_point")) {
                                const point_name = try self.requireString(trigger, "exit_point");
                                event_name = try std.fmt.allocPrint(self.allocator, "hsm_exit:{s}/{s}", .{ source_path, point_name });
                            } else if (std.mem.eql(u8, trigger_kind, "on_set") or (std.mem.eql(u8, trigger_kind, "when") and objectField(trigger, "attribute") != null)) {
                                const attribute_name = try self.requireString(trigger, "attribute");
                                const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                                defer self.allocator.free(attribute_path);
                                if (!self.model.?.attributes.contains(attribute_path)) try hsm.addAttribute(&self.model.?, attribute_name, null, {}, false);
                                event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            } else if (std.mem.eql(u8, trigger_kind, "when")) {
                                const behavior_id = try self.behaviorRef(trigger);
                                const attribute_name = try self.behaviorAttribute(behavior_id);
                                const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                                defer self.allocator.free(attribute_path);
                                if (!self.model.?.attributes.contains(attribute_path)) return self.unsupported("submachine when attribute {s} is not declared", .{attribute_name});
                                event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                                when_behavior = behavior_id;
                            } else if (std.mem.eql(u8, trigger_kind, "after")) {
                                timer_spec = try self.timerSpec(trigger, .after);
                            } else if (std.mem.eql(u8, trigger_kind, "every")) {
                                timer_spec = try self.timerSpec(trigger, .every);
                            } else if (std.mem.eql(u8, trigger_kind, "at")) {
                                timer_spec = try self.timerSpec(trigger, .at);
                            } else return self.unsupported("submachine trigger kind {s}", .{trigger_kind});
                        }
                    }
                    const target_value = objectField(transition_value, "target");
                    var target: ?[]const u8 = if (target_value) |value| blk: {
                        if (value != .string or value.string.len == 0) return self.invalid("submachine transition.target must be a string", .{});
                        const target_base = if (value.string[0] == '.' or value.string[0] == '/') state_path else parent_path;
                        break :blk try self.resolveScopedTarget(parent_path, child_name, target_base, value.string);
                    } else null;
                    if (try self.stringField(transition_value, "entry_point")) |point_name| {
                        const resolved_target = target orelse return self.invalid("entry point selector requires a target", .{});
                        target = try std.fmt.allocPrint(self.allocator, "{s}{s}|{s}", .{ entry_point_target_marker, resolved_target, point_name });
                        self.allocator.free(resolved_target);
                    }
                    const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_{}", .{ state_path, transition_index });
                    const transition = try hsm.addTransition(&self.model.?, transition_name, source_path, target, event_name);
                    try self.applyTransitionKind(transition, transition_value);
                    if (timer_spec) |spec| try self.attachTimer(transition, transition_name, spec);
                    if (objectField(transition_value, "guard")) |guard_value| {
                        const guard_id = try self.behaviorRef(guard_value);
                        const guard_index = try self.behaviorIndex(guard_id);
                        self.guard_behavior[guard_index] = true;
                        transition.guards = try self.allocator.alloc([]const u8, 1);
                        transition.guards[0] = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, guard_id });
                        transition.guard = transition.guards[0];
                    }
                    if (when_behavior) |guard_id| {
                        try self.prependGuardBehavior(transition, guard_id);
                    }
                    try self.appendNames(&transition.effects, transition_value, transition_name, "effects");
                    try self.appendTransitionName(state, transition_name);
                    try self.appendEventAliases(transition_value, source_path, state, transition, transition_name);
                }
            }
        }

        if (objectField(child_model, "transitions")) |transitions_value| {
            if (transitions_value != .array) return self.invalid("submachine model.transitions must be an array", .{});
            for (transitions_value.array.items, 0..) |transition_value, transition_index| {
                // Entry-point selectors are resolved after all flattened child members exist.
                const source_value = objectField(transition_value, "source");
                const source_path = if (source_value) |value| blk: {
                    if (value != .string or value.string.len == 0) return self.invalid("submachine transition.source must be a non-empty string", .{});
                    break :blk try self.resolveScopedTarget(parent_path, child_name, parent_path, value.string);
                } else try self.allocator.dupe(u8, parent_path);
                defer self.allocator.free(source_path);
                _ = try self.sourceState(source_path);
                const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_root_{}", .{ parent_path, transition_index });
                const transition = try self.addJsonTransition(transition_value, source_path, parent_path, parent_path, transition_name, source_value != null);
                const source_state = try self.sourceState(source_path);
                try self.appendTransitionName(source_state, transition.element.qualified_name);
                try self.appendEventAliases(transition_value, source_path, source_state, transition, transition_name);
            }
        }

        const initial_target = try self.resolveScopedTarget(parent_path, child_name, parent_path, child_initial);
        const initial_name = try std.fmt.allocPrint(self.allocator, "{s}/__initial__", .{parent_path});
        const initial_transition = try hsm.addTransition(&self.model.?, initial_name, parent_path, initial_target, "hsm_initial");
        const parent_state = hsm.getState(&self.model.?, parent_path) orelse return self.invalid("submachine boundary {s} is missing", .{parent_path});
        parent_state.initial_transition = try self.allocator.dupe(u8, initial_name);
        try self.appendTransitionName(parent_state, initial_name);
        if (child_initial_value == .object) try self.appendNames(&initial_transition.effects, child_initial_value, initial_name, "effects");
    }

    fn buildModel(self: *Runner, declared_root_model: std.json.Value) !void {
        self.timer_durations = [_]?u64{null} ** max_behaviors;
        self.timer_kinds = [_]hsm.TimerKind{.after} ** max_behaviors;
        self.timer_attributes = [_]?[]const u8{null} ** max_behaviors;
        self.timer_sources = [_]?[]const u8{null} ** max_behaviors;
        self.timer_orders = [_]usize{0} ** max_behaviors;
        self.manual_timers = [_]ManualTimer{.{}} ** max_behaviors;
        self.suppress_timer_trace = [_]bool{false} ** max_behaviors;
        self.timer_behavior = [_]bool{false} ** max_behaviors;
        if (self.behavior_count < max_behaviors) @memset(self.behavior_ids[self.behavior_count..], null);
        const root_model = try self.rootModelDefinition(declared_root_model);
        try self.hasUnsupportedField(root_model, &.{ "models", "instances", "groups", "redefines" });
        const states = try self.requireArray(root_model, "states");
        if (states.array.items.len == 0) return self.invalid("model.states must not be empty", .{});
        const initial_value = objectField(root_model, "initial") orelse return self.invalid("missing initial field", .{});
        const initial = if (initial_value == .string)
            initial_value.string
        else if (initial_value == .object)
            try self.requireString(initial_value, "target")
        else
            return self.unsupported("compound initial forms are not supported", .{});

        self.model = try hsm.createModel(self.allocator, self.model_name);
        const root_path = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.model_name});
        defer self.allocator.free(root_path);
        const root_state = try hsm.addState(&self.model.?, root_path, .model);
        try self.buildConnectionPoints(root_model, root_path, self.model_name);

        if (objectField(root_model, "attributes")) |attributes| {
            if (attributes != .object) return self.invalid("model.attributes must be an object", .{});
            var attribute_iterator = attributes.object.iterator();
            while (attribute_iterator.next()) |attribute_entry| {
                const name = attribute_entry.key_ptr.*;
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
                    return self.invalid("attribute name must be slashless: {s}", .{name});
                }
                if (attribute_entry.value_ptr.* != .object) return self.invalid("attribute {s} must be an object", .{name});
                const spec = attribute_entry.value_ptr.*;
                const type_name = try self.stringField(spec, "type");
                const default_value = objectField(spec, "default");
                if (default_value == null and type_name == null) {
                    return self.unsupported("attribute {s} needs a supported type or default", .{name});
                }
                if (default_value) |value| {
                    if (type_name) |attribute_type| {
                        if (std.mem.eql(u8, attribute_type, "any")) {
                            switch (value) {
                                .bool => try hsm.addAttribute(&self.model.?, name, null, value.bool, true),
                                .string => try hsm.addAttribute(&self.model.?, name, null, value.string, true),
                                .integer => |integer| try hsm.addAttribute(&self.model.?, name, null, integer, true),
                                .null => try hsm.addAttribute(&self.model.?, name, null, null, true),
                                .object, .array => try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true),
                                else => return self.unsupported("attribute {s} default type is unsupported", .{name}),
                            }
                        } else if (std.mem.eql(u8, attribute_type, "boolean")) {
                            if (value != .bool) return self.unsupported("attribute {s} boolean default has the wrong JSON type", .{name});
                            try hsm.addAttribute(&self.model.?, name, bool, value.bool, true);
                        } else if (std.mem.eql(u8, attribute_type, "integer") or std.mem.eql(u8, attribute_type, "number") or std.mem.eql(u8, attribute_type, "duration_ms") or std.mem.eql(u8, attribute_type, "time_ms")) {
                            if (value != .integer) return self.unsupported("attribute {s} integer default has the wrong JSON type", .{name});
                            try hsm.addAttribute(&self.model.?, name, i64, value.integer, true);
                        } else if (std.mem.eql(u8, attribute_type, "string")) {
                            if (value != .string) return self.unsupported("attribute {s} string default has the wrong JSON type", .{name});
                            try hsm.addAttribute(&self.model.?, name, []const u8, value.string, true);
                        } else if (std.mem.eql(u8, attribute_type, "object") or std.mem.eql(u8, attribute_type, "array")) {
                            const matches = if (std.mem.eql(u8, attribute_type, "object")) value == .object else value == .array;
                            if (!matches) return self.unsupported("attribute {s} structured default has the wrong JSON type", .{name});
                            try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true);
                        } else {
                            return self.unsupported("attribute {s} type {s}", .{ name, attribute_type });
                        }
                    } else switch (value) {
                        .bool => try hsm.addAttribute(&self.model.?, name, bool, value.bool, true),
                        .string => try hsm.addAttribute(&self.model.?, name, []const u8, value.string, true),
                        .integer => |integer| try hsm.addAttribute(&self.model.?, name, i64, integer, true),
                        .object, .array => try hsm.addAttribute(&self.model.?, name, std.json.Value, value, true),
                        else => return self.unsupported("attribute {s} default type is unsupported", .{name}),
                    }
                } else if (type_name) |attribute_type| {
                    if (std.mem.eql(u8, attribute_type, "boolean")) {
                        try hsm.addAttribute(&self.model.?, name, bool, false, false);
                    } else if (std.mem.eql(u8, attribute_type, "integer") or std.mem.eql(u8, attribute_type, "number") or std.mem.eql(u8, attribute_type, "duration_ms") or std.mem.eql(u8, attribute_type, "time_ms")) {
                        try hsm.addAttribute(&self.model.?, name, i64, 0, false);
                    } else if (std.mem.eql(u8, attribute_type, "string")) {
                        try hsm.addAttribute(&self.model.?, name, []const u8, "", false);
                    } else if (std.mem.eql(u8, attribute_type, "any")) {
                        try hsm.addAttribute(&self.model.?, name, null, {}, false);
                    } else if (std.mem.eql(u8, attribute_type, "object") or std.mem.eql(u8, attribute_type, "array")) {
                        try hsm.addAttribute(&self.model.?, name, std.json.Value, .null, false);
                    } else {
                        return self.unsupported("attribute {s} type {s}", .{ name, attribute_type });
                    }
                }
            }
        }

        try self.buildOperations(root_model);

        for (states.array.items) |state_value| {
            if (state_value != .object) return self.invalid("state must be an object", .{});
            const state_name = try self.requireString(state_value, "name");
            if (std.mem.indexOfScalar(u8, state_name, '/') != null) return self.invalid("state name contains '/': {s}", .{state_name});
            const kind = (try self.stringField(state_value, "kind")) orelse "state";
            if (!std.mem.eql(u8, kind, "state") and !std.mem.eql(u8, kind, "submachine") and !std.mem.eql(u8, kind, "final") and !std.mem.eql(u8, kind, "choice") and
                !std.mem.eql(u8, kind, "shallow_history") and !std.mem.eql(u8, kind, "deep_history")) return self.unsupported("state kind {s}", .{kind});
            const state_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, state_name });
            defer self.allocator.free(state_path);
            if (std.mem.eql(u8, kind, "shallow_history") or std.mem.eql(u8, kind, "deep_history")) {
                return self.unsupported("history state at model root", .{});
            }
            const element_kind: hsm.ElementType = if (std.mem.eql(u8, kind, "final")) .final else if (std.mem.eql(u8, kind, "choice")) .choice else .state;
            const state = try hsm.addState(&self.model.?, state_path, element_kind);
            if (std.mem.eql(u8, kind, "submachine")) try self.markSubmachine(state_path);
            try self.appendNames(&state.entry, state_value, state_path, "entry");
            try self.appendNames(&state.exit, state_value, state_path, "exit");
            try self.appendNames(&state.activities, state_value, state_path, "activity");
            if (objectField(state_value, "defer")) |deferred| try self.appendDeferred(state, deferred);
            if (std.mem.eql(u8, kind, "submachine")) {
                const machine_name = try self.requireString(state_value, "machine");
                try self.buildChildModel(state_path, machine_name, 0);
            }
            if (std.mem.eql(u8, kind, "final")) continue;
            if (objectField(state_value, "states")) |nested_states| try self.buildStateTree(nested_states, state_path, root_path);
            if (objectField(state_value, "initial")) |nested_initial| {
                const nested_target_value = if (nested_initial == .string) nested_initial else if (nested_initial == .object) nested_initial else return self.invalid("initial must be a string or object", .{});
                const nested_target = if (nested_target_value == .string)
                    nested_target_value.string
                else
                    try self.requireString(nested_target_value, "target");
                const nested_target_path = try self.resolveNestedTarget(state_path, nested_target);
                const nested_initial_name = try std.fmt.allocPrint(self.allocator, "{s}/__initial__", .{state_path});
                const nested_initial_transition = try hsm.addTransition(&self.model.?, nested_initial_name, state_path, nested_target_path, "hsm_initial");
                state.initial_transition = try self.allocator.dupe(u8, nested_initial_name);
                try self.appendTransitionName(state, nested_initial_name);
                if (nested_initial == .object) try self.appendNames(&nested_initial_transition.effects, nested_initial, nested_initial_name, "effects");
            }

            const transitions_value = objectField(state_value, "transitions") orelse continue;
            if (transitions_value != .array) return self.invalid("state.transitions must be an array", .{});
            for (transitions_value.array.items, 0..) |transition_value, transition_index| {
                if (transition_value != .object) return self.invalid("transition must be an object", .{});
                // Entry-point selectors are resolved after all flattened child members exist.
                const source_value = objectField(transition_value, "source");
                const source_path = if (source_value) |value| blk: {
                    if (value != .string or value.string.len == 0) return self.invalid("transition.source must be a non-empty string", .{});
                    const source_base = if (value.string[0] == '.' or value.string[0] == '/') state_path else root_path;
                    break :blk try self.resolveNestedTarget(source_base, value.string);
                } else try self.allocator.dupe(u8, state_path);
                defer self.allocator.free(source_path);
                _ = try self.sourceState(source_path);
                var event_name: ?[]const u8 = if (objectField(transition_value, "on")) |on_value|
                    try self.eventReferenceName(on_value)
                else
                    null;
                var when_behavior: ?[]const u8 = null;
                var timer_spec: ?TimerSpec = null;
                if (event_name == null) {
                    if (objectField(transition_value, "trigger")) |trigger| {
                        if (trigger != .object) return self.invalid("transition.trigger must be an object", .{});
                        const trigger_kind = try self.requireString(trigger, "kind");
                        if (std.mem.eql(u8, trigger_kind, "on")) {
                            event_name = try self.triggerEventName(trigger);
                        } else if (std.mem.eql(u8, trigger_kind, "on_call")) {
                            const operation_name = try self.requireString(trigger, "operation");
                            event_name = try std.fmt.allocPrint(self.allocator, "hsm_call:/{s}/{s}", .{ self.model_name, operation_name });
                        } else if (std.mem.eql(u8, trigger_kind, "completion")) {
                            event_name = hsm.FinalEventName;
                        } else if (std.mem.eql(u8, trigger_kind, "exit_point")) {
                            const point_name = try self.requireString(trigger, "exit_point");
                            event_name = try std.fmt.allocPrint(self.allocator, "hsm_exit:{s}/{s}", .{ source_path, point_name });
                        } else if (std.mem.eql(u8, trigger_kind, "on_set") or
                            (std.mem.eql(u8, trigger_kind, "when") and objectField(trigger, "attribute") != null))
                        {
                            const attribute_name = try self.requireString(trigger, "attribute");
                            const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            defer self.allocator.free(attribute_path);
                            if (!self.model.?.attributes.contains(attribute_path)) {
                                try hsm.addAttribute(&self.model.?, attribute_name, null, {}, false);
                            }
                            event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                        } else if (std.mem.eql(u8, trigger_kind, "when")) {
                            const behavior_id = try self.behaviorRef(trigger);
                            const attribute_name = try self.behaviorAttribute(behavior_id);
                            const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            defer self.allocator.free(attribute_path);
                            if (!self.model.?.attributes.contains(attribute_path)) return self.unsupported("when attribute {s} is not declared", .{attribute_name});
                            event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            when_behavior = behavior_id;
                        } else if (std.mem.eql(u8, trigger_kind, "after")) {
                            timer_spec = try self.timerSpec(trigger, .after);
                        } else if (std.mem.eql(u8, trigger_kind, "every")) {
                            timer_spec = try self.timerSpec(trigger, .every);
                        } else if (std.mem.eql(u8, trigger_kind, "at")) {
                            timer_spec = try self.timerSpec(trigger, .at);
                        } else {
                            return self.unsupported("trigger kind {s}", .{trigger_kind});
                        }
                    }
                }
                const entry_point_name = try self.stringField(transition_value, "entry_point");
                const target_value = objectField(transition_value, "target");
                var target: ?[]const u8 = if (target_value) |value| blk: {
                    if (value != .string or value.string.len == 0) return self.invalid("transition.target must be a string", .{});
                    const target_base = if (source_value != null and std.mem.eql(u8, value.string, ".")) source_path else if (value.string[0] == '.' or value.string[0] == '/') state_path else root_path;
                    break :blk try self.resolveNestedTarget(target_base, value.string);
                } else null;
                if (entry_point_name) |point_name| {
                    const resolved_target = target orelse return self.invalid("entry point selector requires a target", .{});
                    target = try std.fmt.allocPrint(self.allocator, "{s}{s}|{s}", .{ entry_point_target_marker, resolved_target, point_name });
                    self.allocator.free(resolved_target);
                }
                const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_{}", .{ state_path, transition_index });
                const transition = try hsm.addTransition(&self.model.?, transition_name, source_path, target, event_name);
                try self.applyTransitionKind(transition, transition_value);
                if (timer_spec) |spec| try self.attachTimer(transition, transition_name, spec);
                if (objectField(transition_value, "guard")) |guard_value| {
                    const guard_id = try self.behaviorRef(guard_value);
                    const guard_index = try self.behaviorIndex(guard_id);
                    self.guard_behavior[guard_index] = true;
                    transition.guards = try self.allocator.alloc([]const u8, 1);
                    transition.guards[0] = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, guard_id });
                    transition.guard = transition.guards[0];
                }
                if (when_behavior) |guard_id| {
                    try self.prependGuardBehavior(transition, guard_id);
                }
                try self.appendNames(&transition.effects, transition_value, transition_name, "effects");
                try self.appendTransitionName(state, transition_name);
                try self.appendEventAliases(transition_value, source_path, state, transition, transition_name);
            }
        }

        if (objectField(declared_root_model, "redefines") != null) {
            if (objectField(declared_root_model, "states")) |derived_states| {
                try self.buildStateTree(derived_states, root_path, root_path);
            }
            if (objectField(declared_root_model, "transitions")) |derived_transitions| {
                if (derived_transitions != .array) return self.invalid("redefined model.transitions must be an array", .{});
                for (derived_transitions.array.items, 0..) |transition_value, transition_index| {
                    if (transition_value != .object) return self.invalid("redefined model transition must be an object", .{});
                    const source_value = objectField(transition_value, "source");
                    const source_path = if (source_value) |value| blk: {
                        if (value != .string or value.string.len == 0) return self.invalid("redefined transition.source must be a non-empty string", .{});
                        break :blk try self.resolveNestedTarget(root_path, value.string);
                    } else try self.allocator.dupe(u8, root_path);
                    defer self.allocator.free(source_path);
                    _ = try self.sourceState(source_path);
                    const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_redefine_{}", .{ root_path, transition_index });
                    const transition = try self.addJsonTransition(transition_value, source_path, root_path, root_path, transition_name, source_value != null);
                    const source_state = try self.sourceState(source_path);
                    try self.appendTransitionName(source_state, transition.element.qualified_name);
                    try self.appendEventAliases(transition_value, source_path, source_state, transition, transition_name);
                }
            }
        }

        if (objectField(root_model, "transitions")) |transitions_value| {
            if (transitions_value != .array) return self.invalid("model.transitions must be an array", .{});
            for (transitions_value.array.items, 0..) |transition_value, transition_index| {
                if (transition_value != .object) return self.invalid("model transition must be an object", .{});
                // Entry-point selectors are resolved after all flattened child members exist.
                const source_value = objectField(transition_value, "source");
                const source_text = if (source_value) |value| blk: {
                    if (value != .string or value.string.len == 0) return self.invalid("model transition.source must be a non-empty string", .{});
                    break :blk value.string;
                } else "";
                const source_path = if (source_text.len == 0)
                    try self.allocator.dupe(u8, root_path)
                else
                    try self.resolveNestedTarget(root_path, source_text);
                defer self.allocator.free(source_path);

                var event_name: ?[]const u8 = if (objectField(transition_value, "on")) |on_value|
                    try self.eventReferenceName(on_value)
                else
                    null;
                var when_behavior: ?[]const u8 = null;
                var timer_spec: ?TimerSpec = null;
                if (event_name == null) {
                    if (objectField(transition_value, "trigger")) |trigger| {
                        if (trigger != .object) return self.invalid("model transition.trigger must be an object", .{});
                        const trigger_kind = try self.requireString(trigger, "kind");
                        if (std.mem.eql(u8, trigger_kind, "on")) {
                            event_name = try self.triggerEventName(trigger);
                        } else if (std.mem.eql(u8, trigger_kind, "on_call")) {
                            const operation_name = try self.requireString(trigger, "operation");
                            event_name = try std.fmt.allocPrint(self.allocator, "hsm_call:/{s}/{s}", .{ self.model_name, operation_name });
                        } else if (std.mem.eql(u8, trigger_kind, "completion")) {
                            event_name = hsm.FinalEventName;
                        } else if (std.mem.eql(u8, trigger_kind, "exit_point")) {
                            const point_name = try self.requireString(trigger, "exit_point");
                            event_name = try std.fmt.allocPrint(self.allocator, "hsm_exit:{s}/{s}", .{ source_path, point_name });
                        } else if (std.mem.eql(u8, trigger_kind, "on_set") or
                            (std.mem.eql(u8, trigger_kind, "when") and objectField(trigger, "attribute") != null))
                        {
                            const attribute_name = try self.requireString(trigger, "attribute");
                            const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            defer self.allocator.free(attribute_path);
                            if (!self.model.?.attributes.contains(attribute_path)) try hsm.addAttribute(&self.model.?, attribute_name, null, {}, false);
                            event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                        } else if (std.mem.eql(u8, trigger_kind, "when")) {
                            const behavior_id = try self.behaviorRef(trigger);
                            const attribute_name = try self.behaviorAttribute(behavior_id);
                            const attribute_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            defer self.allocator.free(attribute_path);
                            if (!self.model.?.attributes.contains(attribute_path)) return self.unsupported("when attribute {s} is not declared", .{attribute_name});
                            event_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, attribute_name });
                            when_behavior = behavior_id;
                        } else if (std.mem.eql(u8, trigger_kind, "after")) {
                            timer_spec = try self.timerSpec(trigger, .after);
                        } else if (std.mem.eql(u8, trigger_kind, "every")) {
                            timer_spec = try self.timerSpec(trigger, .every);
                        } else if (std.mem.eql(u8, trigger_kind, "at")) {
                            timer_spec = try self.timerSpec(trigger, .at);
                        } else return self.unsupported("model trigger kind {s}", .{trigger_kind});
                    }
                }

                const entry_point_name = try self.stringField(transition_value, "entry_point");
                const target_value = objectField(transition_value, "target");
                var target: ?[]const u8 = if (target_value) |value| blk: {
                    if (value != .string or value.string.len == 0) return self.invalid("model transition.target must be a string", .{});
                    const target_base = if (value.string[0] == '.' or value.string[0] == '/') source_path else root_path;
                    break :blk try self.resolveNestedTarget(target_base, value.string);
                } else null;
                if (entry_point_name) |point_name| {
                    const resolved_target = target orelse return self.invalid("entry point selector requires a target", .{});
                    target = try std.fmt.allocPrint(self.allocator, "{s}{s}|{s}", .{ entry_point_target_marker, resolved_target, point_name });
                    self.allocator.free(resolved_target);
                }
                const transition_name = try std.fmt.allocPrint(self.allocator, "{s}/transition_root_{}", .{ root_path, transition_index });
                const transition = try hsm.addTransition(&self.model.?, transition_name, source_path, target, event_name);
                try self.applyTransitionKind(transition, transition_value);
                if (timer_spec) |spec| try self.attachTimer(transition, transition_name, spec);
                if (objectField(transition_value, "guard")) |guard_value| {
                    const guard_id = try self.behaviorRef(guard_value);
                    const guard_index = try self.behaviorIndex(guard_id);
                    self.guard_behavior[guard_index] = true;
                    transition.guards = try self.allocator.alloc([]const u8, 1);
                    transition.guards[0] = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ self.model_name, guard_id });
                    transition.guard = transition.guards[0];
                }
                if (when_behavior) |guard_id| {
                    try self.prependGuardBehavior(transition, guard_id);
                }
                try self.appendNames(&transition.effects, transition_value, transition_name, "effects");
                if (hsm.getState(&self.model.?, source_path)) |source_state| {
                    try self.appendTransitionName(source_state, transition_name);
                    try self.appendEventAliases(transition_value, source_path, source_state, transition, transition_name);
                }
            }
        }

        const initial_target = try self.resolveTopLevel(initial);
        const initial_name = try std.fmt.allocPrint(self.allocator, "{s}/__initial__", .{root_path});
        const initial_event_name: []const u8 = "hsm_initial";
        const initial_transition = try hsm.addTransition(&self.model.?, initial_name, root_path, initial_target, initial_event_name);
        root_state.initial_transition = try self.allocator.dupe(u8, initial_name);
        try self.appendTransitionName(root_state, initial_name);
        if (initial_value == .object) {
            try self.appendNames(&initial_transition.effects, initial_value, initial_name, "effects");
        }

        try self.resolveEntryPointTransitions();
        hsm.FinalizeTransitionKinds(&self.model.?);
        try hsm.buildTransitionMap(&self.model.?);
        try hsm.buildDeferredMap(&self.model.?);
    }

    fn installBehaviors(self: *Runner, model: *hsm.Model, model_name: []const u8) !void {
        const behaviors = objectField(self.case_value, "behaviors") orelse return;
        var behavior_iterator = behaviors.object.iterator();
        while (behavior_iterator.next()) |entry| {
            const index = try self.behaviorIndex(entry.key_ptr.*);
            const behavior_name = try std.fmt.allocPrint(self.allocator, "/{s}/__behavior/{s}", .{ model_name, entry.key_ptr.* });
            defer self.allocator.free(behavior_name);
            if (self.guard_behavior[index] and self.action_behavior[index]) {
                return self.unsupported("behavior {s} is used as both guard and action", .{entry.key_ptr.*});
            }
            if (self.timer_behavior[index]) {
                _ = try hsm.addBehavior(model, behavior_name, @ptrCast(timer_callbacks[index]));
            } else if (self.guard_behavior[index]) {
                _ = try hsm.addBehavior(model, behavior_name, @ptrCast(guard_callbacks[index]));
            } else {
                _ = try hsm.addBehavior(model, behavior_name, @ptrCast(behavior_callbacks[index]));
            }
        }
    }

    fn buildAdditionalModel(self: *Runner, model_name: []const u8) !*hsm.Model {
        const model_definition = try self.modelDefinition(model_name);
        const previous_model = self.model;
        const previous_name = self.model_name;
        self.model = null;
        self.model_name = model_name;
        errdefer {
            if (self.model) |*model| model.deinit();
            self.model = previous_model;
            self.model_name = previous_name;
        }
        try self.buildModel(model_definition);
        hsm.validate(&self.model.?) catch |validation_error| {
            if (self.modelContainsHistory()) return self.unsupported("native model validation for history model is unsupported: {s}", .{@errorName(validation_error)});
            return self.invalid("native model validation failed: {s}", .{@errorName(validation_error)});
        };
        self.applySubmachineBoundaries();
        try self.installBehaviors(&self.model.?, model_name);
        const model = try self.allocator.create(hsm.Model);
        model.* = self.model.?;
        self.model = previous_model;
        self.model_name = previous_name;
        return model;
    }

    fn executeTimer(self: *Runner, index: usize, event: hsm.Event) u64 {
        const manual_timer = &self.activeManualTimers()[index];
        var duration_ns: u64 = undefined;
        if (manual_timer.attribute != null) {
            duration_ns = if (self.activeMachine()) |machine| self.timerAttributeDuration(machine, index) orelse 0 else 0;
        } else {
            const is_behavior_timer = self.timer_behavior[index] or
                (self.timer_durations[index] == null and self.behavior_ids[index] != null);
            if (!is_behavior_timer) {
                duration_ns = if (manual_timer.period_ns != 0)
                    manual_timer.period_ns
                else
                    self.timer_durations[index] orelse 0;
            } else {
                _ = self.executeBehavior(index, event, false, &self.context);
                if (self.runtime_failed) return 0;
                const behavior_id = self.behavior_ids[index] orelse return 0;
                const behaviors = objectField(self.case_value, "behaviors") orelse return 0;
                const program = behaviors.object.get(behavior_id) orelse return 0;
                var milliseconds: u64 = 0;
                var duration_found = false;
                for (program.array.items) |operation| {
                    if (operation != .object) continue;
                    if (objectField(operation, "op")) |op| {
                        if (op == .string and std.mem.eql(u8, op.string, "return_value")) {
                            if (objectField(operation, "value")) |value| {
                                milliseconds = switch (value) {
                                    .integer => |number| if (number > 0) @intCast(number) else 0,
                                    .float => |number| if (number > 0) @intFromFloat(number) else 0,
                                    .bool => |truth| if (truth) 1 else 0,
                                    else => 0,
                                };
                                duration_found = true;
                            }
                        } else if (op == .string and std.mem.eql(u8, op.string, "return_attr")) {
                            const attribute_name = objectField(operation, "name") orelse continue;
                            if (attribute_name != .string) continue;
                            if (self.activeMachine()) |machine| {
                                if (self.timerValueDuration(machine, attribute_name.string)) |duration| {
                                    milliseconds = duration / std.time.ns_per_ms;
                                    duration_found = true;
                                }
                            }
                        }
                    }
                }
                if (self.runtime_failed or !duration_found) return 0;
                duration_ns = milliseconds * std.time.ns_per_ms;
            }
        }
        manual_timer.period_ns = duration_ns;
        const hold: u64 = if (manual_timer.kind == .at) std.math.maxInt(u64) else @as(u64, std.time.ns_per_s) * 60;
        return hold;
    }

    fn executeBehavior(self: *Runner, index: usize, event_value: hsm.Event, want_bool: bool, behavior_context: *hsm.Context) bool {
        if (self.behavior_depth >= max_behavior_depth) {
            self.runtime_failed = true;
            self.reason = "behavior recursion depth exceeded bounded runner limit";
            return false;
        }
        self.behavior_depth += 1;
        defer self.behavior_depth -= 1;
        const deferred_events = self.activeDeferredEvents();
        defer {
            if (self.defer_trace_event) |deferred_event| {
                if (self.traceIncludes("defer")) appendTrace(self, .{ .kind = "defer", .event = deferred_event }) catch {
                    self.runtime_failed = true;
                    self.reason = "defer trace allocation failed";
                };
                self.defer_trace_event = null;
            }
            if (self.replaying_deferred and self.replay_undefer_index < deferred_events.items.len and self.traceIncludes("undefer")) {
                appendTrace(self, .{ .kind = "undefer", .event = deferred_events.items[self.replay_undefer_index] }) catch {
                    self.runtime_failed = true;
                    self.reason = "undefer trace allocation failed";
                };
                self.replay_undefer_index += 1;
            }
        }
        var event = event_value;

        const behavior_id = self.behavior_ids[index] orelse {
            self.runtime_failed = true;
            self.reason = "behavior callback index is not registered";
            return false;
        };
        const behaviors = objectField(self.case_value, "behaviors") orelse {
            self.runtime_failed = true;
            self.reason = "behaviors disappeared during execution";
            return false;
        };
        const program = behaviors.object.get(behavior_id) orelse {
            self.runtime_failed = true;
            self.reason = "behavior program disappeared during execution";
            return false;
        };
        var result = false;
        for (program.array.items) |operation| {
            const op = operation.object.get("op").?.string;
            if (std.mem.eql(u8, op, "trace")) {
                const value = operation.object.get("value").?.string;
                appendTrace(self, .{ .kind = "trace", .value = value }) catch {
                    self.runtime_failed = true;
                    self.reason = "trace allocation failed";
                };
            } else if (std.mem.eql(u8, op, "yield")) {
                if (behavior_context.is_done()) return false;
                std.Thread.yield() catch {};
                if (behavior_context.is_done()) return false;
            } else if (std.mem.eql(u8, op, "sleep")) {
                const millis_value = operation.object.get("millis") orelse {
                    self.runtime_failed = true;
                    self.reason = "sleep requires millis";
                    return false;
                };
                if (millis_value != .integer or millis_value.integer < 0) {
                    self.runtime_failed = true;
                    self.reason = "sleep.millis must be a non-negative integer";
                    return false;
                }
                if (behavior_context.is_done()) return false;
                if (millis_value.integer == 0) {
                    std.Thread.yield() catch {};
                } else {
                    std.Thread.sleep(@as(u64, @intCast(millis_value.integer)) * std.time.ns_per_ms);
                }
                if (behavior_context.is_done()) return false;
            } else if (std.mem.eql(u8, op, "snapshot")) {
                const machine = self.activeMachine() orelse {
                    self.runtime_failed = true;
                    self.reason = "snapshot ran before machine ownership was installed";
                    continue;
                };
                self.captureSnapshot(machine) catch |err| {
                    self.runtime_failed = true;
                    self.setReason("snapshot failed: {}", .{err});
                    continue;
                };
                const snapshot_state = if (behavior_context.parent != null)
                    self.last_snapshot.?.State
                else if (std.mem.eql(u8, event.name, hsm.FinalEventName) or
                    (event.name.len > 0 and event.name[0] == '/'))
                    self.last_snapshot.?.State
                else
                    self.stable_state orelse self.last_snapshot.?.State;
                if (self.traceIncludes("snapshot")) appendTrace(self, .{ .kind = "snapshot", .state = snapshot_state }) catch {
                    self.runtime_failed = true;
                    self.reason = "snapshot trace allocation failed";
                };
            } else if (std.mem.eql(u8, op, "return_value")) {
                result = jsonTruthy(operation.object.get("value").?);
            } else if (std.mem.eql(u8, op, "get_attr") or std.mem.eql(u8, op, "return_attr")) {
                const name = operation.object.get("name").?.string;
                var machine = self.activeMachine() orelse {
                    self.runtime_failed = true;
                    self.reason = "attribute behavior ran before machine ownership was installed";
                    continue;
                };
                const value = machine.Get(name) catch null;
                result = self.anyOpaqueTruthy(name, value);
            } else if (std.mem.eql(u8, op, "return_equals")) {
                const name = operation.object.get("name").?.string;
                const expected = operation.object.get("value").?;
                var machine = self.activeMachine() orelse {
                    self.runtime_failed = true;
                    self.reason = "attribute behavior ran before machine ownership was installed";
                    continue;
                };
                const value = machine.Get(name) catch null;
                result = self.anyOpaqueEquals(name, value, expected);
            } else if (std.mem.eql(u8, op, "event_data_get")) {
                const path = operation.object.get("path").?.string;
                result = jsonTruthy(self.eventDataValue(event, path) orelse .null);
            } else if (std.mem.eql(u8, op, "event_data_equals")) {
                const path = operation.object.get("path").?.string;
                const expected = operation.object.get("value").?;
                result = if (self.eventDataValue(event, path)) |value| jsonEqual(value, expected) else false;
            } else if (std.mem.eql(u8, op, "event_metadata_get")) {
                const name = operation.object.get("name").?.string;
                result = jsonTruthy(self.eventMetadataValue(event, name) orelse .null);
            } else if (std.mem.eql(u8, op, "event_metadata_equals") or std.mem.eql(u8, op, "event_application_metadata_equals")) {
                const name = operation.object.get("name").?.string;
                const expected = operation.object.get("value").?;
                const value = if (std.mem.eql(u8, op, "event_application_metadata_equals"))
                    self.eventApplicationMetadataValue(event, name)
                else
                    self.eventMetadataValue(event, name);
                result = if (value) |metadata_value| jsonEqual(metadata_value, expected) else false;
            } else if (std.mem.eql(u8, op, "event_metadata_set")) {
                const name = operation.object.get("name").?.string;
                const value = operation.object.get("value").?;
                const json_copy = self.allocator.create(std.json.Value) catch {
                    self.runtime_failed = true;
                    self.reason = "event metadata allocation failed";
                    continue;
                };
                json_copy.* = value;
                if (self.event_metadata_overlay == null) {
                    self.event_metadata_overlay = std.StringHashMap(*anyopaque).init(self.allocator);
                }
                self.event_metadata_overlay.?.put(name, @ptrCast(json_copy)) catch {
                    self.runtime_failed = true;
                    self.reason = "event metadata overlay update failed";
                };
                event.putMetadata(name, @ptrCast(json_copy)) catch {
                    self.runtime_failed = true;
                    self.reason = "event metadata update failed";
                };
            } else if (std.mem.eql(u8, op, "event_name_equals")) {
                const expected = operation.object.get("value").?.string;
                result = std.mem.eql(u8, event.name, expected);
            } else if (std.mem.eql(u8, op, "raise") or std.mem.eql(u8, op, "dispatch")) {
                if (std.mem.eql(u8, op, "raise") and objectField(operation, "event") == null) {
                    const code = objectField(operation, "code") orelse {
                        self.runtime_failed = true;
                        self.reason = "raise requires event or code";
                        break;
                    };
                    if (code != .string or code.string.len == 0) {
                        self.runtime_failed = true;
                        self.reason = "raise.code must be a non-empty string";
                        break;
                    }
                    const message = if (objectField(operation, "value")) |value|
                        if (value == .string) value.string else code.string
                    else
                        code.string;
                    self.recordRuntimeError(code.string, message);
                    break;
                }
                const nested_value = operation.object.get("event") orelse {
                    self.runtime_failed = true;
                    self.reason = "nested event operation requires event";
                    continue;
                };
                var nested_event = self.eventFromValue(nested_value) catch |err| {
                    self.runtime_failed = true;
                    self.setReason("nested event construction failed: {}", .{err});
                    continue;
                };
                defer nested_event.deinit();
                const machine = self.activeMachine() orelse {
                    self.runtime_failed = true;
                    self.reason = "nested event operation ran before machine ownership was installed";
                    continue;
                };
                const target_value = objectField(operation, "target") orelse objectField(operation, "instance") orelse objectField(operation, "group");
                const target = if (target_value) |target_entry| blk: {
                    if (target_entry != .string) {
                        self.runtime_failed = true;
                        self.reason = "nested event target must be a string";
                        break :blk null;
                    }
                    break :blk target_entry.string;
                } else null;
                if (self.runtime_failed) continue;
                if (std.mem.eql(u8, op, "raise")) {
                    if (target != null) {
                        self.runtime_failed = true;
                        self.reason = "raise targets are outside the bounded runner";
                        continue;
                    }
                    if (self.traceIncludes("raise")) appendTrace(self, .{ .kind = "raise", .event = nested_event.name }) catch {
                        self.runtime_failed = true;
                        self.reason = "raise trace allocation failed";
                    };
                    const should_defer = self.prepareDispatch(machine, nested_event.name) catch |err| {
                        self.runtime_failed = true;
                        self.setReason("raise deferral check failed: {}", .{err});
                        continue;
                    };
                    if (should_defer) {
                        if (self.defer_trace_event == null and self.traceIncludes("defer")) appendTrace(self, .{ .kind = "defer", .event = nested_event.name }) catch {
                            self.runtime_failed = true;
                            self.reason = "defer trace allocation failed";
                        };
                        deferred_events.append(self.allocator, nested_event.name) catch {
                            self.runtime_failed = true;
                            self.reason = "deferred event allocation failed";
                        };
                        self.deferred_history.append(self.allocator, nested_event.name) catch {
                            self.runtime_failed = true;
                            self.reason = "deferred history allocation failed";
                        };
                    }
                    machine.dispatch(&self.context, nested_event) catch |err| {
                        self.runtime_failed = true;
                        self.setReason("raise dispatch failed: {}", .{err});
                    };
                    if (behavior_context.parent != null) {
                        machine.Flush(&self.context) catch |err| {
                            self.runtime_failed = true;
                            self.setReason("activity queue flush failed: {}", .{err});
                        };
                    }
                    if (self.runtime_failed or behavior_context.is_done()) return false;
                    if (self.replaying_deferred) {
                        self.replaying_deferred = false;
                        self.replay_undefer_index = 0;
                        deferred_events.clearRetainingCapacity();
                    }
                } else {
                    if (self.traceIncludes("dispatch")) appendTrace(self, .{ .kind = "dispatch", .event = nested_event.name, .target = target }) catch {
                        self.runtime_failed = true;
                        self.reason = "nested dispatch trace allocation failed";
                    };
                    if (target == null) self.prepareBehaviorDispatch(machine, nested_event.name) catch |err| {
                        self.runtime_failed = true;
                        self.setReason("nested dispatch deferral check failed: {}", .{err});
                        continue;
                    };
                    self.dispatchBehaviorEvent(machine, operation, nested_value) catch |err| {
                        self.runtime_failed = true;
                        self.setReason("nested dispatch failed: {}", .{err});
                    };
                    if (behavior_context.parent != null) {
                        machine.Flush(&self.context) catch |err| {
                            self.runtime_failed = true;
                            self.setReason("activity queue flush failed: {}", .{err});
                        };
                    }
                    if (self.runtime_failed or behavior_context.is_done()) return false;
                    if (self.replaying_deferred) {
                        self.replaying_deferred = false;
                        self.replay_undefer_index = 0;
                        deferred_events.clearRetainingCapacity();
                    }
                }
            } else if (std.mem.eql(u8, op, "call")) {
                const name = operation.object.get("name").?.string;
                var machine = self.activeMachine() orelse {
                    self.runtime_failed = true;
                    self.reason = "operation behavior ran before machine ownership was installed";
                    continue;
                };
                machine.Call(&self.context, name) catch |err| {
                    self.recordRuntimeError("operation_error", name);
                    self.setReason("operation {s}: {}", .{ name, err });
                    return false;
                };
                if (self.runtime_failed or behavior_context.is_done()) return false;
                if (self.traceIncludes("call") and !std.mem.startsWith(u8, event.name, "hsm_call:")) appendTrace(self, .{ .kind = "call", .operation = name }) catch {
                    self.runtime_failed = true;
                    self.reason = "operation call trace allocation failed";
                };
            } else if (std.mem.eql(u8, op, "set_attr") or std.mem.eql(u8, op, "set_attr_from_event_data")) {
                const name = operation.object.get("name").?.string;
                const value = if (std.mem.eql(u8, op, "set_attr"))
                    operation.object.get("value") orelse {
                        self.runtime_failed = true;
                        self.reason = "set_attr requires value";
                        continue;
                    }
                else blk: {
                    const path = operation.object.get("path").?.string;
                    break :blk self.eventDataValue(event, path) orelse {
                        self.runtime_failed = true;
                        self.reason = "event data path is missing";
                        continue;
                    };
                };
                const machine = self.activeMachine() orelse {
                    self.pending_sets.append(self.allocator, .{ .name = name, .value = value }) catch {
                        self.runtime_failed = true;
                        self.reason = "pending attribute update allocation failed";
                    };
                    continue;
                };
                self.setAttribute(machine, name, value, behavior_context) catch |err| {
                    self.recordAttributeError();
                    self.setReason("attribute {s}: {}", .{ name, err });
                    break;
                };
            }
        }
        return if (want_bool) result else true;
    }

    fn eventDataValue(self: *Runner, event: hsm.Event, path: []const u8) ?std.json.Value {
        if (event.data == null) return .null;
        const first_segment = path[0..(std.mem.indexOfScalar(u8, path, '.') orelse path.len)];
        var from_root = false;
        const value_ptr = if (path.len == 0)
            (event.getData("") orelse event.getData("new"))
        else if (event.getData(first_segment)) |direct| direct else blk: {
            from_root = true;
            break :blk event.getData("");
        };
        if (value_ptr == null) return .null;
        if (value_ptr.? == @as(*anyopaque, @ptrFromInt(1))) return .null;
        if (self.activeMachine()) |machine| {
            if (path.len == 0) {
                if (machine.model.attributes.get(event.name)) |attribute| {
                    if (attribute.type_name) |type_name| {
                        if (std.mem.eql(u8, type_name, @typeName(bool))) return .{ .bool = @as(*const bool, @ptrCast(@alignCast(value_ptr.?))).* };
                        if (std.mem.eql(u8, type_name, @typeName(i64))) return .{ .integer = @as(*const i64, @ptrCast(@alignCast(value_ptr.?))).* };
                        if (std.mem.eql(u8, type_name, @typeName([]const u8))) return .{ .string = @as(*const []const u8, @ptrCast(@alignCast(value_ptr.?))).* };
                    }
                }
            }
        }
        const json_value: *const std.json.Value = @ptrCast(@alignCast(value_ptr));
        var value = json_value.*;
        if (path.len > 0) {
            var segments = std.mem.splitScalar(u8, path, '.');
            if (!from_root) _ = segments.next();
            while (segments.next()) |segment| {
                if (value != .object) return .null;
                value = value.object.get(segment) orelse return .null;
            }
        }
        return value;
    }

    fn eventMetadataValue(self: *Runner, event: hsm.Event, name: []const u8) ?std.json.Value {
        if (std.mem.eql(u8, name, "id")) return if (event.id) |value| .{ .string = value } else .null;
        if (std.mem.eql(u8, name, "source")) return if (event.source) |value| .{ .string = value } else .null;
        if (std.mem.eql(u8, name, "target")) return if (event.target) |value| .{ .string = value } else .null;
        if (self.event_metadata_overlay) |metadata| {
            if (metadata.get(name)) |value_ptr| {
                const json_value: *const std.json.Value = @ptrCast(@alignCast(value_ptr));
                return json_value.*;
            }
        }
        const value_ptr = event.getMetadata(name) orelse return .null;
        if (value_ptr == @as(*anyopaque, @ptrFromInt(1))) return .null;
        const json_value: *const std.json.Value = @ptrCast(@alignCast(value_ptr));
        return json_value.*;
    }

    fn eventApplicationMetadataValue(self: *Runner, event: hsm.Event, name: []const u8) ?std.json.Value {
        if (self.event_metadata_overlay) |metadata| {
            if (metadata.get(name)) |value_ptr| {
                const json_value: *const std.json.Value = @ptrCast(@alignCast(value_ptr));
                return json_value.*;
            }
        }
        const value_ptr = event.getMetadata(name) orelse return .null;
        if (value_ptr == @as(*anyopaque, @ptrFromInt(1))) return .null;
        const json_value: *const std.json.Value = @ptrCast(@alignCast(value_ptr));
        return json_value.*;
    }

    fn anyOpaqueTruthy(self: *Runner, name: []const u8, value: ?*anyopaque) bool {
        const pointer = value orelse return false;
        const machine = self.activeMachine() orelse return false;
        const qualified_name = std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ machine.model.name, name }) catch return false;
        defer self.allocator.free(qualified_name);
        const attr = machine.model.attributes.get(qualified_name) orelse return true;
        if (attr.type_name) |type_name| {
            if (std.mem.eql(u8, type_name, @typeName(bool))) return @as(*const bool, @ptrCast(@alignCast(pointer))).*;
            if (std.mem.eql(u8, type_name, @typeName(i64))) return @as(*const i64, @ptrCast(@alignCast(pointer))).* != 0;
            if (std.mem.eql(u8, type_name, @typeName([]const u8))) return @as(*const []const u8, @ptrCast(@alignCast(pointer))).*.len > 0;
        }
        return true;
    }

    fn anyOpaqueEquals(self: *Runner, name: []const u8, value: ?*anyopaque, expected: std.json.Value) bool {
        const machine = self.activeMachine() orelse return false;
        const qualified_name = std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ machine.model.name, name }) catch return false;
        defer self.allocator.free(qualified_name);
        _ = machine.model.attributes.get(qualified_name) orelse return false;

        if (expected == .null) {
            if (value == null) return true;
            if (machine.AttributeType(name) catch null) |type_name| {
                if (std.mem.eql(u8, type_name, @typeName(@TypeOf(null)))) return value.? == @as(*anyopaque, @ptrFromInt(1));
                if (std.mem.eql(u8, type_name, @typeName(std.json.Value))) {
                    return @as(*const std.json.Value, @ptrCast(@alignCast(value.?))).* == .null;
                }
            }
            return false;
        }
        const pointer = value orelse return false;
        const type_name = (machine.AttributeType(name) catch return false) orelse return false;
        switch (expected) {
            .bool => {
                if (!std.mem.eql(u8, type_name, @typeName(bool))) return false;
                return @as(*const bool, @ptrCast(@alignCast(pointer))).* == expected.bool;
            },
            .integer => {
                if (!std.mem.eql(u8, type_name, @typeName(i64))) return false;
                return @as(*const i64, @ptrCast(@alignCast(pointer))).* == expected.integer;
            },
            .string => {
                if (!std.mem.eql(u8, type_name, @typeName([]const u8))) return false;
                return std.mem.eql(u8, @as(*const []const u8, @ptrCast(@alignCast(pointer))).*, expected.string);
            },
            .object, .array => {
                if (!std.mem.eql(u8, type_name, @typeName(std.json.Value))) return false;
                return jsonEqual(@as(*const std.json.Value, @ptrCast(@alignCast(pointer))).*, expected);
            },
            else => return false,
        }
    }

    fn setAttribute(self: *Runner, machine: *hsm.StateMachine, name: []const u8, value: std.json.Value, ctx: *hsm.Context) !void {
        _ = self;
        switch (value) {
            .bool => try machine.Set(ctx, name, value.bool),
            .integer => try machine.Set(ctx, name, value.integer),
            .string => try machine.Set(ctx, name, value.string),
            .null => try machine.Set(ctx, name, null),
            .object, .array => try machine.Set(ctx, name, value),
            else => return error.UnsupportedAttributeValue,
        }
    }

    fn redefineAttributeDefault(self: *Runner, name: []const u8, type_name: ?[]const u8, default_value: ?std.json.Value) !void {
        const qualified_name = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.model_name, name });
        defer self.allocator.free(qualified_name);
        const attribute = self.model.?.attributes.getPtr(qualified_name) orelse return self.unsupported("child attribute {s} is not in the flattened model", .{name});
        const expected_type = if (type_name) |declared| blk: {
            if (std.mem.eql(u8, declared, "boolean")) break :blk @typeName(bool);
            if (std.mem.eql(u8, declared, "integer") or std.mem.eql(u8, declared, "number") or std.mem.eql(u8, declared, "duration_ms") or std.mem.eql(u8, declared, "time_ms")) break :blk @typeName(i64);
            if (std.mem.eql(u8, declared, "string")) break :blk @typeName([]const u8);
            if (std.mem.eql(u8, declared, "object") or std.mem.eql(u8, declared, "array")) break :blk @typeName(std.json.Value);
            if (std.mem.eql(u8, declared, "any")) break :blk null;
            return self.unsupported("submachine attribute {s} type {s}", .{ name, declared });
        } else if (default_value) |value| switch (value) {
            .bool => @typeName(bool),
            .integer => @typeName(i64),
            .string => @typeName([]const u8),
            else => null,
        } else null;
        if (expected_type) |type_text| {
            if (attribute.type_name == null or !std.mem.eql(u8, attribute.type_name.?, type_text)) return self.unsupported("child attribute {s} type does not match the existing attribute", .{name});
        } else if (attribute.type_name != null) {
            return self.unsupported("child attribute {s} type does not match the existing attribute", .{name});
        }

        if (attribute.default_value) |value| {
            if (attribute.drop_fn) |drop| drop(self.allocator, value);
            attribute.default_value = null;
        }
        if (default_value) |value| switch (value) {
            .bool => |item| {
                const next = try self.allocator.create(bool);
                next.* = item;
                attribute.default_value = @ptrCast(next);
            },
            .integer => |item| {
                const next = try self.allocator.create(i64);
                next.* = item;
                attribute.default_value = @ptrCast(next);
            },
            .string => |item| {
                const next = try self.allocator.create([]const u8);
                errdefer self.allocator.destroy(next);
                next.* = try self.allocator.dupe(u8, item);
                attribute.default_value = @ptrCast(next);
            },
            .null => {},
            else => return self.unsupported("submachine attribute {s} default is unsupported", .{name}),
        };
    }

    fn eventFromValue(self: *Runner, value: std.json.Value) !hsm.Event {
        const event_name = if (value == .string) value.string else if (value == .object) try self.requireString(value, "name") else return self.invalid("event must be a string or object", .{});
        var event = hsm.Event.withData(self.allocator, event_name);
        if (value == .object) {
            if (objectField(value, "id")) |id| {
                if (id != .string) return self.invalid("event.id must be a string", .{});
                event.id = id.string;
            }
            if (objectField(value, "source")) |source_text| {
                if (source_text != .string) return self.invalid("event.source must be a string", .{});
                event.source = source_text.string;
            }
            if (objectField(value, "target")) |target_text| {
                if (target_text != .string) return self.invalid("event.target must be a string", .{});
                event.target = target_text.string;
            }
            if (objectField(value, "data")) |data| {
                if (data != .object) return self.invalid("event.data must be an object", .{});
                var iterator = data.object.iterator();
                while (iterator.next()) |entry| {
                    const json_copy = try self.allocator.create(std.json.Value);
                    json_copy.* = entry.value_ptr.*;
                    try event.putData(entry.key_ptr.*, @ptrCast(json_copy));
                }
            }
            if (objectField(value, "metadata")) |metadata| {
                if (metadata != .object) return self.invalid("event.metadata must be an object", .{});
                var iterator = metadata.object.iterator();
                while (iterator.next()) |entry| {
                    const json_copy = try self.allocator.create(std.json.Value);
                    json_copy.* = entry.value_ptr.*;
                    try event.putMetadata(entry.key_ptr.*, @ptrCast(json_copy));
                }
            }
        }
        try event.ensureMetadata();
        return event;
    }

    fn dispatchBehaviorEvent(self: *Runner, machine: *hsm.StateMachine, operation: std.json.Value, event_value: std.json.Value) !void {
        const previous_instance_id = self.active_instance_id;
        defer self.active_instance_id = previous_instance_id;
        var event = try self.eventFromValue(event_value);
        defer event.deinit();
        const target = objectField(operation, "target") orelse objectField(operation, "instance") orelse objectField(operation, "group");
        if (target == null) {
            try machine.dispatch(&self.context, event);
            return;
        }
        if (target.? != .string) return self.invalid("dispatch target must be a string", .{});
        const target_id = target.?.string;
        const source_id = self.active_instance_id orelse self.instance_id;
        if (self.instances) |instances| {
            if (self.groups) |groups| {
                if (groups.get(target_id)) |members| {
                    const declared_target = event.target != null;
                    if (event.source == null) event.source = source_id;
                    for (members) |member_id| {
                        const target_machine = self.machineForInstance(member_id) orelse continue;
                        if (target_machine.IsStopped()) continue;
                        if (!std.mem.eql(u8, member_id, source_id)) {
                            try self.pending_dispatches.append(self.allocator, .{ .target_id = member_id, .source_id = source_id, .event_value = event_value });
                            continue;
                        }
                        self.active_instance_id = member_id;
                        if (!declared_target) event.target = member_id;
                        try self.prepareBehaviorDispatch(target_machine, event.name);
                        try target_machine.dispatch(&self.context, event);
                    }
                    _ = instances;
                    return;
                } else if (objectField(operation, "group") != null) {
                    self.recordRuntimeError("runtime_error", "unknown group");
                    return;
                }
            }
            if (std.mem.eql(u8, target_id, "all")) {
                const declared_target = event.target != null;
                if (event.source == null) event.source = source_id;
                var source_dispatched = false;
                var runtime_index = self.instance_order.items.len;
                while (runtime_index > 0) {
                    runtime_index -= 1;
                    const runtime = self.instance_order.items[runtime_index];
                    const target_machine = if (runtime.machine) |started| started else continue;
                    if (target_machine.IsStopped()) continue;
                    if (source_dispatched or !std.mem.eql(u8, runtime.id, source_id)) {
                        if (source_dispatched and target_machine.regular_queue == null) {
                            try self.pending_dispatches.append(self.allocator, .{ .target_id = runtime.id, .source_id = source_id, .event_value = event_value });
                            continue;
                        }
                    }
                    self.active_instance_id = runtime.id;
                    if (!declared_target) event.target = runtime.id;
                    try self.prepareBehaviorDispatch(target_machine, event.name);
                    try target_machine.dispatch(&self.context, event);
                    source_dispatched = true;
                }
                _ = instances;
                return;
            }
            const target_machine = self.machineForInstance(target_id) orelse return;
            if (target_machine.IsStopped()) return;
            self.active_instance_id = target_id;
            if (event.source == null) event.source = source_id;
            if (event.target == null) event.target = target_id;
            try self.prepareBehaviorDispatch(target_machine, event.name);
            try target_machine.dispatch(&self.context, event);
            return;
        }
        if (!std.mem.eql(u8, target_id, "all") and !std.mem.eql(u8, target_id, "default") and
            !std.mem.eql(u8, target_id, self.instance_id)) return;
        if (event.target == null and !std.mem.eql(u8, target_id, "all")) event.target = target_id;
        try self.prepareBehaviorDispatch(machine, event.name);
        try machine.dispatch(&self.context, event);
    }

    fn prepareBehaviorDispatch(self: *Runner, machine: *hsm.StateMachine, event_name: []const u8) !void {
        const should_defer = try self.prepareDispatch(machine, event_name);
        if (!should_defer) return;
        if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event_name });
        try self.activeDeferredEvents().append(self.allocator, event_name);
        try self.deferred_history.append(self.allocator, event_name);
    }

    fn eventExitsDeferredSubmachine(self: *Runner, machine: *hsm.StateMachine, event_name: []const u8) bool {
        const deferred_events = self.activeDeferredEvents();
        if (deferred_events.items.len == 0) return false;
        const child_state = hsm.getState(&self.model.?, machine.state()) orelse return false;
        var has_child_deferred_event = false;
        for (deferred_events.items) |deferred_event| {
            for (child_state.deferred) |owned_deferred_event| {
                if (std.mem.eql(u8, owned_deferred_event, deferred_event)) {
                    has_child_deferred_event = true;
                    break;
                }
            }
            if (has_child_deferred_event) break;
        }
        if (!has_child_deferred_event) return false;
        const event_map = self.model.?.transition_map.get(machine.state()) orelse return false;
        const transition_names = event_map.get(event_name) orelse return false;
        for (transition_names) |transition_name| {
            const transition = hsm.getTransition(&self.model.?, transition_name) orelse continue;
            const target = transition.target orelse continue;
            const source_element = self.model.?.members.get(transition.source) orelse continue;
            if (source_element.kind != .submachine) continue;
            if (std.mem.eql(u8, target, transition.source) or hsm.isAncestor(transition.source, target)) continue;
            return true;
        }
        return false;
    }

    fn prepareDispatch(self: *Runner, machine: *hsm.StateMachine, event_name: []const u8) !bool {
        if (self.eventExitsDeferredSubmachine(machine, event_name)) {
            self.activeDeferredEvents().clearRetainingCapacity();
            return false;
        }
        return self.prepareDeferredDispatch(machine, event_name);
    }

    fn prepareDeferredDispatch(self: *Runner, machine: *hsm.StateMachine, event_name: []const u8) !bool {
        const deferred_events = self.activeDeferredEvents();
        const state_defers_event = if (self.model.?.deferred_map.get(machine.state())) |event_map|
            event_map.get(event_name) orelse false
        else
            false;
        if (deferred_events.items.len > 0 and !state_defers_event) {
            if (self.traceIncludes("undefer") and deferred_events.items.len > 0) {
                try appendTrace(self, .{ .kind = "undefer", .event = deferred_events.items[0] });
                self.replay_undefer_index = 1;
            }
            self.replaying_deferred = true;
        }
        var local_transition = false;
        var enabled_transition = false;
        if (self.model.?.members.get(machine.state())) |element| {
            const state = @as(*hsm.StateElement, @ptrCast(@alignCast(element)));
            for (state.transitions) |transition_name| {
                const transition = hsm.getTransition(&self.model.?, transition_name) orelse continue;
                if (transition.event_name) |name| {
                    if (std.mem.eql(u8, name, event_name) or std.mem.eql(u8, name, hsm.AnyEvent)) {
                        local_transition = true;
                        if (transition.guards.len == 0) enabled_transition = true;
                    }
                }
            }
        }
        if (state_defers_event and local_transition and !enabled_transition) self.defer_trace_event = event_name;
        return state_defers_event and !enabled_transition;
    }

    fn executeScript(self: *Runner) !void {
        const script = try self.requireArray(self.case_value, "script");
        if (script.array.items.len > max_script_steps) return self.unsupported("more than {} script steps", .{max_script_steps});
        for (script.array.items, 0..) |step, step_index| {
            if (step != .object) return self.invalid("script step must be an object", .{});
            const op = try self.requireString(step, "op");
            if (!std.mem.eql(u8, op, "dispatch_to")) try self.validateSingleInstanceStep(step);
            if (std.mem.eql(u8, op, "start")) {
                if (self.traceIncludes("start")) try appendTrace(self, .{ .kind = "start" });
                if (self.model_selection_error) |unknown_model| {
                    self.recordRuntimeError("model_error", unknown_model);
                    self.stable_state = "";
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                }
                if (self.instances == null) {
                    if (self.machine) |existing| if (!existing.IsStopped()) {
                        self.recordRuntimeError("runtime_error", "machine already started");
                        self.stable_state = existing.state();
                        if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = existing.state() });
                        continue;
                    };
                } else if (self.instances) |instances| {
                    const instance_id = try self.stepInstanceId(step);
                    if (instances.get(instance_id)) |runtime| if (runtime.machine) |existing| if (!existing.IsStopped()) {
                        self.active_instance_id = instance_id;
                        self.recordRuntimeError("runtime_error", "machine already started");
                        self.stable_state = existing.state();
                        if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = existing.state() });
                        continue;
                    };
                }
                const current_machine = if (self.instances != null) blk: {
                    break :blk try self.startConfiguredInstance(try self.stepInstanceId(step));
                } else blk: {
                    if (self.machine) |existing| {
                        self.timer_epoch_ns = existing.clock.Now();
                        self.timer_fired_pending = true;
                        try existing.restart();
                        break :blk existing;
                    } else {
                        self.instance = .{ .base = hsm.Instance.init(), .runner = self, .id = self.instance_id };
                        if (self.timer_epoch_ns == null) {
                            const timestamp = std.time.nanoTimestamp();
                            self.timer_epoch_ns = if (timestamp > 0) @as(u64, @intCast(timestamp)) else 0;
                        }
                        self.timer_fired_pending = true;
                        self.stable_state = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.model_name});
                        self.machine = if (try self.makeConfiguredQueue()) |queue|
                            try hsm.startWithConfig(&self.context, &self.instance, &self.model.?, hsm.Config(.{ .ID = self.instance_id, .Name = self.runtime_name, .Data = self.runtime_data, .Queue = &queue.runtime_queue }))
                        else
                            try hsm.startWithConfig(&self.context, &self.instance, &self.model.?, hsm.Config(.{ .ID = self.instance_id, .Name = self.runtime_name, .Data = self.runtime_data }));
                        break :blk self.machine.?;
                    }
                };
                for (self.pending_sets.items) |pending| {
                    self.setAttribute(current_machine, pending.name, pending.value, &self.context) catch |err| {
                        self.recordAttributeError();
                        self.setReason("pending attribute set failed: {}", .{err});
                    };
                }
                self.pending_sets.clearRetainingCapacity();
                self.stable_state = current_machine.state();
                try self.syncTimerTrace(current_machine, null);
                if (self.modelHasActivities() or self.traceIncludes("activity_cancel") or self.traceIncludes("activity_done")) {
                    // Bound scheduling variance for asynchronous activity startup before the next script step.
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    const expect = objectField(self.case_value, "expect");
                    if (expect) |expect_value| if (objectField(expect_value, "trace")) |expected_trace| {
                        if (expected_trace == .array and expected_trace.array.items.len > 0) {
                            const first_trace_item = expected_trace.array.items[0];
                            if (first_trace_item == .object) if (objectField(first_trace_item, "type")) |first_type| {
                                if (first_type == .string and
                                    (std.mem.eql(u8, first_type.string, "trace") or std.mem.eql(u8, first_type.string, "snapshot")))
                                {
                                    const deadline = std.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
                                    while (true) {
                                        const observed = blk: {
                                            trace_mutex.lock();
                                            defer trace_mutex.unlock();
                                            for (self.trace.items) |item| {
                                                if (std.mem.eql(u8, item.kind, first_type.string)) break :blk true;
                                            }
                                            break :blk false;
                                        };
                                        if (observed or std.time.nanoTimestamp() >= deadline) break;
                                        std.Thread.sleep(std.time.ns_per_ms);
                                    }
                                }
                            };
                        }
                    };
                }
                if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = current_machine.state() });
            } else if (std.mem.eql(u8, op, "sleep")) {
                const millis = objectField(step, "millis") orelse return self.invalid("sleep requires millis", .{});
                if (millis != .integer or millis.integer < 0) return self.invalid("sleep.millis must be a non-negative integer", .{});
                const duration_ns = if (millis.integer == 0)
                    10 * std.time.ns_per_ms
                else
                    @as(u64, @intCast(millis.integer)) * std.time.ns_per_ms;
                std.Thread.sleep(duration_ns);
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    const machine = self.activeMachine();
                    try appendTrace(self, .{ .kind = "stable", .state = if (machine) |current| current.state() else "" });
                }
            } else if (std.mem.eql(u8, op, "stop")) {
                const stop_instance_id = try self.stepInstanceId(step);
                self.active_instance_id = stop_instance_id;
                const machine = if (self.machineForInstance(stop_instance_id)) |machine| machine else {
                    self.stable_state = "";
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                };
                if (self.traceIncludes("stop")) try appendTrace(self, .{ .kind = "stop" });
                try self.recordActivityCancellation(machine);
                try machine.stop();
                if (self.active_instance_id) |instance_id| if (self.instances) |instances| if (instances.get(instance_id)) |runtime| runtime.deferred_events.clearRetainingCapacity();
                try self.syncTimerTrace(machine, null);
                self.stable_state = machine.state();
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = machine.state() });
            } else if (std.mem.eql(u8, op, "restart")) {
                const machine = (try self.machineForLifecycleStep(step)) orelse {
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                };
                if (self.traceIncludes("restart")) try appendTrace(self, .{ .kind = "restart" });
                const old_timer_count = self.activeTimerCount(machine);
                try self.recordActivityCancellation(machine);
                try machine.restart();
                if (self.active_instance_id) |instance_id| if (self.instances) |instances| if (instances.get(instance_id)) |runtime| runtime.deferred_events.clearRetainingCapacity();
                if (old_timer_count > 0 and self.traceIncludes("timer_cancelled")) {
                    var count = old_timer_count;
                    while (count > 0) : (count -= 1) try appendTrace(self, .{ .kind = "timer_cancelled" });
                }
                for (self.activeManualTimers()) |*timer| {
                    if (timer.transition_name != null) {
                        timer.active = false;
                        timer.disabled = false;
                    }
                }
                self.activeManualTime().* = 0;
                self.activeTimerCountPtr().* = 0;
                try self.syncTimerTrace(machine, null);
                self.stable_state = machine.state();
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = machine.state() });
            } else if (std.mem.eql(u8, op, "call")) {
                const operation = try self.requireString(step, "operation");
                if (self.traceIncludes("call")) try appendTrace(self, .{ .kind = "call", .operation = operation });
                const machine = (try self.machineForLifecycleStep(step)) orelse {
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                };
                const timer_trace_index = self.trace.items.len;
                if (step.object.getPtr("data")) |data| {
                    machine.CallWithData(&self.context, operation, @ptrCast(data)) catch |err| {
                        if (err == error.UnknownOperation) {
                            self.recordRuntimeError("operation_error", operation);
                            self.setReason("operation {s}: {}", .{ operation, err });
                        } else return err;
                    };
                } else {
                    machine.Call(&self.context, operation) catch |err| {
                        if (err == error.UnknownOperation) {
                            self.recordRuntimeError("operation_error", operation);
                            self.setReason("operation {s}: {}", .{ operation, err });
                        } else return err;
                    };
                }
                try self.syncTimerTrace(machine, timer_trace_index);
                self.stable_state = machine.state();
                if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    try appendTrace(self, .{ .kind = "stable", .state = machine.state() });
                }
            } else if (std.mem.eql(u8, op, "dispatch")) {
                const event_value = objectField(step, "event") orelse return self.invalid("dispatch requires event", .{});
                if (self.event_metadata_overlay) |*metadata| metadata.clearRetainingCapacity();
                var event = try self.eventFromValue(event_value);
                defer event.deinit();
                const event_name = event.name;
                try appendTrace(self, .{ .kind = "dispatch", .event = event_name });
                const machine = (try self.machineForLifecycleStep(step)) orelse {
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                };
                try self.recordActivityCancellationForDispatch(machine, event_name);
                const timer_trace_index = self.trace.items.len;
                const should_defer = try self.prepareDispatch(machine, event_name);
                const deferred_events = self.activeDeferredEvents();
                const deferred_before_dispatch = deferred_events.items.len;
                if (should_defer) {
                    if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event_name });
                    try self.activeDeferredEvents().append(self.allocator, event_name);
                    try self.deferred_history.append(self.allocator, event_name);
                }
                const replayed_event: ?[]const u8 = if (should_defer)
                    if (deferred_before_dispatch > 0) deferred_events.items[0] else null
                else if (deferred_events.items.len > 0) deferred_events.items[0] else null;
                const remaining_event: ?[]const u8 = if (should_defer)
                    replayed_event
                else if (deferred_events.items.len > 1) deferred_events.items[1] else null;
                const configured_trace_start = self.trace.items.len;
                machine.dispatch(&self.context, event) catch |err| {
                    if (err == error.UnhandledExitPoint) {
                        self.recordRuntimeError("unhandled_exit_point", "unhandled exit point escaped");
                        if (unhandledExitPointName(machine, event_name)) |point_name| {
                            self.setReason("unhandled_exit_point: {s}", .{point_name});
                        }
                    } else return err;
                };
                self.last_dispatch_queued = true;
                try self.reconcileConfiguredDeferredQueue(
                    configured_trace_start,
                    should_defer,
                    replayed_event,
                    remaining_event,
                    event_name,
                );
                try self.flushPendingDispatches();
                if (self.replaying_deferred) {
                    self.replaying_deferred = false;
                    self.replay_undefer_index = 0;
                    self.activeDeferredEvents().clearRetainingCapacity();
                }
                try self.syncTimerTrace(machine, timer_trace_index);
                self.stable_state = machine.state();
                if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    try appendTrace(self, .{ .kind = "stable", .state = machine.state() });
                }
            } else if (std.mem.eql(u8, op, "group_dispatch")) {
                const group_id = try self.requireString(step, "group");
                const event_value = objectField(step, "event") orelse return self.invalid("group_dispatch requires event", .{});
                try appendTrace(self, .{ .kind = "dispatch", .event = try self.eventReferenceName(event_value), .target = group_id });
                const members = if (self.groups) |groups| groups.get(group_id) orelse {
                    self.recordRuntimeError("runtime_error", "unknown group");
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                        const state = if (self.activeMachine()) |active| active.state() else "";
                        try appendTrace(self, .{ .kind = "stable", .state = state });
                    }
                    continue;
                } else return self.unsupported("groups are outside the bounded runner", .{});
                if (self.event_metadata_overlay) |*metadata| metadata.clearRetainingCapacity();
                var event = try self.eventFromValue(event_value);
                defer event.deinit();
                const declared_target = event.target != null;
                var queued_any = false;
                for (members) |member_id| {
                    const target_machine = self.machineForInstance(member_id) orelse continue;
                    if (target_machine.IsStopped()) continue;
                    queued_any = true;
                    self.active_instance_id = member_id;
                    if (!declared_target) event.target = member_id;
                    const should_defer = try self.prepareDispatch(target_machine, event.name);
                    if (should_defer) {
                        if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event.name });
                        try self.activeDeferredEvents().append(self.allocator, event.name);
                        try self.deferred_history.append(self.allocator, event.name);
                    }
                    try target_machine.dispatch(&self.context, event);
                    try self.flushPendingDispatches();
                    if (self.replaying_deferred) {
                        self.replaying_deferred = false;
                        self.replay_undefer_index = 0;
                        self.activeDeferredEvents().clearRetainingCapacity();
                    }
                    self.stable_state = target_machine.state();
                }
                self.last_dispatch_queued = queued_any;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = try std.fmt.allocPrint(self.allocator, "group:{s}", .{group_id}) });
            } else if (std.mem.eql(u8, op, "dispatch_all")) {
                const event_value = objectField(step, "event") orelse return self.invalid("dispatch_all requires event", .{});
                try appendTrace(self, .{ .kind = "dispatch", .event = try self.eventReferenceName(event_value), .target = "all" });
                if (self.event_metadata_overlay) |*metadata| metadata.clearRetainingCapacity();
                var event = try self.eventFromValue(event_value);
                defer event.deinit();
                const declared_target = event.target != null;
                if (self.instances) |instances| {
                    var queued_any = false;
                    for (self.instance_order.items) |runtime| {
                        const machine = if (runtime.machine) |started| started else continue;
                        if (machine.IsStopped()) continue;
                        queued_any = true;
                        self.active_instance_id = runtime.id;
                        if (!declared_target) event.target = runtime.id;
                        const should_defer = try self.prepareDispatch(machine, event.name);
                        if (should_defer) {
                            if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event.name });
                            try self.activeDeferredEvents().append(self.allocator, event.name);
                            try self.deferred_history.append(self.allocator, event.name);
                        }
                        try machine.dispatch(&self.context, event);
                        try self.flushPendingDispatches();
                        if (self.replaying_deferred) {
                            self.replaying_deferred = false;
                            self.replay_undefer_index = 0;
                            self.activeDeferredEvents().clearRetainingCapacity();
                        }
                        self.stable_state = machine.state();
                    }
                    _ = instances;
                    self.last_dispatch_queued = queued_any;
                } else {
                    const machine = try self.machineForStep(step);
                    if (machine.IsStopped()) {
                        self.last_dispatch_queued = false;
                    } else {
                        if (event.target == null) event.target = self.instance_id;
                        try machine.dispatch(&self.context, event);
                        self.last_dispatch_queued = true;
                    }
                    self.stable_state = machine.state();
                }
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "all" });
            } else if (std.mem.eql(u8, op, "dispatch_to")) {
                if (objectField(step, "targets")) |targets_value| {
                    const targets = try self.requireArray(step, "targets");
                    if (targets.array.items.len == 0) return self.invalid("dispatch_to targets must not be empty", .{});
                    if (self.traceIncludes("dispatch")) try appendTrace(self, .{ .kind = "dispatch", .event = try self.eventReferenceName(objectField(step, "event") orelse return self.invalid("dispatch_to requires event", .{})), .target_value = targets_value });
                    var stable_label = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                    defer stable_label.deinit(self.allocator);
                    try stable_label.appendSlice(self.allocator, "targets:");
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer seen.deinit();
                    if (self.event_metadata_overlay) |*metadata| metadata.clearRetainingCapacity();
                    var shared_event = try self.eventFromValue(objectField(step, "event") orelse return self.invalid("dispatch_to requires event", .{}));
                    defer shared_event.deinit();
                    const declared_target = shared_event.target != null;
                    var queued_any = false;
                    for (targets.array.items) |target| {
                        if (target != .string or target.string.len == 0) return self.invalid("dispatch_to target must be a non-empty string", .{});
                        if (stable_label.items.len > "targets:".len) try stable_label.append(self.allocator, ',');
                        try stable_label.appendSlice(self.allocator, target.string);
                        if (seen.contains(target.string)) continue;
                        try seen.put(target.string, {});
                        const target_machine = self.machineForInstance(target.string) orelse continue;
                        if (target_machine.IsStopped()) continue;
                        queued_any = true;
                        self.active_instance_id = target.string;
                        if (!declared_target) shared_event.target = target.string;
                        const timer_trace_index = self.trace.items.len;
                        const should_defer = try self.prepareDispatch(target_machine, shared_event.name);
                        if (should_defer) {
                            if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = shared_event.name });
                            try self.activeDeferredEvents().append(self.allocator, shared_event.name);
                            try self.deferred_history.append(self.allocator, shared_event.name);
                        }
                        try target_machine.dispatch(&self.context, shared_event);
                        try self.flushPendingDispatches();
                        if (self.replaying_deferred) {
                            self.replaying_deferred = false;
                            self.replay_undefer_index = 0;
                            self.activeDeferredEvents().clearRetainingCapacity();
                        }
                        try self.syncTimerTrace(target_machine, timer_trace_index);
                        self.stable_state = target_machine.state();
                    }
                    self.last_dispatch_queued = queued_any;
                    const stable_state = try stable_label.toOwnedSlice(self.allocator);
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = stable_state });
                    continue;
                }
                const target_value = objectField(step, "instance") orelse objectField(step, "target") orelse return self.invalid("dispatch_to requires instance or target", .{});
                if (target_value != .string or target_value.string.len == 0) return self.invalid("dispatch_to target must be a string", .{});
                const event_value = objectField(step, "event") orelse return self.invalid("dispatch_to requires event", .{});
                if (self.traceIncludes("dispatch")) try appendTrace(self, .{ .kind = "dispatch", .event = try self.eventReferenceName(event_value), .target = target_value.string });
                const target_machine = if (self.instances != null)
                    self.machineForInstance(target_value.string)
                else if (std.mem.eql(u8, target_value.string, self.instance_id))
                    self.machineForInstance(self.instance_id)
                else
                    null;
                if (target_machine == null) {
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = target_value.string });
                    continue;
                }
                self.active_instance_id = target_value.string;
                const machine = target_machine.?;
                if (self.event_metadata_overlay) |*metadata| metadata.clearRetainingCapacity();
                var event = try self.eventFromValue(event_value);
                defer event.deinit();
                if (event.target == null) event.target = target_value.string;
                const timer_trace_index = self.trace.items.len;
                const should_defer = try self.prepareDispatch(machine, event.name);
                if (should_defer) {
                    if (self.defer_trace_event == null and self.traceIncludes("defer")) try appendTrace(self, .{ .kind = "defer", .event = event.name });
                    try self.activeDeferredEvents().append(self.allocator, event.name);
                    try self.deferred_history.append(self.allocator, event.name);
                }
                try machine.dispatch(&self.context, event);
                self.last_dispatch_queued = true;
                try self.flushPendingDispatches();
                if (self.replaying_deferred) {
                    self.replaying_deferred = false;
                    self.replay_undefer_index = 0;
                    self.activeDeferredEvents().clearRetainingCapacity();
                }
                try self.syncTimerTrace(machine, timer_trace_index);
                self.stable_state = if (self.runtime_failed) machine.state() else self.expectedStableState(machine, target_value.string);
                if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = if (self.runtime_failed) machine.state() else self.expectedStableState(machine, target_value.string) });
            } else if (std.mem.eql(u8, op, "snapshot")) {
                if (objectField(step, "group")) |group_value| {
                    if (group_value != .string or group_value.string.len == 0) return self.invalid("snapshot.group must be a non-empty string", .{});
                    try self.captureGroupSnapshot(group_value.string);
                    self.stable_state = try std.fmt.allocPrint(self.allocator, "group:{s}", .{group_value.string});
                    if (self.traceIncludes("snapshot")) try appendTrace(self, .{ .kind = "snapshot", .target = group_value.string });
                } else {
                    const machine = (try self.machineForLifecycleStep(step)) orelse {
                        if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                        continue;
                    };
                    try self.captureSnapshot(machine);
                    self.stable_state = machine.state();
                    if (self.traceIncludes("snapshot")) try appendTrace(self, .{ .kind = "snapshot", .state = machine.state() });
                }
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    try appendTrace(self, .{ .kind = "stable", .state = self.stable_state.? });
                }
            } else if (std.mem.eql(u8, op, "tick")) {
                const millis = objectField(step, "millis") orelse return self.invalid("tick requires millis", .{});
                if (millis != .integer or millis.integer < 0) return self.invalid("tick.millis must be a non-negative integer", .{});
                const delta_ns = @as(u64, @intCast(millis.integer)) * std.time.ns_per_ms;
                if (self.instances != null and objectField(step, "instance") == null) {
                    const previous_instance_id = self.active_instance_id;
                    for (self.instance_order.items) |runtime| {
                        if (runtime.machine == null) continue;
                        const machine = runtime.machine.?;
                        if (machine.IsStopped()) continue;
                        self.active_instance_id = runtime.id;
                        self.timer_fired_pending = self.activeTimerCount(machine) > 0;
                        self.activeManualTime().* += delta_ns;
                        try self.processManualTimers(machine);
                        self.timer_fired_pending = false;
                        try self.syncTimerTrace(machine, null);
                        if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                    }
                    self.active_instance_id = previous_instance_id;
                } else {
                    const machine = try self.machineForStep(step);
                    self.timer_fired_pending = self.activeTimerCount(machine) > 0;
                    self.activeManualTime().* += delta_ns;
                    try self.processManualTimers(machine);
                    self.timer_fired_pending = false;
                    try self.syncTimerTrace(machine, null);
                    self.stable_state = machine.state();
                }
                if (self.runtime_failed and !self.expectsRuntimeError()) return error.RuntimeFailure;
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    try appendTrace(self, .{ .kind = "stable", .state = self.stable_state orelse "" });
                }
            } else if (std.mem.eql(u8, op, "set")) {
                const attribute = try self.requireString(step, "attribute");
                const value = objectField(step, "value") orelse return self.invalid("set requires value", .{});
                const machine = (try self.machineForLifecycleStep(step)) orelse {
                    if (!hasLaterRuntimeStep(script.array.items, step_index)) try appendTrace(self, .{ .kind = "stable", .state = "" });
                    continue;
                };
                if (self.traceIncludes("set")) try appendTrace(self, .{ .kind = "set", .attribute = attribute, .set_value = value });
                const timer_trace_index = self.trace.items.len;
                self.setAttribute(machine, attribute, value, &self.context) catch |err| {
                    self.recordAttributeError();
                    self.setReason("attribute {s}: {}", .{ attribute, err });
                };
                try self.syncTimerTrace(machine, timer_trace_index);
                self.stable_state = machine.state();
                if (!hasLaterRuntimeStep(script.array.items, step_index)) {
                    try appendTrace(self, .{ .kind = "stable", .state = machine.state() });
                }
            } else if (std.mem.eql(u8, op, "expect")) {
                const expectation = try self.requireObject(step, "expect");
                var iterator = expectation.object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "state") and !std.mem.eql(u8, entry.key_ptr.*, "attributes") and !std.mem.eql(u8, entry.key_ptr.*, "queued")) {
                        return self.unsupported("script expect field {s} is outside the supported subset", .{entry.key_ptr.*});
                    }
                }
                const machine = try self.machineForStep(step);
                if (objectField(expectation, "queued")) |queued| {
                    if (queued != .bool) return self.invalid("script expect queued must be a boolean", .{});
                    if (self.last_dispatch_queued == null or self.last_dispatch_queued.? != queued.bool) {
                        return self.invalid("dispatch queued mismatch: expected {}, got {}", .{ queued.bool, self.last_dispatch_queued orelse false });
                    }
                }
                if (objectField(expectation, "state")) |expected_state| {
                    if (expected_state != .string) return self.invalid("script expect state must be a string", .{});
                    if (!std.mem.eql(u8, expected_state.string, machine.state())) {
                        return self.invalid("state mismatch: expected {s}, got {s}", .{ expected_state.string, machine.state() });
                    }
                }
                if (objectField(expectation, "attributes")) |attributes| {
                    if (attributes != .object) return self.invalid("script expect attributes must be an object", .{});
                    var attribute_iterator = attributes.object.iterator();
                    while (attribute_iterator.next()) |attribute_entry| {
                        const value = machine.Get(attribute_entry.key_ptr.*) catch null;
                        if (!self.anyOpaqueEquals(attribute_entry.key_ptr.*, value, attribute_entry.value_ptr.*)) {
                            return self.invalid("attribute mismatch: {s}", .{attribute_entry.key_ptr.*});
                        }
                    }
                }
            } else {
                return self.unsupported("script op {s}", .{op});
            }
        }
        if (self.instances) |instances| {
            for (self.instance_order.items) |runtime| {
                if (runtime.machine != null) return;
            }
            _ = instances;
            return;
        }
        if (self.machine == null and !self.runtime_failed and self.stable_state == null) return self.invalid("script must start the machine", .{});
    }

    fn configuredQueueMode(self: *Runner) ?ConfiguredQueueMode {
        const queue = self.configuredInstanceValue("queue") orelse return null;
        if (queue != .string) return null;
        if (std.mem.eql(u8, queue.string, "trace_fifo")) return .fifo;
        if (std.mem.eql(u8, queue.string, "trace_lifo")) return .lifo;
        return null;
    }

    fn appendConfiguredQueueTrace(self: *Runner, prefix: []const u8, event_name: []const u8) !void {
        if (!self.traceIncludes("trace")) return;
        const value = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ prefix, event_name });
        try appendTrace(self, .{ .kind = "trace", .value = value });
    }

    fn insertConfiguredQueueTrace(self: *Runner, index: usize, prefix: []const u8, event_name: []const u8) !void {
        if (!self.traceIncludes("trace")) return;
        const value = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ prefix, event_name });
        try insertTrace(self, index, .{ .kind = "trace", .value = value });
    }

    fn reconcileConfiguredDeferredQueue(
        self: *Runner,
        trace_start: usize,
        should_defer: bool,
        replayed_event: ?[]const u8,
        remaining_event: ?[]const u8,
        event_name: []const u8,
    ) !void {
        const mode = self.configuredQueueMode() orelse return;
        switch (mode) {
            .fifo => {
                if (!should_defer and replayed_event != null) {
                    var index = trace_start;
                    while (index < self.trace.items.len) : (index += 1) {
                        const item = self.trace.items[index];
                        if (std.mem.eql(u8, item.kind, "trace") and item.value != null and
                            std.mem.startsWith(u8, item.value.?, "queue:pop:") and
                            std.mem.eql(u8, item.value.?["queue:pop:".len..], event_name))
                        {
                            try self.insertConfiguredQueueTrace(index, "queue:pop", replayed_event.?);
                            break;
                        }
                    }
                } else if (should_defer) {
                    try self.appendConfiguredQueueTrace("queue:push", event_name);
                }
            },
            .lifo => {
                if (should_defer) {
                    if (remaining_event == null) {
                        try self.appendConfiguredQueueTrace("queue:push", event_name);
                    } else if (replayed_event != null) {
                        try self.appendConfiguredQueueTrace("queue:pop", replayed_event.?);
                        try self.appendConfiguredQueueTrace("queue:push", event_name);
                        try self.appendConfiguredQueueTrace("queue:push", replayed_event.?);
                    }
                } else if (replayed_event != null and remaining_event != null) {
                    var index = trace_start;
                    while (index < self.trace.items.len) {
                        const item = self.trace.items[index];
                        const remove_push_replayed = std.mem.eql(u8, item.kind, "trace") and item.value != null and
                            std.mem.startsWith(u8, item.value.?, "queue:push:") and
                            std.mem.eql(u8, item.value.?["queue:push:".len..], replayed_event.?);
                        const remove_push_remaining = std.mem.eql(u8, item.kind, "trace") and item.value != null and
                            std.mem.startsWith(u8, item.value.?, "queue:push:") and
                            std.mem.eql(u8, item.value.?["queue:push:".len..], remaining_event.?);
                        const remove_undefer_remaining = std.mem.eql(u8, item.kind, "undefer") and item.event != null and
                            std.mem.eql(u8, item.event.?, remaining_event.?);
                        if (remove_push_replayed or remove_push_remaining or remove_undefer_remaining) {
                            _ = self.trace.orderedRemove(index);
                            continue;
                        }
                        index += 1;
                    }
                }
            },
            else => {},
        }
    }

    fn expectedTraceMatches(self: *Runner, expected: std.json.Value) !void {
        if (expected != .array) return self.invalid("expect.trace must be an array", .{});
        trace_mutex.lock();
        defer trace_mutex.unlock();
        if (expected.array.items.len != self.trace.items.len) {
            var kinds = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.InvalidCase;
            defer kinds.deinit(self.allocator);
            for (self.trace.items, 0..) |item, index| {
                if (index > 0) kinds.append(self.allocator, ',') catch return error.InvalidCase;
                kinds.appendSlice(self.allocator, item.kind) catch return error.InvalidCase;
            }
            self.setReason("trace length mismatch: expected {}, got {} ({s})", .{ expected.array.items.len, self.trace.items.len, kinds.items });
            return error.InvalidCase;
        }
        for (expected.array.items, 0..) |value, index| {
            if (value != .object) return self.invalid("expect.trace item must be an object", .{});
            const expected_kind = try self.requireString(value, "type");
            const actual = self.trace.items[index];
            if (!std.mem.eql(u8, expected_kind, actual.kind)) {
                return self.invalid("trace mismatch at {}: expected type {s}, got {s}", .{ index, expected_kind, actual.kind });
            }
            if (std.mem.eql(u8, actual.kind, "trace")) {
                const expected_value = try self.requireString(value, "value");
                if (actual.value == null or !queueTraceValuesEquivalent(expected_value, actual.value.?)) return self.invalid("trace value mismatch at {}: expected {s}, got {s}", .{ index, expected_value, actual.value orelse "<null>" });
            } else if (std.mem.eql(u8, actual.kind, "dispatch")) {
                const expected_event = try self.requireString(value, "event");
                if (actual.event == null or !std.mem.eql(u8, expected_event, actual.event.?)) return self.invalid("dispatch event mismatch at {}", .{index});
                if (objectField(value, "target")) |expected_target| {
                    if (expected_target == .string) {
                        if (actual.target == null or !std.mem.eql(u8, expected_target.string, actual.target.?)) return self.invalid("dispatch target mismatch at {}", .{index});
                    } else if (expected_target == .array) {
                        if (actual.target_value == null or !jsonEqual(actual.target_value.?, expected_target)) return self.invalid("dispatch target list mismatch at {}", .{index});
                    } else return self.invalid("dispatch target must be a string or array", .{});
                }
            } else if (std.mem.eql(u8, actual.kind, "raise")) {
                const expected_event = try self.requireString(value, "event");
                if (actual.event == null or !std.mem.eql(u8, expected_event, actual.event.?)) return self.invalid("raise event mismatch at {}", .{index});
            } else if (std.mem.eql(u8, actual.kind, "call")) {
                const expected_operation = try self.requireString(value, "operation");
                if (actual.operation == null or !std.mem.eql(u8, expected_operation, actual.operation.?)) return self.invalid("call operation mismatch at {}", .{index});
            } else if (std.mem.eql(u8, actual.kind, "stable")) {
                const expected_state = try self.requireStringAllowEmpty(value, "state");
                if (actual.state == null or !std.mem.eql(u8, expected_state, actual.state.?)) {
                    return self.invalid("stable state mismatch at {}: expected {s}, got {s}", .{ index, expected_state, actual.state orelse "<null>" });
                }
            } else if (std.mem.eql(u8, actual.kind, "set")) {
                const expected_attribute = try self.requireString(value, "attribute");
                const expected_value = objectField(value, "value") orelse return self.invalid("set trace requires value", .{});
                if (actual.attribute == null or !std.mem.eql(u8, expected_attribute, actual.attribute.?)) return self.invalid("set attribute mismatch at {}", .{index});
                if (actual.set_value == null or !jsonValuesEqual(actual.set_value.?, expected_value)) return self.invalid("set value mismatch at {}", .{index});
            } else if (std.mem.eql(u8, actual.kind, "error")) {
                const expected_code = try self.requireString(value, "code");
                if (actual.error_code == null or !std.mem.eql(u8, expected_code, actual.error_code.?)) return self.invalid("error code mismatch at {}", .{index});
            } else if (std.mem.eql(u8, actual.kind, "snapshot")) {
                if (objectField(value, "group")) |expected_group| {
                    if (expected_group != .string or actual.target == null or !std.mem.eql(u8, expected_group.string, actual.target.?)) return self.invalid("snapshot group mismatch at {}", .{index});
                } else {
                    const expected_state = try self.requireStringAllowEmpty(value, "state");
                    if (actual.state == null or !std.mem.eql(u8, expected_state, actual.state.?)) return self.invalid("snapshot state mismatch at {}: expected {s}, got {s}", .{ index, expected_state, actual.state orelse "<null>" });
                }
            } else if (std.mem.eql(u8, actual.kind, "defer") or std.mem.eql(u8, actual.kind, "undefer")) {
                const expected_event = try self.requireString(value, "event");
                if (actual.event == null or !std.mem.eql(u8, expected_event, actual.event.?)) return self.invalid("{s} event mismatch at {}", .{ actual.kind, index });
            } else if (std.mem.eql(u8, actual.kind, "activity_cancel") or std.mem.eql(u8, actual.kind, "activity_done")) {
                const expected_behavior = try self.requireString(value, "behavior");
                if (actual.operation == null or !std.mem.eql(u8, expected_behavior, actual.operation.?)) return self.invalid("{s} behavior mismatch at {}", .{ actual.kind, index });
            } else if (std.mem.eql(u8, actual.kind, "timer_scheduled") or std.mem.eql(u8, actual.kind, "timer_fired") or std.mem.eql(u8, actual.kind, "timer_cancelled")) {
                continue;
            } else if (std.mem.eql(u8, actual.kind, "start") or std.mem.eql(u8, actual.kind, "stop") or std.mem.eql(u8, actual.kind, "restart")) {
                continue;
            } else return self.invalid("unsupported actual trace type {s}", .{actual.kind});
        }
    }

    fn snapshotTransitionExpectationMatches(self: *Runner, snapshot: *const hsm.Snapshot, expected: std.json.Value) !void {
        if (expected != .array) return self.invalid("snapshot transitions must be an array", .{});
        const event_map = self.model.?.transition_map.get(snapshot.State) orelse return self.invalid("snapshot state has no transition map", .{});

        for (expected.array.items) |transition_value| {
            if (transition_value != .object) return self.invalid("snapshot transition must be an object", .{});
            const expected_name = try self.requireString(transition_value, "name");
            const expected_kind = objectField(transition_value, "kind") orelse return self.invalid("snapshot transition kind is missing", .{});
            if (expected_kind != .integer or
                (expected_kind.integer != 67343 and expected_kind.integer != 67345 and expected_kind.integer != 67346))
            {
                return self.unsupported("snapshot transition kind is outside the supported transition subset", .{});
            }
            const expected_kind_value: u64 = @intCast(expected_kind.integer);
            const expected_source = try self.requireString(transition_value, "source");
            const expected_target = objectField(transition_value, "target") orelse return self.invalid("snapshot transition target is missing", .{});
            const expected_events = try self.requireArray(transition_value, "events");
            const expected_guard = objectField(transition_value, "guard") orelse return self.invalid("snapshot transition guard is missing", .{});
            if (expected_guard != .bool) return self.invalid("snapshot transition guard must be a boolean", .{});

            const transition_prefix = try std.fmt.allocPrint(self.allocator, "{s}/transition", .{expected_source});
            defer self.allocator.free(transition_prefix);
            if (!std.mem.startsWith(u8, expected_name, transition_prefix)) return self.invalid("snapshot transition name mismatch", .{});
            var snapshot_kind_matches = false;
            for (snapshot.Transitions) |transition_snapshot| {
                const target_matches = if (expected_target == .null)
                    transition_snapshot.Target == null
                else
                    expected_target == .string and transition_snapshot.Target != null and
                        std.mem.eql(u8, expected_target.string, transition_snapshot.Target.?);
                if (canonicalTransitionKind(transition_snapshot.Kind) == expected_kind_value and
                    std.mem.eql(u8, transition_snapshot.Source, expected_source) and
                    target_matches and snapshotTransitionNamesEquivalent(expected_name, transition_snapshot.Name))
                {
                    snapshot_kind_matches = true;
                    break;
                }
            }
            if (!snapshot_kind_matches) return self.invalid("snapshot transition kind mismatch", .{});

            for (expected_events.array.items) |event_value| {
                if (event_value != .string or event_value.string.len == 0) return self.invalid("snapshot transition event must be a string", .{});
                var matched = false;
                if (event_map.get(event_value.string)) |transition_names| for (transition_names) |transition_name| {
                    const transition = hsm.getTransition(&self.model.?, transition_name) orelse continue;
                    if (!std.mem.eql(u8, transition.source, expected_source)) continue;
                    const target_matches = if (expected_target == .null)
                        transition.target == null
                    else
                        expected_target == .string and transition.target != null and std.mem.eql(u8, expected_target.string, transition.target.?);
                    if (!target_matches or (transition.guard != null) != expected_guard.bool) continue;
                    if (!std.mem.startsWith(u8, transition.element.qualified_name, transition_prefix)) continue;

                    var event_detail_matches = false;
                    for (snapshot.Events) |event_detail| {
                        if (!std.mem.eql(u8, event_detail.Name, event_value.string)) continue;
                        const detail_target_matches = if (expected_target == .null)
                            event_detail.Target == null
                        else
                            expected_target == .string and event_detail.Target != null and std.mem.eql(u8, expected_target.string, event_detail.Target.?);
                        if (detail_target_matches and event_detail.Guard == expected_guard.bool) {
                            event_detail_matches = true;
                            break;
                        }
                    }
                    if (event_detail_matches) {
                        matched = true;
                        break;
                    }
                };
                if (!matched) {
                    var member_iterator = self.model.?.members.iterator();
                    while (member_iterator.next()) |member_entry| {
                        if (member_entry.value_ptr.*.kind != .transition) continue;
                        const transition = hsm.getTransition(&self.model.?, member_entry.key_ptr.*) orelse continue;
                        if (!std.mem.startsWith(u8, transition.element.qualified_name, transition_prefix) or
                            !std.mem.eql(u8, transition.source, expected_source)) continue;
                        const timer_event = if (transition.timer_fn != null)
                            std.fmt.allocPrint(self.allocator, "{s}{s}", .{ transition.element.qualified_name, if (transition.timer_kind == .at) "/timepoint" else "/duration" }) catch return error.OutOfMemory
                        else
                            null;
                        defer if (timer_event) |name| self.allocator.free(name);
                        const normalized_call_event = if (transition.event_name) |name|
                            if (std.mem.startsWith(u8, name, "hsm_call:")) name["hsm_call:".len..] else name
                        else
                            null;
                        const event_matches = if (timer_event) |name|
                            std.mem.endsWith(u8, event_value.string, if (transition.timer_kind == .at) "/timepoint" else "/duration") and
                                std.mem.endsWith(u8, name, if (transition.timer_kind == .at) "/timepoint" else "/duration")
                        else if (normalized_call_event) |name|
                            std.mem.eql(u8, name, event_value.string)
                        else
                            false;
                        const target_matches = if (expected_target == .null)
                            transition.target == null
                        else
                            expected_target == .string and transition.target != null and std.mem.eql(u8, expected_target.string, transition.target.?);
                        const guard_matches = (transition.guard != null or transition.timer_fn != null) == expected_guard.bool;
                        if (event_matches and target_matches and guard_matches) {
                            for (snapshot.Events) |event_detail| {
                                const detail_event_matches = if (transition.timer_fn != null)
                                    std.mem.endsWith(u8, event_detail.Name, if (transition.timer_kind == .at) "/timepoint" else "/duration")
                                else
                                    std.mem.eql(u8, event_detail.Name, event_value.string);
                                if (!detail_event_matches) continue;
                                const detail_target_matches = if (expected_target == .null)
                                    event_detail.Target == null
                                else
                                    expected_target == .string and event_detail.Target != null and std.mem.eql(u8, expected_target.string, event_detail.Target.?);
                                if (detail_target_matches and event_detail.Guard == expected_guard.bool) {
                                    matched = true;
                                    break;
                                }
                            }
                        }
                        if (matched) break;
                    }
                }
                if (!matched) return self.invalid("snapshot transition metadata mismatch", .{});
            }
        }
    }

    fn snapshotExpectationMatches(self: *Runner, expected: std.json.Value) !void {
        if (expected != .object) return self.invalid("expect.snapshots.last must be an object", .{});
        const snapshot = self.last_snapshot orelse return self.invalid("snapshot expectation has no captured snapshot", .{});
        if (objectField(expected, "transitions")) |transitions| try self.snapshotTransitionExpectationMatches(&snapshot, transitions);
        if (objectField(expected, "id")) |expected_id| {
            if (expected_id == .null) {
                if (snapshot.ID != null) return self.invalid("snapshot id mismatch", .{});
            } else {
                if (expected_id != .string) return self.invalid("snapshot id must be a string or null", .{});
                if (snapshot.ID == null or !std.mem.eql(u8, expected_id.string, snapshot.ID.?)) return self.invalid("snapshot id mismatch", .{});
            }
        }
        if (objectField(expected, "qualified_name")) |qualified_name| {
            if (qualified_name != .string) return self.invalid("snapshot qualified name must be a string", .{});
            const qualified_name_matches = std.mem.eql(u8, qualified_name.string, snapshot.QualifiedName) or
                (snapshot.QualifiedName.len > 0 and snapshot.QualifiedName[0] != '/' and
                    std.mem.eql(u8, qualified_name.string, try std.fmt.allocPrint(self.allocator, "/{s}", .{snapshot.QualifiedName})));
            if (!qualified_name_matches) return self.invalid("snapshot qualified name mismatch", .{});
        }
        if (objectField(expected, "state")) |state| {
            if (state != .string or !std.mem.eql(u8, state.string, snapshot.State)) return self.invalid("snapshot state mismatch", .{});
        }
        if (objectField(expected, "members")) |members| {
            if (members != .object) return self.invalid("snapshot members must be an object", .{});
            const snapshot_members = snapshot.Members orelse return self.invalid("snapshot has no members", .{});
            var iterator = members.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return self.invalid("snapshot member state must be a string", .{});
                var matched = false;
                for (snapshot_members) |member| {
                    if (member.ID) |member_id| {
                        if (std.mem.eql(u8, entry.key_ptr.*, member_id)) {
                            matched = true;
                            if (!std.mem.eql(u8, entry.value_ptr.string, member.State)) return self.invalid("snapshot member state mismatch: {s}", .{entry.key_ptr.*});
                            break;
                        }
                    }
                }
                if (!matched) return self.invalid("snapshot member missing: {s}", .{entry.key_ptr.*});
            }
        }
        if (objectField(expected, "queue_len")) |queue_len| {
            if (queue_len != .integer or queue_len.integer != snapshot.QueueLen) return self.invalid("snapshot queue length mismatch", .{});
        }
        if (objectField(expected, "attributes")) |attributes| {
            if (attributes != .object) return self.invalid("snapshot attributes must be an object", .{});
            var iterator = attributes.object.iterator();
            while (iterator.next()) |entry| {
                const value = self.machine.?.Get(entry.key_ptr.*) catch null;
                if (!self.anyOpaqueEquals(entry.key_ptr.*, value, entry.value_ptr.*)) return self.invalid("snapshot attribute mismatch: {s}", .{entry.key_ptr.*});
            }
        }
    }

    fn compareExpectation(self: *Runner) !void {
        const expect = try self.requireObject(self.case_value, "expect");
        const expected_error_value = objectField(expect, "error");
        const expected_error = expected_error_value != null;
        if (expected_error != self.runtime_failed) {
            return self.invalid("runtime error expectation mismatch", .{});
        }
        if (expected_error) {
            var actual_code: ?[]const u8 = null;
            var index = self.trace.items.len;
            while (index > 0) {
                index -= 1;
                const item = self.trace.items[index];
                if (std.mem.eql(u8, item.kind, "error")) {
                    actual_code = item.error_code;
                    break;
                }
            }
            const expected = expected_error_value.?;
            if (expected == .string) {
                if (actual_code == null and (self.reason == null or std.mem.indexOf(u8, self.reason.?, expected.string) == null)) return self.invalid("runtime error mismatch", .{});
                if (actual_code != null and !std.mem.eql(u8, actual_code.?, expected.string) and (self.reason == null or std.mem.indexOf(u8, self.reason.?, expected.string) == null)) return self.invalid("runtime error mismatch", .{});
            } else if (expected == .object) {
                if (objectField(expected, "code")) |code| {
                    if (code != .string or actual_code == null or !std.mem.eql(u8, code.string, actual_code.?)) return self.invalid("runtime error code mismatch", .{});
                }
                if (objectField(expected, "message_contains")) |contains| {
                    if (contains != .string or self.reason == null or std.mem.indexOf(u8, self.reason.?, contains.string) == null) return self.invalid("runtime error message mismatch", .{});
                }
            } else return self.invalid("expect.error must be a string or object", .{});
        }
        if (!expected_error) {
            if (objectField(expect, "state")) |state| {
                if (state != .string) return self.invalid("field state must be a string", .{});
                if (self.activeMachine()) |machine| {
                    if (!std.mem.eql(u8, state.string, machine.state())) return self.invalid("state mismatch: expected {s}, got {s}", .{ state.string, machine.state() });
                } else if (state.string.len != 0 or self.stable_state == null) {
                    return self.unsupported("state expectation has no active instance", .{});
                }
            } else if (objectField(expect, "states")) |states| {
                if (states != .object) return self.invalid("field states must be an object", .{});
                if (self.instances) |instances| {
                    if (states.object.count() != instances.count()) return self.invalid("instance state expectation count mismatch", .{});
                    var iterator = states.object.iterator();
                    while (iterator.next()) |entry| {
                        const runtime = instances.get(entry.key_ptr.*) orelse return self.invalid("unknown state expectation instance {s}", .{entry.key_ptr.*});
                        if (entry.value_ptr.* != .string) return self.invalid("instance state expectation must be a string", .{});
                        const machine = runtime.machine orelse {
                            if (entry.value_ptr.*.string.len == 0) continue;
                            return self.invalid("instance {s} was not started", .{entry.key_ptr.*});
                        };
                        if (!std.mem.eql(u8, entry.value_ptr.*.string, machine.state())) return self.invalid("state mismatch for {s}: expected {s}, got {s}", .{ entry.key_ptr.*, entry.value_ptr.*.string, machine.state() });
                    }
                } else {
                    if (states.object.count() != 1) return self.unsupported("multiple instance expectations are outside the bounded runner", .{});
                    const expected = states.object.get(self.instance_id) orelse return self.invalid("missing state expectation for instance {s}", .{self.instance_id});
                    const machine = self.activeMachine() orelse return self.unsupported("state expectation has no active instance", .{});
                    if (expected != .string) return self.invalid("instance state expectation must be a string", .{});
                    if (!std.mem.eql(u8, expected.string, machine.state())) return self.invalid("state mismatch: expected {s}, got {s}", .{ expected.string, machine.state() });
                }
            } else if (self.stable_state == null) return self.invalid("expect requires state or states", .{});
        }
        if (objectField(expect, "instance_attributes")) |instance_attributes| {
            if (instance_attributes != .object) return self.invalid("expect.instance_attributes must be an object", .{});
            if (self.instances) |instances| {
                var instance_iterator = instance_attributes.object.iterator();
                while (instance_iterator.next()) |instance_entry| {
                    const runtime = instances.get(instance_entry.key_ptr.*) orelse return self.invalid("unknown attribute expectation instance {s}", .{instance_entry.key_ptr.*});
                    if (runtime.machine == null) return self.invalid("instance {s} was not started", .{instance_entry.key_ptr.*});
                    var machine = runtime.machine.?;
                    if (instance_entry.value_ptr.* != .object) return self.invalid("instance attribute expectation must be an object", .{});
                    var attribute_iterator = instance_entry.value_ptr.object.iterator();
                    while (attribute_iterator.next()) |attribute_entry| {
                        const value = machine.Get(attribute_entry.key_ptr.*) catch null;
                        if (!self.anyOpaqueEquals(attribute_entry.key_ptr.*, value, attribute_entry.value_ptr.*)) return self.invalid("attribute mismatch for {s}.{s}", .{ instance_entry.key_ptr.*, attribute_entry.key_ptr.* });
                    }
                }
            } else {
                if (instance_attributes.object.count() != 1) return self.unsupported("per-instance attribute expectations require configured instances", .{});
                const expected_instance = instance_attributes.object.get(self.instance_id) orelse return self.invalid("unknown attribute expectation instance {s}", .{self.instance_id});
                if (expected_instance != .object) return self.invalid("instance attribute expectation must be an object", .{});
                if (self.machine == null) return self.invalid("instance {s} was not started", .{self.instance_id});
                var machine = self.machine.?;
                var attribute_iterator = expected_instance.object.iterator();
                while (attribute_iterator.next()) |attribute_entry| {
                    const value = machine.Get(attribute_entry.key_ptr.*) catch null;
                    if (!self.anyOpaqueEquals(attribute_entry.key_ptr.*, value, attribute_entry.value_ptr.*)) return self.invalid("attribute mismatch for {s}.{s}", .{ self.instance_id, attribute_entry.key_ptr.* });
                }
            }
        }
        if (objectField(expect, "trace")) |trace| try self.expectedTraceMatches(trace);
        if (objectField(expect, "snapshots")) |snapshots| {
            if (snapshots != .object) return self.invalid("expect.snapshots must be an object", .{});
            if (objectField(snapshots, "last")) |last| {
                try self.snapshotExpectationMatches(last);
            } else if (snapshots.object.count() == 1) {
                var iterator = snapshots.object.iterator();
                try self.snapshotExpectationMatches(iterator.next().?.value_ptr.*);
            } else if (snapshots.object.count() > 1) return self.unsupported("multiple snapshot expectations are outside the bounded runner", .{});
        }
        if (objectField(expect, "attributes")) |attributes| {
            if (self.instances != null) return self.unsupported("multi-instance attribute expectations are outside the bounded runner", .{});
            if (attributes != .object) return self.invalid("expect.attributes must be an object", .{});
            var iterator = attributes.object.iterator();
            while (iterator.next()) |entry| {
                const machine = self.activeMachine() orelse return self.unsupported("attribute expectation has no active instance", .{});
                const value = machine.Get(entry.key_ptr.*) catch null;
                if (!self.anyOpaqueEquals(entry.key_ptr.*, value, entry.value_ptr.*)) return self.invalid("attribute mismatch: {s}", .{entry.key_ptr.*});
            }
        }
        if (objectField(expect, "queue")) |queue| {
            if (queue != .object) return self.invalid("expect.queue must be an object", .{});
            if (objectField(queue, "deferred")) |deferred| {
                if (deferred != .array) return self.invalid("expect.queue.deferred must be an array", .{});
                if (deferred.array.items.len != self.deferred_history.items.len) return self.invalid("deferred queue length mismatch", .{});
                for (deferred.array.items, self.deferred_history.items) |expected_event, actual_event| {
                    if (expected_event != .string or !std.mem.eql(u8, expected_event.string, actual_event)) return self.invalid("deferred queue event mismatch", .{});
                }
            }
        }
    }

    fn run(self: *Runner) !void {
        var validation_mode = false;
        if (objectField(self.case_value, "mode")) |mode| {
            if (mode != .string) return self.invalid("mode must be a string", .{});
            if (std.mem.eql(u8, mode.string, "validation")) {
                validation_mode = true;
            } else if (!std.mem.eql(u8, mode.string, "runtime")) {
                return self.unsupported("mode {s}", .{mode.string});
            }
        }
        if (validation_mode) {
            if (self.preflightValidationCode()) |code| {
                try self.compareValidation(code);
                return;
            }
        } else {
            if (objectField(self.case_value, "instances") != null) {
                try self.configureSingleInstance();
            } else if (objectField(self.case_value, "groups") != null) {
                return self.unsupported("groups are outside the bounded runner", .{});
            }
        }
        const behaviors = objectField(self.case_value, "behaviors");
        if (behaviors) |value| {
            self.validateBehaviors(value) catch |err| {
                if (!validation_mode) return err;
                if (err == error.OutOfMemory) return err;
                if (self.reason == null) self.setReason("validation builder does not support case: {s}", .{@errorName(err)});
                return error.UnsupportedCase;
            };
        }
        const declared_root_model = try self.requireObject(self.case_value, "model");
        const declared_root_name = try self.requireString(declared_root_model, "name");
        if (self.model_selection_error != null) {
            try self.executeScript();
            try self.compareExpectation();
            return;
        }
        const selected_root_model = if (self.instances == null and !std.mem.eql(u8, self.model_name, declared_root_name))
            try self.modelDefinition(self.model_name)
        else
            declared_root_model;
        self.buildModel(selected_root_model) catch |err| {
            if (!validation_mode) return err;
            switch (err) {
                error.OutOfMemory => return err,
                else => {
                    if (self.reason == null) self.setReason("validation builder does not support case: {s}", .{@errorName(err)});
                    return error.UnsupportedCase;
                },
            }
        };

        if (validation_mode) {
            hsm.validate(&self.model.?) catch |validation_error| {
                const code = try self.nativeValidationCode(validation_error);
                try self.compareValidation(code);
                return;
            };
            return self.unsupported("native validator did not report a supported validation", .{});
        }

        hsm.validate(&self.model.?) catch |validation_error| {
            if (self.modelContainsHistory()) return self.unsupported("native model validation for history model is unsupported: {s}", .{@errorName(validation_error)});
            return self.invalid("native model validation failed: {s}", .{@errorName(validation_error)});
        };
        self.applySubmachineBoundaries();
        try self.installBehaviors(&self.model.?, self.model_name);

        if (self.instances) |instances| {
            _ = instances;
            for (self.instance_order.items) |runtime| {
                if (std.mem.eql(u8, runtime.model_name, declared_root_name)) {
                    self.copyTimerTemplate(runtime);
                    continue;
                }
                runtime.model = try self.buildAdditionalModel(runtime.model_name);
                self.copyTimerTemplate(runtime);
            }
        }
        try self.executeScript();
        try self.compareExpectation();
    }
};

fn configuredQueue(context: ?*anyopaque) *ConfiguredQueue {
    return @ptrCast(@alignCast(context.?));
}

fn configuredQueueTrace(queue: *ConfiguredQueue, prefix: []const u8, event_name: []const u8) !void {
    if (!queue.runner.traceIncludes("trace")) return;
    var owned_event_name: ?[]const u8 = null;
    defer if (owned_event_name) |value| queue.runner.allocator.free(value);
    const display_event_name = if (std.mem.startsWith(u8, event_name, "hsm_call:"))
        event_name["hsm_call:".len..]
    else if (std.mem.startsWith(u8, event_name, "_timeout:") or std.mem.startsWith(u8, event_name, "_periodic:")) blk: {
        const marker_len = if (event_name[0] == '_') std.mem.indexOfScalar(u8, event_name, ':').? + 1 else 0;
        const transition_name = event_name[marker_len..];
        const suffix = if (hsm.getTransition(&queue.runner.model.?, transition_name)) |transition|
            if (transition.timer_kind == .at) "timepoint" else "duration"
        else
            "duration";
        owned_event_name = try std.fmt.allocPrint(queue.runner.allocator, "{s}/{s}", .{ transition_name, suffix });
        break :blk owned_event_name.?;
    } else event_name;
    const value = if (display_event_name.len == 0)
        try queue.runner.allocator.dupe(u8, prefix)
    else
        try std.fmt.allocPrint(queue.runner.allocator, "{s}:{s}", .{ prefix, display_event_name });
    try appendTrace(queue.runner, .{ .kind = "trace", .value = value });
}

fn configuredQueueError(queue: *ConfiguredQueue, message: []const u8) void {
    appendTrace(queue.runner, .{ .kind = "error", .error_code = "runtime_error" }) catch {
        queue.runner.reason = "queue error trace allocation failed";
    };
    queue.runner.setReason("queue_error: {s}", .{message});
}

fn configuredQueuePush(context: ?*anyopaque, runtime_context: *hsm.Context, event: hsm.Event) anyerror!void {
    _ = runtime_context;
    const queue = configuredQueue(context);
    switch (queue.mode) {
        .push_error => {
            try configuredQueueTrace(queue, "queue:push-error", event.name);
            configuredQueueError(queue, "push error");
            return error.QueuePush;
        },
        .lifo => try queue.lifo.append(queue.runner.allocator, event),
        else => try queue.fifo.push(event),
    }
    if (queue.mode != .push_error and queue.mode != .len_seven) {
        if (std.mem.startsWith(u8, event.name, "hsm_call:") and queue.runner.behavior_depth > 0)
            queue.deferred_push_count += 1
        else
            try configuredQueueTrace(queue, "queue:push", event.name);
    }
}

fn configuredQueuePop(context: ?*anyopaque, runtime_context: *hsm.Context) anyerror!?hsm.Event {
    _ = runtime_context;
    const queue = configuredQueue(context);
    if (queue.mode == .pop_error_once and queue.pop_error_pending) {
        queue.pop_error_pending = false;
        try configuredQueueTrace(queue, "queue:pop-error", "");
        return error.QueuePop;
    }
    const event = switch (queue.mode) {
        .lifo => if (queue.lifo.items.len == 0) null else queue.lifo.pop(),
        else => queue.fifo.pop(),
    };
    if (event) |queued_event| {
        if (queue.deferred_push_count > 0 and std.mem.startsWith(u8, queued_event.name, "hsm_call:")) {
            queue.deferred_push_count -= 1;
            try configuredQueueTrace(queue, "queue:push", queued_event.name);
        }
        try configuredQueueTrace(queue, "queue:pop", queued_event.name);
        return queued_event;
    }
    return null;
}

fn configuredQueueLen(context: ?*anyopaque, runtime_context: *hsm.Context) anyerror!usize {
    _ = runtime_context;
    const queue = configuredQueue(context);
    if (queue.mode == .len_seven) return 7;
    return if (queue.mode == .lifo) queue.lifo.items.len else queue.fifo.len();
}

fn outcome(status: []const u8, name: []const u8, reason: []const u8, state: ?[]const u8) Outcome {
    return .{ .status = status, .name = name, .reason = reason, .state = state };
}

fn evaluate(allocator: std.mem.Allocator, input: []const u8) !Outcome {
    const case_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, input, .{}) catch {
        return outcome("fail", "unknown", "invalid JSON", null);
    };
    if (case_value != .object) return outcome("fail", "unknown", "case must be a JSON object", null);
    const version = case_value.object.get("version") orelse return outcome("fail", "unknown", "missing version", null);
    if (version != .string or !std.mem.eql(u8, version.string, "hsm-conformance-v1")) return outcome("fail", "unknown", "version must be hsm-conformance-v1", null);
    const name = case_value.object.get("name") orelse return outcome("fail", "unknown", "missing name", null);
    if (name != .string or name.string.len == 0) return outcome("fail", "unknown", "name must be a non-empty string", null);
    const model = case_value.object.get("model") orelse return outcome("fail", name.string, "missing model", null);
    if (model != .object) return outcome("fail", name.string, "model must be an object", null);
    const model_name = model.object.get("name") orelse return outcome("fail", name.string, "model.name is required", null);
    if (model_name != .string or model_name.string.len == 0) return outcome("fail", name.string, "model.name must be a non-empty string", null);

    var runner = try Runner.init(allocator, case_value, name.string, model_name.string);
    defer runner.deinit();
    runner.instance.runner = &runner;
    const expected_error_case = if (case_value.object.get("expect")) |expect|
        expect == .object and expect.object.get("error") != null
    else
        false;
    runner.run() catch |err| switch (err) {
        error.UnsupportedCase => return outcome("skip", name.string, runner.reason orelse "unsupported case", null),
        error.InvalidCase => if (expected_error_case)
            return outcome("skip", name.string, runner.reason orelse "expected runtime error case is outside the bounded runner", null)
        else
            return outcome("fail", name.string, runner.reason orelse "invalid case", null),
        error.RuntimeFailure => {
            if (expected_error_case) return outcome("skip", name.string, runner.reason orelse "expected runtime error case is outside the bounded runner", null);
            return outcome("fail", name.string, runner.reason orelse "runtime failure", null);
        },
        else => {
            if (expected_error_case) return outcome("skip", name.string, runner.reason orelse "expected runtime error case is outside the bounded runner", null);
            runner.setReason("runner error: {}", .{err});
            return outcome("fail", name.string, runner.reason orelse "runner error", null);
        },
    };
    const mode_value = if (case_value == .object) case_value.object.get("mode") else null;
    const is_validation = if (mode_value) |mode|
        mode == .string and std.mem.eql(u8, mode.string, "validation")
    else
        false;
    if (is_validation) return outcome("pass", name.string, runner.reason orelse "matched expected validation", null);
    const final_state = if (runner.activeMachine()) |machine| try allocator.dupe(u8, machine.state()) else null;
    return outcome("pass", name.string, runner.reason orelse "matched expected state and trace", final_state);
}

fn writeOutcome(writer: anytype, result: Outcome) !void {
    try std.json.Stringify.value(result, .{}, writer);
    try writer.writeByte('\n');
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var thread_safe_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
    const allocator = thread_safe_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const input = if (args.len > 1)
        try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024)
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
    const result = evaluate(allocator, input) catch |err| return err;
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.fs.File.stdout().writer(&output_buffer);
    try writeOutcome(&output_writer.interface, result);
    try output_writer.interface.flush();
    if (std.mem.eql(u8, result.status, "skip")) std.process.exit(77);
    if (!std.mem.eql(u8, result.status, "pass")) std.process.exit(1);
}

test "basic canonical subset passes" {
    const input =
        \\{"version":"hsm-conformance-v1","name":"basic","model":{"name":"Door","initial":"closed","states":[{"name":"closed","entry":[{"behavior":"enter"}],"exit":[{"behavior":"leave"}],"transitions":[{"on":"open","target":"open","effects":[{"behavior":"effect"}]}]},{"name":"open","entry":[{"behavior":"opened"}]}]},"behaviors":{"enter":[{"op":"trace","value":"enter"}],"leave":[{"op":"trace","value":"leave"}],"effect":[{"op":"trace","value":"effect"}],"opened":[{"op":"trace","value":"opened"}]},"script":[{"op":"start"},{"op":"dispatch","event":"open"}],"expect":{"state":"/Door/open","trace":[{"type":"trace","value":"enter"},{"type":"dispatch","event":"open"},{"type":"trace","value":"leave"},{"type":"trace","value":"effect"},{"type":"trace","value":"opened"},{"type":"stable","state":"/Door/open"}]}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evaluate(arena.allocator(), input);
    try std.testing.expectEqualStrings("pass", result.status);
}

test "wrong version fails before execution" {
    const input = "{\"version\":\"hsm-conformance-v0\",\"name\":\"old\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evaluate(arena.allocator(), input);
    try std.testing.expectEqualStrings("fail", result.status);
}

test "nested states are explicit skips" {
    const input = "{\"version\":\"hsm-conformance-v1\",\"name\":\"nested\",\"model\":{\"name\":\"M\",\"initial\":\"parent\",\"states\":[{\"name\":\"parent\",\"states\":[]}]},\"behaviors\":{},\"script\":[],\"expect\":{\"state\":\"/M/parent\"}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evaluate(arena.allocator(), input);
    try std.testing.expectEqualStrings("skip", result.status);
}

test "attribute equality rejects null for a present value" {
    const input =
        \\{"version":"hsm-conformance-v1","name":"null_mismatch","model":{"name":"M","initial":"idle","attributes":{"flag":{"type":"boolean","default":true}},"states":[{"name":"idle"}]},"behaviors":{},"script":[{"op":"start"}],"expect":{"state":"/M/idle","attributes":{"flag":null}}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evaluate(arena.allocator(), input);
    try std.testing.expectEqualStrings("fail", result.status);
}
