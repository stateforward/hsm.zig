const std = @import("std");
const hsm = @import("hsm");

// Custom instance type
const DemoInstance = struct {
    base: hsm.Instance,
    counter: i32,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = hsm.Instance.init(),
            .counter = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

// Entry/exit/effect functions
fn increment(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const demo_inst: *DemoInstance = @ptrCast(@alignCast(inst));
    demo_inst.counter += 1;
    std.log.info("Counter incremented to {}", .{demo_inst.counter});
}

fn reset(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const demo_inst: *DemoInstance = @ptrCast(@alignCast(inst));
    demo_inst.counter = 0;
    std.log.info("Counter reset to 0", .{});
}

fn checkCounter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const demo_inst: *DemoInstance = @ptrCast(@alignCast(inst));
    return demo_inst.counter >= 3;
}

fn logEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    std.log.info("State entered", .{});
}

fn shortDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return std.time.ns_per_s; // 1 second
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== HSM Feature Demonstration ===", .{});
    
    // Define state machine with new features
    const model = comptime hsm.define("FeatureDemo", .{
        hsm.initial(hsm.target("waiting")),
        
        hsm.state("waiting", .{
            hsm.entry(.{logEntry, reset}),
            hsm.deferEvents(.{"pause", "resume"}), // Deferred events
            hsm.transition(.{ hsm.on("process"), hsm.effect(increment), hsm.target("processing") }),
            hsm.transition(.{ hsm.after(shortDelay), hsm.target("timeout") })
        }),
        
        hsm.state("processing", .{
            hsm.entry(logEntry),
            hsm.transition(.{ hsm.on("process"), hsm.effect(increment) }), // Internal transition
            hsm.transition(.{ hsm.on("check"), hsm.guard(checkCounter), hsm.target("../complete") }),
            hsm.transition(.{ hsm.on("check"), hsm.target("../waiting") }) // Fallback
        }),
        
        hsm.choice("decision", .{
            hsm.transition(.{ hsm.guard(checkCounter), hsm.target("../complete") }),
            hsm.transition(.{ hsm.target("../waiting") }) // Required guardless fallback
        }),
        
        hsm.state("complete", .{
            hsm.entry(logEntry)
        }),
        
        hsm.state("timeout", .{
            hsm.entry(logEntry)
        })
    });
    
    // Build and validate the model
    var built_model = try model.build(allocator);
    defer built_model.deinit();
    
    try hsm.validate(&built_model);
    std.log.info("Model validation passed", .{});
    
    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = DemoInstance.init();
    defer instance.deinit();
    
    // Start the state machine
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    std.log.info("Started in state: {s}", .{sm.state()});
    
    // Test deferred events
    std.log.info("\n--- Testing Deferred Events ---", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "pause"));
    try sm.dispatch(&context, hsm.Event.init(allocator, "resume"));
    std.log.info("Sent deferred events (should be queued)", .{});
    
    // Process some events
    std.log.info("\n--- Processing Events ---", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
    std.log.info("Current state: {s}, counter: {}", .{sm.state(), instance.counter});
    
    try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
    try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
    std.log.info("After processing, counter: {}", .{instance.counter});
    
    // Test guard condition
    try sm.dispatch(&context, hsm.Event.init(allocator, "check"));
    std.log.info("Final state: {s}", .{sm.state()});
    
    // Stop the state machine
    try hsm.stop(&sm);
    std.log.info("State machine stopped successfully", .{});
}