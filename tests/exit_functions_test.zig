const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for tracking exit function calls
const ExitTestInstance = struct {
    base: hsm.Instance,
    exit_count: i32,
    exit_sequence: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .exit_count = 0,
            .exit_sequence = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.exit_sequence.deinit();
        self.base.deinit();
    }
    
    pub fn recordExit(self: *Self, name: []const u8) void {
        self.exit_count += 1;
        self.exit_sequence.append(name) catch unreachable;
    }
};

// Exit functions
fn firstExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("first");
}

fn secondExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("second");
}

fn cleanupExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("cleanup");
}

fn saveStateExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("save_state");
}

fn finalizeExit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("finalize");
}

test "Single exit function execution" {
    const model = comptime hsm.define("SingleExitTest", .{
        hsm.initial(hsm.target("state1")),
        hsm.state("state1", .{
            hsm.exit(firstExit),
            hsm.transition(.{ hsm.on("next"), hsm.target("state2") })
        }),
        hsm.state("state2", .{
            hsm.exit(secondExit),
            hsm.transition(.{ hsm.on("back"), hsm.target("state1") })
        })
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in state1, no exits yet
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state1"));
    try testing.expect(instance.exit_count == 0);
    
    // Transition to state2 - should call firstExit
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state2"));
    try testing.expect(instance.exit_count == 1);
    try testing.expectEqualStrings("first", instance.exit_sequence.items[0]);
    
    // Transition back to state1 - should call secondExit
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state1"));
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("second", instance.exit_sequence.items[1]);
}

test "Multiple exit functions execution order" {
    const model = comptime hsm.define("MultipleExitTest", .{
        hsm.initial(hsm.target("complex_state")),
        hsm.state("complex_state", .{
            hsm.exit(.{ saveStateExit, cleanupExit, finalizeExit }),
            hsm.transition(.{ hsm.on("shutdown"), hsm.target("simple_state") })
        }),
        hsm.state("simple_state", .{
            hsm.exit(.{ firstExit, secondExit }),
            hsm.transition(.{ hsm.on("restart"), hsm.target("complex_state") })
        })
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in complex_state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "complex_state"));
    try testing.expect(instance.exit_count == 0);
    
    // Transition to simple_state - should call all three exit functions in order
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "shutdown"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "simple_state"));
    try testing.expect(instance.exit_count == 3);
    try testing.expectEqualStrings("save_state", instance.exit_sequence.items[0]);
    try testing.expectEqualStrings("cleanup", instance.exit_sequence.items[1]);
    try testing.expectEqualStrings("finalize", instance.exit_sequence.items[2]);
    
    // Transition back - should call two exit functions in order
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "restart"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "complex_state"));
    try testing.expect(instance.exit_count == 5);
    try testing.expectEqualStrings("first", instance.exit_sequence.items[3]);
    try testing.expectEqualStrings("second", instance.exit_sequence.items[4]);
}

test "Exit functions with event data access" {
    var test_data: i32 = 99;
    
    const dataExit = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
            test_inst.recordExit("data_exit");
            
            // Try to access event data
            if (event.getData("exit_reason")) |data| {
                const value_ptr: *i32 = @ptrCast(@alignCast(data));
                if (value_ptr.* == 99) {
                    test_inst.recordExit("data_correct");
                }
            }
        }
    }.func;
    
    const model = comptime hsm.define("ExitDataTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.exit(dataExit),
            hsm.transition(.{ hsm.on("with_data"), hsm.target("end") })
        }),
        hsm.final("end")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Create event with data
    var event = hsm.Event.withData(testing.allocator, "with_data");
    defer event.deinit();
    try event.putData("exit_reason", &test_data);
    
    try sm.dispatch(&context, event);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("data_exit", instance.exit_sequence.items[0]);
    try testing.expectEqualStrings("data_correct", instance.exit_sequence.items[1]);
}

test "Exit functions in hierarchical states" {
    const model = comptime hsm.define("HierarchicalExitTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.exit(firstExit),
            hsm.initial(hsm.target("child")),
            hsm.state("child", .{
                hsm.exit(secondExit),
                hsm.transition(.{ hsm.on("up"), hsm.target("../../other") })
            })
        }),
        hsm.state("other", .{})
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in parent/child
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child"));
    try testing.expect(instance.exit_count == 0);
    
    // Transition out of hierarchy - should call both exit functions
    // child exit first, then parent exit
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "up"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "other"));
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("second", instance.exit_sequence.items[0]); // child exit
    try testing.expectEqualStrings("first", instance.exit_sequence.items[1]);  // parent exit
}

