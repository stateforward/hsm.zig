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
        std.Thread.sleep(std.time.ns_per_ms * 500); // 500ms
        iteration += 1;

        if (ctx.is_done()) break;
    }

    std.log.info("Background activity completed", .{});
}

// Timer function for periodic events
fn periodicTimer(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx;
    _ = inst;
    _ = event;
    return std.time.ns_per_s * 2; // 2 seconds
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting HSM basic example...", .{});

    // Define the state machine model at compile time
    const model = comptime hsm.define("ExampleMachine", .{
        hsm.initial(hsm.target("idle")),

        hsm.state("idle", .{
            hsm.entry(idleEntry),
            hsm.transition(.{ hsm.on("start"), hsm.target("active") }),
            hsm.transition(.{ hsm.on("reset"), hsm.target(".") }), // Self transition
        }),

        hsm.state("active", .{
            hsm.entry(activeEntry),
            hsm.activity(backgroundActivity),
            hsm.transition(.{ hsm.on("process"), hsm.effect(processEffect), hsm.target(".") }),
            hsm.transition(.{ hsm.on("complete"), hsm.guard(completionGuard), hsm.target("../idle") }),
            hsm.transition(.{ hsm.on("stop"), hsm.target("../idle") }),
            hsm.transition(.{ hsm.every(periodicTimer), hsm.effect(processEffect) }), // Internal transition
        }),

        hsm.final("done"),
    });

    var built_model = try model.build(allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = MyInstance.init(allocator);
    defer instance.deinit();

    // Start the state machine
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    std.log.info("State machine started in state: {s}", .{sm.state()});

    // Simulate some events
    std.log.info("Dispatching 'start' event...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "start"));
    std.log.info("Current state: {s}", .{sm.state()});

    // Wait a bit for background activity
    std.Thread.sleep(std.time.ns_per_s);

    // Process a few times
    for (0..3) |i| {
        std.log.info("Dispatching 'process' event {} ...", .{i + 1});
        try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
        std.Thread.sleep(std.time.ns_per_ms * 200);
    }

    // Try to complete (should fail guard)
    std.log.info("Trying to complete (should fail guard)...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "complete"));
    std.log.info("Current state: {s}", .{sm.state()});

    // Process more to satisfy guard
    for (0..3) |i| {
        std.log.info("Processing more {} ...", .{i + 1});
        try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
        std.Thread.sleep(std.time.ns_per_ms * 200);
    }

    // Now complete should work
    std.log.info("Completing (should pass guard)...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "complete"));
    std.log.info("Final state: {s}", .{sm.state()});

    // Cancel context to stop activities
    context.cancel();

    std.log.info("Example completed!", .{});
}
