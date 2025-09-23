const std = @import("std");
const hsm = @import("hsm");

// Custom instance type extending base Instance
const MyInstance = struct {
    base: hsm.Instance,
    counter: i32,
    status: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{
            .base = hsm.Instance.init(),
            .counter = 0,
            .status = "idle",
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Entry action for idle state
fn idleEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter = 0;
    my_inst.status = "idle";
    std.log.info("Entered idle state, counter reset to {}", .{my_inst.counter});
}

// Entry action for active state
fn activeEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.status = "active";
    std.log.info("Entered active state, status: {s}", .{my_inst.status});
}

// Exit action for active state
fn activeExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    std.log.info("Exiting active state, final counter: {}", .{my_inst.counter});
}

// Effect action for processing
fn processEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter += 1;
    std.log.info("Processing... counter: {}", .{my_inst.counter});
}

// Guard condition for completion
fn completionGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    return my_inst.counter >= 5;
}

// Activity for background work
fn backgroundActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    
    var iteration: u32 = 0;
    while (!ctx.is_done() and iteration < 10) {
        std.log.info("Background activity iteration {}, counter: {}", .{ iteration, my_inst.counter });
        std.time.sleep(std.time.ns_per_ms * 500); // 500ms
        iteration += 1;
        
        if (ctx.is_done()) break;
    }
    
    std.log.info("Background activity completed", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Starting HSM simple example...", .{});
    
    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = MyInstance.init(allocator);
    defer instance.deinit();
    
    // Create the state machine
    var sm = try hsm.createSimpleStateMachine(allocator, &context, &instance);
    defer sm.deinit();
    
    // Add states
    try sm.addState("idle", idleEntry, null, null);
    try sm.addState("active", activeEntry, activeExit, backgroundActivity);
    try sm.addState("done", null, null, null);
    
    // Add transitions
    try sm.addTransition("idle", "start", "active", null, null);
    try sm.addTransition("active", "process", "active", null, processEffect); // Self transition with effect
    try sm.addTransition("active", "complete", "done", completionGuard, null);
    try sm.addTransition("active", "stop", "idle", null, null);
    
    // Set initial state to idle
    sm.allocator.free(sm.current_state);
    sm.current_state = try sm.allocator.dupe(u8, "idle");
    
    std.log.info("State machine started in state: {s}", .{sm.state()});
    
    // Simulate some events
    std.log.info("Dispatching 'start' event...", .{});
    try sm.dispatch(hsm.Event.init("start"));
    std.log.info("Current state: {s}", .{sm.state()});
    
    // Wait a bit for background activity
    std.time.sleep(std.time.ns_per_s);
    
    // Process a few times
    for (0..3) |i| {
        std.log.info("Dispatching 'process' event {} ...", .{i + 1});
        try sm.dispatch(hsm.Event.init("process"));
        std.time.sleep(std.time.ns_per_ms * 200);
    }
    
    // Try to complete (should fail guard)
    std.log.info("Trying to complete (should fail guard)...", .{});
    try sm.dispatch(hsm.Event.init("complete"));
    std.log.info("Current state: {s}", .{sm.state()});
    
    // Process more to satisfy guard
    for (0..3) |i| {
        std.log.info("Processing more {} ...", .{i + 1});
        try sm.dispatch(hsm.Event.init("process"));
        std.time.sleep(std.time.ns_per_ms * 200);
    }
    
    // Now complete should work
    std.log.info("Completing (should pass guard)...", .{});
    try sm.dispatch(hsm.Event.init("complete"));
    std.log.info("Final state: {s}", .{sm.state()});
    
    // Cancel context to stop activities
    context.cancel();
    
    std.log.info("Example completed!", .{});
}