test "Exit functions with self transitions" {
    const model = comptime hsm.define("SelfTransitionExitTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.exit(firstExit),
            hsm.transition(.{ hsm.on("self"), hsm.target(".") }),
            hsm.transition(.{ hsm.on("next"), hsm.target("end") })
        }),
        hsm.final("end")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in start state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.exit_count == 0);
    
    // Self transition - should call exit function
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "self"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.exit_count == 1);
    try testing.expectEqualStrings("first", instance.exit_sequence.items[0]);
    
    // Regular transition - should call exit function again
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("first", instance.exit_sequence.items[1]);
}

test "Exit functions vs internal transitions" {
    const model = comptime hsm.define("InternalTransitionExitTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.exit(firstExit),
            hsm.transition(.{ hsm.on("internal"), hsm.effect(secondExit) }), // Internal transition (no target)
            hsm.transition(.{ hsm.on("external"), hsm.target("end") })
        }),
        hsm.final("end")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Should start in start state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.exit_count == 0);
    
    // Internal transition - should NOT call exit function
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "internal"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expect(instance.exit_count == 1); // Only the effect was called
    try testing.expectEqualStrings("second", instance.exit_sequence.items[0]); // Effect, not exit
    
    // External transition - should call exit function
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "external"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "end"));
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("first", instance.exit_sequence.items[1]); // Exit function
}

test "Exit functions with context cancellation" {
    const cancelCheckExit = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = event;
            const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
            
            if (ctx.is_done()) {
                test_inst.recordExit("cancelled");
            } else {
                test_inst.recordExit("normal");
            }
        }
    }.func;
    
    const model = comptime hsm.define("ExitCancellationTest", .{
        hsm.initial(hsm.target("start")),
        hsm.state("start", .{
            hsm.exit(cancelCheckExit),
            hsm.transition(.{ hsm.on("next"), hsm.target("middle") })
        }),
        hsm.state("middle", .{
            hsm.exit(cancelCheckExit),
            hsm.transition(.{ hsm.on("next"), hsm.target("end") })
        }),
        hsm.final("end")
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // First transition - normal exit
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    try testing.expect(instance.exit_count == 1);
    try testing.expectEqualStrings("normal", instance.exit_sequence.items[0]);
    
    // Cancel context and transition
    context.cancel();
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "next"));
    
    // Second exit should detect cancellation
    try testing.expect(instance.exit_count == 2);
    try testing.expectEqualStrings("cancelled", instance.exit_sequence.items[1]);
}

test "Exit functions state cleanup pattern" {
    var resource_counter: i32 = 0;
    
    const allocateResource = struct {
        var counter: *i32 = undefined;
        
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
            counter.* += 1;
            test_inst.recordExit("allocated");
        }
    }.func;
    
    const deallocateResource = struct {
        var counter: *i32 = undefined;
        
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            const test_inst: *ExitTestInstance = @ptrCast(@alignCast(inst));
            counter.* -= 1;
            test_inst.recordExit("deallocated");
        }
    }.func;
    
    allocateResource.counter = &resource_counter;
    deallocateResource.counter = &resource_counter;
    
    const model = comptime hsm.define("ResourceCleanupTest", .{
        hsm.initial(hsm.target("idle")),
        hsm.state("idle", .{
            hsm.transition(.{ hsm.on("acquire"), hsm.effect(allocateResource), hsm.target("holding") })
        }),
        hsm.state("holding", .{
            hsm.exit(.{ deallocateResource, finalizeExit }),
            hsm.transition(.{ hsm.on("release"), hsm.target("idle") })
        })
    });
    
    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);
    
    var context = hsm.Context.init(testing.allocator);
    var instance = ExitTestInstance.init(testing.allocator);
    defer instance.deinit();
    
    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();
    
    // Start in idle, acquire resource
    try testing.expect(resource_counter == 0);
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "acquire"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "holding"));
    try testing.expect(resource_counter == 1);
    try testing.expect(instance.exit_count == 1);
    try testing.expectEqualStrings("allocated", instance.exit_sequence.items[0]);
    
    // Release resource - should cleanup via exit functions
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "release"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "idle"));
    try testing.expect(resource_counter == 0); // Resource cleaned up
    try testing.expect(instance.exit_count == 3);
    try testing.expectEqualStrings("deallocated", instance.exit_sequence.items[1]);
    try testing.expectEqualStrings("finalize", instance.exit_sequence.items[2]);
}