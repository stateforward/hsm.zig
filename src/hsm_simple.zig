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
    data: ?*anyopaque = null,
    
    const Self = @This();
    
    pub fn init(name: []const u8) Self {
        return Self{ .name = name };
    }
    
    pub fn withData(name: []const u8, data: *anyopaque) Self {
        return Self{ .name = name, .data = data };
    }
};

/// Base instance type that can be extended by user implementations
pub const Instance = struct {
    // Just a marker type - no dynamic storage needed
    // Could potentially hold common metadata in the future
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{};
    }
    
    pub fn deinit(self: *Self) void {
        // Nothing to clean up since no dynamic storage
        _ = self;
    }
};

// ============================================================================
// Function Signatures 
// ============================================================================

/// Entry function signature - executes when entering a state
pub fn EntryFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) void;
}

/// Exit function signature - executes when exiting a state  
pub fn ExitFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) void;
}

/// Effect function signature - executes during transitions
pub fn EffectFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) void;
}

/// Guard function signature - boolean condition for transitions
pub fn GuardFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) bool;
}

/// Activity function signature - long-running async operations
pub fn ActivityFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) void;
}

/// Timer function signature - returns nanoseconds for delays
pub fn TimerFn(comptime T: type) type {
    return fn(ctx: *Context, inst: *T, event: Event) u64;
}

// ============================================================================
// Simple State Machine Implementation
// ============================================================================

