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

/// Event represents a state machine event with optional data
pub const Event = struct {
    name: []const u8,
    data: ?std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .name = name,
            .data = null,
            .allocator = allocator,
        };
    }

    pub fn withData(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .name = name,
            .data = std.HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
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
    effects: [][]const u8, // qualified names of effect behaviors
    timer_fn: ?[]const u8, // qualified name of timer behavior
    paths: std.StringHashMap(TransitionPaths), // precomputed paths for each source state

    const Self = @This();
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

/// Model containing all elements in flat storage
pub const Model = struct {
    name: []const u8,
    members: std.StringHashMap(*Element), // flat storage by qualified name
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
                .state, .model => {
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

                    // Free effects array
                    if (trans_elem.effects.len > 0) self.allocator.free(trans_elem.effects);

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

/// Create a target builder
pub fn target(comptime target_path: []const u8) TargetBuilder {
    return TargetBuilder.init(target_path);
}

/// Create a timer builder for 'after' transitions
pub fn after(comptime timer_function: anytype) type {
    return struct {
        timer_fn: @TypeOf(timer_function) = timer_function,
    };
}

/// Create a timer builder for 'every' transitions
pub fn every(comptime timer_function: anytype) type {
    return struct {
        timer_fn: @TypeOf(timer_function) = timer_function,
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

/// Create a transition builder - supports multiple arguments in tuple
pub fn transition(comptime args: anytype) type {
    return struct {
        args: @TypeOf(args) = args,

        pub fn getEvent(self: @This()) ?[]const u8 {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                if (ArgType == EventBuilder) {
                    return arg.event_name;
                }
            }
            return null;
        }

        pub fn getTarget(self: @This()) ?[]const u8 {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                if (ArgType == TargetBuilder) {
                    return arg.target_path;
                }
            }
            return null;
        }

        pub fn getSource(self: @This()) ?[]const u8 {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "source_path")) {
                    return arg.source_path;
                }
            }
            return null;
        }

        pub fn getGuard(self: @This()) ?*const anyopaque {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "function")) {
                    return @ptrCast(&arg.function);
                }
            }
            return null;
        }

        pub fn getEffects(self: @This()) []const *const anyopaque {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "functions")) {
                    // Convert function array to pointers
                    const func_count = arg.functions.len;
                    var func_ptrs: [func_count]*const anyopaque = undefined;
                    for (arg.functions, 0..) |func, idx| {
                        func_ptrs[idx] = @ptrCast(&func);
                    }
                    return &func_ptrs;
                }
            }
            return &[_]*const anyopaque{};
        }

        pub fn getTimer(self: @This()) ?*const anyopaque {
            const fields = std.meta.fields(@TypeOf(self.args));
            inline for (fields, 0..) |_, i| {
                const arg = self.args[i];
                const ArgType = @TypeOf(arg);
                const type_info = @typeInfo(ArgType);
                if (type_info == .@"struct" and @hasField(ArgType, "timer_fn")) {
                    return @ptrCast(&arg.timer_fn);
                }
            }
            return null;
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
                if (@hasField(element_type, "state_type")) {
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

            const event_name = trans_builder.getEvent();
            const raw_target_path = trans_builder.getTarget();

            // Resolve target path if present (ownership transferred to addTransition)
            var resolved_target_path: ?[]const u8 = null;
            if (raw_target_path) |target_path| {
                resolved_target_path = try resolveTargetPath(model.allocator, state_path, target_path);
            }

            const trans = try addTransition(model, trans_name, state_path, resolved_target_path, event_name);

            // Add guard if present
            if (trans_builder.getGuard()) |guard_fn_ptr| {
                const guard_name = try std.fmt.allocPrint(model.allocator, "{s}/guard", .{trans_name});
                _ = try addBehavior(model, guard_name, guard_fn_ptr);
                trans.guard = guard_name;
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
    sm: *StateMachine,
    trans: *TransitionElement,
    timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64,
    instance: *Instance,
    ctx: *Context,
    event: Event,
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
    active_timers: std.StringHashMap(std.Thread),
    history_value: std.StringHashMap([]const u8),
    deferred_queue: EventQueue,
    stopped: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn context(self: *const Self) *Context {
        return self._context;
    }

    pub fn state(self: *const Self) []const u8 {
        return self.current_state;
    }

    fn executeWithErrorHandling(self: *Self, func: anytype, ctx: *Context, inst: *Instance, event: Event, operation_type: []const u8) !void {
        _ = self;
        _ = operation_type;
        // In a real implementation, this would wrap the function call in error handling
        // For now, just call the function directly
        func(ctx, inst, event);
    }

    fn dispatchErrorEvent(self: *Self, ctx: *Context, err: anyerror, error_source: []const u8) !void {
        var error_event = Event.withData(ctx.allocator, "__ERROR__");
        defer error_event.deinit();
        try error_event.putData("error_type", @constCast(@as(*const anyopaque, @ptrCast(&err))));
        try error_event.putData("source", @constCast(@as(*const anyopaque, @ptrCast(&error_source))));

        // Dispatch error event (avoid infinite recursion by using processEvent directly)
        try self.processEvent(ctx, error_event);
    }

    pub fn dispatch(self: *Self, ctx: *Context, event: Event) !void {
        if (self.stopped) return;

        // Check if event should be deferred using O(1) lookup
        if (self.model.deferred_map.get(self.current_state)) |event_map| {
            if (event_map.get(event.name)) |is_deferred| {
                if (is_deferred) {
                    // Defer the event
                    try self.deferred_queue.enqueue(event);
                    return;
                }
            }
        }

        // Process the event immediately
        try self.processEvent(ctx, event);

        // After processing, check deferred queue for events that can now be processed
        try self.processDeferredEvents(ctx);
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

        // Fall back to searching parent states for event bubbling
        try self.bubbleEvent(event, ctx);
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

        // Check guard condition
        if (trans.guard) |guard_name| {
            const guard_behavior = getBehavior(self.model, guard_name) orelse return false;
            const guard_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) bool = @ptrCast(@alignCast(guard_behavior.function_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            if (!guard_fn(ctx, instance, event)) {
                return false;
            }
        }

        return true;
    }

    fn executeTransition(self: *Self, trans: *TransitionElement, event: Event, ctx: *Context) !void {
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
                if (!std.mem.eql(u8, self.current_state, target_name)) {
                    // Current state was already updated by initial transitions, don't override
                } else {
                    self.allocator.free(self.current_state);
                    self.current_state = try self.allocator.dupe(u8, target_name);
                }
            }
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

            // Cancel activities by setting context done flag
            ctx.cancel();

            // Wait for activities to finish (with timeout to avoid hanging)
            for (state_element.activities) |activity_name| {
                if (self.active_activities.get(activity_name)) |thread| {
                    thread.join(); // Wait for activity to respect cancellation
                    _ = self.active_activities.remove(activity_name);
                }
            }

            // Cancel and wait for timers to finish
            for (state_element.transitions) |trans_name| {
                if (self.active_timers.get(trans_name)) |thread| {
                    thread.join(); // Wait for timer to respect cancellation
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
            if (trans.timer_fn) |timer_fn_name| {
                const timer_behavior = getBehavior(self.model, timer_fn_name) orelse continue;
                const timer_fn: *const fn (ctx: *Context, inst: *Instance, event: Event) u64 = @ptrCast(@alignCast(timer_behavior.function_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));

                // Create timer thread context

                const timer_context = try self.allocator.create(TimerContext);
                timer_context.* = TimerContext{
                    .sm = self,
                    .trans = trans,
                    .timer_fn = timer_fn,
                    .instance = instance,
                    .ctx = ctx,
                    .event = event,
                };

                const thread = std.Thread.spawn(.{}, timerThreadFn, .{timer_context}) catch |err| {
                    std.log.warn("Failed to spawn timer thread for {s}: {}", .{ trans_name, err });
                    self.allocator.destroy(timer_context);
                    continue;
                };

                // Track the timer thread
                self.active_timers.put(trans_name, thread) catch |err| {
                    std.log.warn("Failed to track timer thread for {s}: {}", .{ trans_name, err });
                    thread.detach();
                    self.allocator.destroy(timer_context);
                    continue;
                };
            }
        }
    }

    fn timerThreadFn(timer_context: *const TimerContext) void {
        defer timer_context.sm.allocator.destroy(timer_context);

        // Get delay from timer function
        const delay_ns = timer_context.timer_fn(timer_context.ctx, timer_context.instance, timer_context.event);

        // Sleep for the specified time, checking cancellation periodically
        const sleep_chunk_ns = std.time.ns_per_ms * 100; // 100ms chunks
        var remaining_ns = delay_ns;

        while (remaining_ns > 0 and !timer_context.ctx.is_done()) {
            const chunk = @min(remaining_ns, sleep_chunk_ns);
            std.Thread.sleep(chunk);
            remaining_ns -= chunk;
        }

        // Check if context is still active and we completed the full delay
        if (!timer_context.ctx.is_done() and remaining_ns == 0) {
            // Create timer completion event
            var timer_event = Event.init(timer_context.ctx.allocator, "__TIMER_COMPLETE__");
            defer timer_event.deinit();

            // Dispatch using the specific transition that fired
            timer_context.sm.executeTransition(timer_context.trans, timer_event, timer_context.ctx) catch |err| {
                // Dispatch error event if timer transition fails
                var error_event = Event.withData(timer_context.ctx.allocator, "__ERROR__");
                defer error_event.deinit();
                error_event.putData("error_type", @constCast(&err)) catch {};
                const source_str = "timer_transition";
                error_event.putData("source", @constCast(@as(*const anyopaque, @ptrCast(&source_str)))) catch {};

                timer_context.sm.dispatch(timer_context.ctx, error_event) catch |dispatch_err| {
                    std.log.err("Failed to dispatch both timer and error events: timer={}, error={}", .{ err, dispatch_err });
                };
            };
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
            timer_entry.value_ptr.join();
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

        // Free current state string
        self.allocator.free(self.current_state);
    }
};

/// Start a state machine with flat element model
pub fn start(ctx: *Context, instance: anytype, model: *const Model) !StateMachine {
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
        .active_timers = std.StringHashMap(std.Thread).init(ctx.allocator),
        .history_value = std.StringHashMap([]const u8).init(ctx.allocator),
        .deferred_queue = try EventQueue.init(ctx.allocator),
        .stopped = false,
        .allocator = ctx.allocator,
    };

    // Enter the root state with default_entry=true to follow initial transitions recursively
    const initial_event = Event.init(ctx.allocator, "__INITIAL__");
    try sm.enterState(root_state_name, initial_event, ctx, true);

    return sm;
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
        .transition_map = std.StringHashMap(std.StringHashMap([][]const u8)).init(allocator),
        .deferred_map = std.StringHashMap(std.StringHashMap(bool)).init(allocator),
        .allocator = allocator,
    };
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
        .effects = &[_][]const u8{},
        .timer_fn = null,
        .paths = std.StringHashMap(TransitionPaths).init(model.allocator),
    };

    try model.members.put(transition_element.element.qualified_name, @ptrCast(transition_element));
    return transition_element;
}

/// Resolve a target path relative to the source state
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < path.len) {
        if (i + 1 < path.len and path[i] == '.' and path[i + 1] == '/') {
            // Skip "./" sequence
            i += 2;
        } else {
            try result.append(allocator, path[i]);
            i += 1;
        }
    }

    return try allocator.dupe(u8, result.items);
}

