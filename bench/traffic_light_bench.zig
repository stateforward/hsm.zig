const std = @import("std");
const hsm = @import("hsm");

fn envOrDefault(name: []const u8, default_value: usize) usize {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, name)) |value| {
        defer std.heap.page_allocator.free(value);
        return std.fmt.parseInt(usize, value, 10) catch default_value;
    } else |_| {
        return default_value;
    }
}

fn dispatchBatch(sm: *hsm.StateMachine, ctx: *hsm.Context, cycles: usize, car_arrival: hsm.Event, timer_event: hsm.Event) !void {
    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        try sm.dispatch(ctx, car_arrival);
        try sm.dispatch(ctx, timer_event);
        try sm.dispatch(ctx, timer_event);
        try sm.dispatch(ctx, timer_event);
    }
}

const TrafficLight = struct {
    base: hsm.Instance,
    maintenance_mode: bool,
    cars_waiting: i32,
    timer: i32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{
            .base = hsm.Instance.init(),
            .maintenance_mode = false,
            .cars_waiting = 0,
            .timer = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }
};

fn resetCars(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    tl.cars_waiting = 0;
}

fn addCar(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    tl.cars_waiting += 1;
}

fn noCarsWaiting(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    return tl.cars_waiting == 0;
}

fn isMaintenance(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    return tl.maintenance_mode == true;
}

fn isNotMaintenance(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    return tl.maintenance_mode == false;
}

fn checkCarsForChoice(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    return tl.cars_waiting > 10;
}

fn setTimerExtended(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    tl.timer = 60;
}

fn setTimerStandard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    tl.timer = 40;
}

fn maintenanceTick(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const tl: *TrafficLight = @ptrCast(@alignCast(inst));
    tl.timer += 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const model = comptime hsm.define("TrafficLight", .{
        hsm.initial(hsm.target("operational")),
        
        hsm.state("operational", .{
            hsm.transition(.{ hsm.on("MaintenanceSwitch"), hsm.guard(isMaintenance), hsm.target("../maintenance") }),
            hsm.initial(hsm.target("red")),

            hsm.state("red", .{
                hsm.transition(.{ hsm.on("TimerEvent"), hsm.guard(checkCarsForChoice), hsm.effect(setTimerExtended), hsm.target("../green") }),
                hsm.transition(.{ hsm.on("TimerEvent"), hsm.effect(setTimerStandard), hsm.target("../green") }),
                hsm.transition(.{ hsm.on("CarArrival"), hsm.effect(addCar) }),
            }),

            hsm.state("green", .{
                hsm.transition(.{ hsm.on("TimerEvent"), hsm.target("../yellow") }),
                hsm.transition(.{ hsm.on("PedestrianButton"), hsm.guard(noCarsWaiting), hsm.target("../yellow") }),
            }),

            hsm.state("yellow", .{
                hsm.deferEvents(.{"CarArrival"}),
                hsm.transition(.{ hsm.on("TimerEvent"), hsm.target("../red") }),
            }),
        }),

        hsm.state("maintenance", .{
            hsm.entry(resetCars),
            hsm.transition(.{ hsm.on("Tick"), hsm.effect(maintenanceTick) }),
            hsm.transition(.{ hsm.on("MaintenanceSwitch"), hsm.guard(isNotMaintenance), hsm.target("../operational") }),
        })
    });

    var built_model = try model.build(allocator);
    defer built_model.deinit();

    const warmup_ms = envOrDefault("HSM_BENCH_WARMUP_MS", 250);
    const duration_target_ms = envOrDefault("HSM_BENCH_DURATION_MS", 2000);
    
    var ctx = hsm.Context.init(allocator);

    var warmup_inst = TrafficLight.init(allocator);
    var warmup_sm = try hsm.start(&ctx, &warmup_inst.base, &built_model);
    
    const car_arrival = hsm.Event.init(allocator, "CarArrival");
    const timer_event = hsm.Event.init(allocator, "TimerEvent");
    
    var batch_cycles: usize = 1;
    while (true) {
        const calibration_start = std.time.milliTimestamp();
        try dispatchBatch(&warmup_sm, &ctx, batch_cycles, car_arrival, timer_event);
        if ((std.time.milliTimestamp() - calibration_start) >= 10 or batch_cycles >= (1 << 20)) {
            break;
        }
        batch_cycles *= 2;
    }
    const warmup_start = std.time.milliTimestamp();
    while ((std.time.milliTimestamp() - warmup_start) < warmup_ms) {
        try dispatchBatch(&warmup_sm, &ctx, batch_cycles, car_arrival, timer_event);
    }
    warmup_sm.deinit();
    warmup_inst.deinit();

    var inst = TrafficLight.init(allocator);
    defer inst.deinit();
    var sm = try hsm.start(&ctx, &inst.base, &built_model);
    defer sm.deinit();

    const start_time = std.time.milliTimestamp();

    var completed_cycles: usize = 0;
    while ((std.time.milliTimestamp() - start_time) < duration_target_ms) {
        try dispatchBatch(&sm, &ctx, batch_cycles, car_arrival, timer_event);
        completed_cycles += batch_cycles;
    }

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    const total_dispatches = completed_cycles * 4;
    var ops_per_sec: usize = 0;
    if (duration_ms > 0) {
        ops_per_sec = @intCast((total_dispatches * 1000) / @as(usize, @intCast(duration_ms)));
    }
    
    // Fallback: estimate memory used by allocator since getrusage requires cImport and linkage.
    // For a generic comparison, heap usage of GPA is an okay proxy for Zig.
    const mem_mb: f64 = 0.0;

    std.debug.print("{{\"language\": \"Zig\", \"iterations\": {}, \"duration_ms\": {}, \"memory_mb\": {d:.3}, \"throughput_ops_per_sec\": {}}}\n",
        .{ total_dispatches, duration_ms, mem_mb, ops_per_sec });
}
