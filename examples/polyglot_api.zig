const std = @import("std");
const hsm = @import("hsm");

// Custom instance type
const MyInstance = struct {
    base: hsm.Instance,
    counter: i32,
    status: []const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .counter = 0,
            .status = "idle",
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Multiple entry functions for demonstration
fn logEntry(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    std.log.info("Entry: {s} (event: {s})", .{ inst.status, event.name });
}

fn initializeCounters(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    inst.counter = 0;
    std.log.info("Counters initialized", .{});
}

fn setupState(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    inst.status = "active";
    std.log.info("State setup completed", .{});
}

// Multiple exit functions
fn saveData(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    std.log.info("Saving data... counter: {}", .{inst.counter});
}

fn cleanupResources(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    std.log.info("Cleaning up resources...", .{});
}

fn logStateExit(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    std.log.info("Exiting state, final counter: {}", .{inst.counter});
}

// Multiple effect functions
fn validateInput(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    std.log.info("Validating input...", .{});
}

fn processData(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    inst.counter += 1;
    std.log.info("Processing data, counter: {}", .{inst.counter});
}

fn updateUI(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    inst.status = "updated";
    std.log.info("UI updated", .{});
}

// Multiple concurrent activities
fn backgroundSync(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = inst;
    _ = event;
    var i: u32 = 0;
    while (!ctx.is_done() and i < 5) : (i += 1) {
        std.log.info("Background sync #{}", .{i});
        std.time.sleep(std.time.ns_per_s);
        if (ctx.is_done()) break;
    }
}

fn heartbeat(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = event;
    _ = inst;
    var i: u32 = 0;
    while (!ctx.is_done() and i < 10) : (i += 1) {
        std.log.info("Heartbeat...", .{});
        std.time.sleep(std.time.ns_per_ms * 500);
        if (ctx.is_done()) break;
    }
}

fn monitoring(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) void {
    _ = event;
    var i: u32 = 0;
    while (!ctx.is_done() and i < 20) : (i += 1) {
        std.log.info("Monitoring system health... counter: {}", .{inst.counter});
        std.time.sleep(std.time.ns_per_ms * 250);
        if (ctx.is_done()) break;
    }
}

// Guard function
fn counterGuard(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    return inst.counter > 5;
}

// Timer function
fn shortDelay(ctx: *hsm.Context, inst: *MyInstance, event: hsm.Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return std.time.ns_per_s * 2; // 2 seconds
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Starting HSM Polyglot API Example...", .{});
    
    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = MyInstance.init(allocator);
    defer instance.deinit();
    
    // Define state machine using JavaScript-style API with Zig's anonymous tuples
    const model = hsm.define("PolyglotMachine", .{
        hsm.initial(hsm.target("idle")),
        
        hsm.state("idle", .{
            // Single entry function
            hsm.entry(logEntry),
            hsm.transition(.{
                hsm.on("start"),
                hsm.target("active"),
            }),
        }),
        
        hsm.state("active", .{
            // Multiple entry functions
            hsm.entry(.{ setupState, logEntry, initializeCounters }),
            // Multiple exit functions
            hsm.exit(.{ saveData, cleanupResources, logStateExit }),
            // Multiple concurrent activities
            hsm.activity(.{ backgroundSync, heartbeat, monitoring }),
            
            // Transition with multiple effects
            hsm.transition(.{
                hsm.on("process"),
                hsm.effect(.{ validateInput, processData, updateUI }),
                hsm.target("."), // Self transition
            }),
            
            // Transition with guard
            hsm.transition(.{
                hsm.on("complete"),
                hsm.guard(counterGuard),
                hsm.target("done"),
            }),
            
            // Timer-based transition
            hsm.transition(.{
                hsm.after(shortDelay),
                hsm.target("timeout"),
            }),
        }),
        
        hsm.state("timeout", .{
            hsm.entry(logEntry),
        }),
        
        hsm.final("done"),
    });
    
    // Validate the model (optional)
    const built_model = try model.build(allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    // Start the state machine
    var sm = try hsm.start(&context, &instance, model);
    defer sm.deinit();
    
    std.log.info("Initial state: {s}", .{sm.state()});
    
    // Dispatch some events
    std.log.info("\nDispatching 'start' event...", .{});
    try sm.dispatch(&context, hsm.Event.init("start"));
    std.log.info("Current state: {s}", .{sm.state()});
    
    // Let activities run for a bit
    std.time.sleep(std.time.ns_per_s);
    
    // Process multiple times to demonstrate multiple effects
    for (0..3) |i| {
        std.log.info("\nDispatching 'process' event #{}", .{i + 1});
        try sm.dispatch(&context, hsm.Event.init("process"));
        std.time.sleep(std.time.ns_per_ms * 500);
    }
    
    // Try to complete (should fail guard)
    std.log.info("\nTrying to complete (counter = {}, should fail)...", .{instance.counter});
    try sm.dispatch(&context, hsm.Event.init("complete"));
    std.log.info("Still in state: {s}", .{sm.state()});
    
    // Process more to satisfy guard
    for (0..5) |i| {
        std.log.info("\nMore processing #{}", .{i + 1});
        try sm.dispatch(&context, hsm.Event.init("process"));
        std.time.sleep(std.time.ns_per_ms * 200);
    }
    
    // Now complete should work
    std.log.info("\nCompleting (counter = {}, should pass)...", .{instance.counter});
    try sm.dispatch(&context, hsm.Event.init("complete"));
    std.log.info("Final state: {s}", .{sm.state()});
    
    // Cancel context to stop activities
    context.cancel();
    
    std.log.info("\nPolyglot API example completed!", .{});
}