const std = @import("std");
const hsm = @import("hsm");

// Simple instance that extends base Instance
const MyInstance = struct {
    base: hsm.Instance,
    counter: i32,
    status: []const u8,

    const Self = @This();

    pub fn init() Self {
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

// Entry functions - all take base Instance type
fn idleEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter = 0;
    my_inst.status = "idle";
    std.log.info("Entered idle state", .{});
}

fn setupLog(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    std.log.info("Setting up state for {s}", .{my_inst.status});
}

fn initCounters(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter = 0;
    std.log.info("Counters initialized", .{});
}

fn activeEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.status = "active";
    std.log.info("Entered active state", .{});
}

fn saveData(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    std.log.info("Saving data, counter: {}", .{my_inst.counter});
}

fn cleanup(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    std.log.info("Cleaning up...", .{});
}

fn validateInput(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = inst;
    _ = event;
    std.log.info("Validating input...", .{});
}

fn processData(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter += 1;
    std.log.info("Processing data, counter: {}", .{my_inst.counter});
}

fn counterGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    return my_inst.counter >= 3;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting Basic API Demo...", .{});

    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = MyInstance.init();
    defer instance.deinit();

    // Create model using runtime API for now since the compile-time API has issues
    var model = try hsm.createModel(allocator, "BasicDemo");
    defer model.deinit();

    // Add root state
    _ = try hsm.addState(&model, "/BasicDemo", .model);

    // Add states
    _ = try hsm.addState(&model, "/BasicDemo/idle", .state);
    _ = try hsm.addState(&model, "/BasicDemo/active", .state);
    _ = try hsm.addState(&model, "/BasicDemo/done", .final);

    // Runtime-built models own the names stored in behavior and transition
    // arrays. Start at idle just like the compile-time API does.
    const initial_trans = try hsm.addTransition(&model, "/BasicDemo/.initial", "/BasicDemo", "/BasicDemo/idle", null);
    const root_state = hsm.getState(&model, "/BasicDemo").?;
    root_state.initial_transition = try allocator.dupe(u8, initial_trans.element.qualified_name);

    // Add behaviors
    _ = try hsm.addBehavior(&model, "/BasicDemo/idle/entry", @ptrCast(&idleEntry));
    _ = try hsm.addBehavior(&model, "/BasicDemo/active/entry", @ptrCast(&activeEntry));
    _ = try hsm.addBehavior(&model, "/BasicDemo/active/exit", @ptrCast(&saveData));
    _ = try hsm.addBehavior(&model, "/BasicDemo/validate", @ptrCast(&validateInput));
    _ = try hsm.addBehavior(&model, "/BasicDemo/process", @ptrCast(&processData));
    _ = try hsm.addBehavior(&model, "/BasicDemo/guard", @ptrCast(&counterGuard));

    // Add transitions
    const idle_to_active = try hsm.addTransition(&model, "/BasicDemo/idle/start_trans", "/BasicDemo/idle", "/BasicDemo/active", "start");
    _ = idle_to_active;

    const process_trans = try hsm.addTransition(&model, "/BasicDemo/active/process_trans", "/BasicDemo/active", "/BasicDemo/active", "process");
    var effect_names = try allocator.alloc([]const u8, 2);
    effect_names[0] = try allocator.dupe(u8, "/BasicDemo/validate");
    effect_names[1] = try allocator.dupe(u8, "/BasicDemo/process");
    process_trans.effects = effect_names;

    const complete_trans = try hsm.addTransition(&model, "/BasicDemo/active/complete_trans", "/BasicDemo/active", "/BasicDemo/done", "complete");
    complete_trans.guard = try allocator.dupe(u8, "/BasicDemo/guard");

    // Set up the states' behaviors
    const idle_state = hsm.getState(&model, "/BasicDemo/idle").?;
    var idle_entry_names = try allocator.alloc([]const u8, 1);
    idle_entry_names[0] = try allocator.dupe(u8, "/BasicDemo/idle/entry");
    idle_state.entry = idle_entry_names;

    const active_state = hsm.getState(&model, "/BasicDemo/active").?;
    var active_entry_names = try allocator.alloc([]const u8, 1);
    active_entry_names[0] = try allocator.dupe(u8, "/BasicDemo/active/entry");
    active_state.entry = active_entry_names;
    var active_exit_names = try allocator.alloc([]const u8, 1);
    active_exit_names[0] = try allocator.dupe(u8, "/BasicDemo/active/exit");
    active_state.exit = active_exit_names;

    // Build transition map
    try hsm.buildTransitionMap(&model);

    // Start the state machine
    var sm = try hsm.start(&context, &instance, &model);
    defer sm.deinit();

    std.log.info("Initial state: {s}", .{sm.state()});

    // Dispatch events
    std.log.info("\\nDispatching 'start' event...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "start"));
    std.log.info("Current state: {s}", .{sm.state()});

    // Process a few times
    for (0..2) |i| {
        std.log.info("\\nDispatching 'process' event #{}", .{i + 1});
        try sm.dispatch(&context, hsm.Event.init(allocator, "process"));
        std.Thread.sleep(std.time.ns_per_ms * 200);
    }

    // Try to complete (should fail guard)
    std.log.info("\\nTrying to complete (should fail guard)...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "complete"));
    std.log.info("Still in state: {s}", .{sm.state()});

    // Process once more to satisfy guard
    std.log.info("\\nProcessing once more...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "process"));

    // Now complete should work
    std.log.info("\\nCompleting (should pass guard)...", .{});
    try sm.dispatch(&context, hsm.Event.init(allocator, "complete"));
    std.log.info("Final state: {s}", .{sm.state()});

    std.log.info("\\nBasic API Demo completed!", .{});
}