/// Simple state machine that just tracks current state and handles basic transitions
pub const StateMachine = struct {
    current_state: []const u8,
    states: std.StringHashMap(StateInfo),
    transitions: std.ArrayList(TransitionInfo),
    instance: *anyopaque,
    context_ptr: *Context,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    const StateInfo = struct {
        name: []const u8,
        entry_fn: ?*const anyopaque = null,
        exit_fn: ?*const anyopaque = null,
        activity_fn: ?*const anyopaque = null,
    };
    
    const TransitionInfo = struct {
        from_state: []const u8,
        event_name: []const u8,
        to_state: []const u8,
        guard_fn: ?*const anyopaque = null,
        effect_fn: ?*const anyopaque = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, ctx: *Context, instance: anytype, initial_state: []const u8) !Self {
        return Self{
            .current_state = try allocator.dupe(u8, initial_state),
            .states = std.StringHashMap(StateInfo).init(allocator),
            .transitions = std.ArrayList(TransitionInfo).init(allocator),
            .instance = instance,
            .context_ptr = ctx,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_state);
        self.states.deinit();
        self.transitions.deinit();
    }
    
    pub fn addState(self: *Self, name: []const u8, entry_fn: anytype, exit_fn: anytype, activity_fn: anytype) !void {
        const info = StateInfo{
            .name = try self.allocator.dupe(u8, name),
            .entry_fn = if (@TypeOf(entry_fn) != @TypeOf(null)) @ptrCast(&entry_fn) else null,
            .exit_fn = if (@TypeOf(exit_fn) != @TypeOf(null)) @ptrCast(&exit_fn) else null,
            .activity_fn = if (@TypeOf(activity_fn) != @TypeOf(null)) @ptrCast(&activity_fn) else null,
        };
        try self.states.put(name, info);
    }
    
    pub fn addTransition(self: *Self, from: []const u8, event: []const u8, to: []const u8, guard: anytype, effect: anytype) !void {
        const info = TransitionInfo{
            .from_state = try self.allocator.dupe(u8, from),
            .event_name = try self.allocator.dupe(u8, event),
            .to_state = try self.allocator.dupe(u8, to),
            .guard_fn = if (@TypeOf(guard) != @TypeOf(null)) @ptrCast(&guard) else null,
            .effect_fn = if (@TypeOf(effect) != @TypeOf(null)) @ptrCast(&effect) else null,
        };
        try self.transitions.append(info);
    }
    
    pub fn context(self: *const Self) *Context {
        return self.context_ptr;
    }
    
    pub fn state(self: *const Self) []const u8 {
        return self.current_state;
    }
    
    pub fn dispatch(self: *Self, event: Event) !void {
        // Find matching transition
        for (self.transitions.items) |transition| {
            if (std.mem.eql(u8, transition.from_state, self.current_state) and 
                std.mem.eql(u8, transition.event_name, event.name)) {
                
                // Check guard if present
                if (transition.guard_fn) |guard_ptr| {
                    const guard_fn: *const GuardFn(Instance) = @ptrCast(@alignCast(guard_ptr));
                    const instance: *Instance = @ptrCast(@alignCast(self.instance));
                    if (!guard_fn(self.context_ptr, instance, event)) {
                        continue;
                    }
                }
                
                // Execute transition
                try self.executeTransition(transition, event);
                return;
            }
        }
    }
    
    fn executeTransition(self: *Self, transition: TransitionInfo, event: Event) !void {
        // Exit current state
        if (self.states.get(self.current_state)) |state_info| {
            if (state_info.exit_fn) |exit_ptr| {
                const exit_fn: *const ExitFn(Instance) = @ptrCast(@alignCast(exit_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                exit_fn(self.context_ptr, instance, event);
            }
        }
        
        // Execute effect
        if (transition.effect_fn) |effect_ptr| {
            const effect_fn: *const EffectFn(Instance) = @ptrCast(@alignCast(effect_ptr));
            const instance: *Instance = @ptrCast(@alignCast(self.instance));
            effect_fn(self.context_ptr, instance, event);
        }
        
        // Update current state
        self.allocator.free(self.current_state);
        self.current_state = try self.allocator.dupe(u8, transition.to_state);
        
        // Enter new state
        if (self.states.get(self.current_state)) |state_info| {
            if (state_info.entry_fn) |entry_ptr| {
                const entry_fn: *const EntryFn(Instance) = @ptrCast(@alignCast(entry_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                entry_fn(self.context_ptr, instance, event);
            }
            
            // Start activity if present (simplified - just call directly for now)
            if (state_info.activity_fn) |activity_ptr| {
                const activity_fn: *const ActivityFn(Instance) = @ptrCast(@alignCast(activity_ptr));
                const instance: *Instance = @ptrCast(@alignCast(self.instance));
                // For simplicity, just call directly instead of spawning
                activity_fn(self.context_ptr, instance, event);
            }
        }
    }
};

// ============================================================================
// Convenience Functions for Simple Usage
// ============================================================================

/// Create a simple state machine with basic transitions
pub fn createSimpleStateMachine(allocator: std.mem.Allocator, ctx: *Context, instance: anytype) !StateMachine {
    return StateMachine.init(allocator, ctx, instance, "initial");
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
    const event1 = Event.init("test_event");
    try testing.expectEqualStrings("test_event", event1.name);
    try testing.expect(event1.data == null);
    
    var data: i32 = 42;
    const event2 = Event.withData("data_event", &data);
    try testing.expectEqualStrings("data_event", event2.name);
    try testing.expect(event2.data != null);
}

test "Instance creation" {
    var instance = Instance.init();
    defer instance.deinit();
    
    // Instance is now just a marker type
    // Real data would be in user's custom struct that embeds Instance
}

// Test instance struct for testing
const TestInstance = struct {
    base: Instance,
    entered: bool = false,
    exited: bool = false,
    allow_transition: bool = true,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = Instance.init(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Test functions for state machine
fn testEntry(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    test_inst.entered = true;
}

fn testExit(ctx: *Context, inst: *Instance, event: Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    test_inst.exited = true;
}

fn testGuard(ctx: *Context, inst: *Instance, event: Event) bool {
    _ = ctx;
    _ = event;
    const test_inst: *TestInstance = @ptrCast(@alignCast(inst));
    return test_inst.allow_transition;
}

test "Simple state machine transitions" {
    var context = Context.init(testing.allocator);
    var instance = TestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try createSimpleStateMachine(testing.allocator, &context, &instance);
    defer sm.deinit();
    
    // Add states
    try sm.addState("initial", testEntry, testExit, null);
    try sm.addState("active", testEntry, testExit, null);
    try sm.addState("done", testEntry, null, null);
    
    // Add transitions
    try sm.addTransition("initial", "start", "active", null, null);
    try sm.addTransition("active", "finish", "done", testGuard, null);
    
    // Set initial state
    sm.allocator.free(sm.current_state);
    sm.current_state = try sm.allocator.dupe(u8, "initial");
    
    // Test initial state
    try testing.expectEqualStrings("initial", sm.state());
    
    // Transition to active
    try sm.dispatch(Event.init("start"));
    try testing.expectEqualStrings("active", sm.state());
    try testing.expect(instance.entered); // Should have entered active state
    
    // Set up guard to allow transition
    instance.allow_transition = true;
    
    // Transition to done
    try sm.dispatch(Event.init("finish"));
    try testing.expectEqualStrings("done", sm.state());
}