fn resolveTargetPath(allocator: std.mem.Allocator, source_state: []const u8, target_path: []const u8) ![]const u8 {
    if (target_path[0] == '/') {
        // Absolute path
        return try allocator.dupe(u8, target_path);
    } else if (std.mem.eql(u8, target_path, ".")) {
        // Self reference
        return try allocator.dupe(u8, source_state);
    } else if (std.mem.startsWith(u8, target_path, "../")) {
        // Relative to parent
        const parent_path = std.fs.path.dirname(source_state) orelse "/";
        const remaining_path = target_path[3..]; // Skip "../"
        if (remaining_path.len == 0) {
            return try allocator.dupe(u8, parent_path);
        } else {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, remaining_path });
        }
    } else {
        // Relative to current state (child)
        const raw_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_state, target_path });
        defer allocator.free(raw_path);

        // Normalize the path to remove "./" segments
        return try normalizePath(allocator, raw_path);
    }
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
            // Regular transition: exit source, enter target
            try exit_states.append(model.allocator, try model.allocator.dupe(u8, source_state));
            try enter_states.append(model.allocator, try model.allocator.dupe(u8, resolved_target));
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
        trans_entry.value_ptr.deinit();
    }
    model.transition_map.clearAndFree();

    // Iterate through all transitions and build the map
    var members_iter = model.members.iterator();
    while (members_iter.next()) |kv| {
        const element = kv.value_ptr.*;
        if (element.kind != .transition) continue;

        const trans: *TransitionElement = @ptrCast(@alignCast(element));
        const source_state = trans.source;

        // Get or create event map for this state
        var event_map = model.transition_map.getPtr(source_state);
        if (event_map == null) {
            const new_event_map = std.StringHashMap([][]const u8).init(model.allocator);
            try model.transition_map.put(try model.allocator.dupe(u8, source_state), new_event_map);
            event_map = model.transition_map.getPtr(source_state);
        }

        if (trans.event_name) |event_name| {
            // Get or create transition list for this event
            const transition_list = event_map.?.get(event_name);
            if (transition_list == null) {
                const new_list = try model.allocator.alloc([]const u8, 1);
                new_list[0] = try model.allocator.dupe(u8, trans.element.qualified_name);
                try event_map.?.put(try model.allocator.dupe(u8, event_name), new_list);
            } else {
                // Append to existing list (simplified - would need proper resizing)
                const old_list = transition_list.?;
                const new_list = try model.allocator.alloc([]const u8, old_list.len + 1);
                @memcpy(new_list[0..old_list.len], old_list);
                new_list[old_list.len] = try model.allocator.dupe(u8, trans.element.qualified_name);
                try event_map.?.put(try model.allocator.dupe(u8, event_name), new_list);
                model.allocator.free(old_list);
            }
        }

        // Compute transition paths for this transition
        try computeTransitionPaths(model, trans, source_state);
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
