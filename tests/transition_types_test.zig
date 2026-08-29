const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for transition type testing
const TransitionTestInstance = struct {
    base: hsm.Instance,
    transition_count: i32,
    transition_sequence: std.ArrayList([]const u8),
    entry_count: i32,
    exit_count: i32,
    effect_count: i32,
    entry_sequence: std.ArrayList([]const u8),
    exit_sequence: std.ArrayList([]const u8),
    effect_sequence: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .transition_count = 0,
            .transition_sequence = .{},
            .entry_count = 0,
            .exit_count = 0,
            .effect_count = 0,
            .entry_sequence = .{},
            .exit_sequence = .{},
            .effect_sequence = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.transition_sequence.deinit(self.allocator);
        self.entry_sequence.deinit(self.allocator);
        self.exit_sequence.deinit(self.allocator);
        self.effect_sequence.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordTransition(self: *Self, name: []const u8) void {
        self.transition_count += 1;
        self.transition_sequence.append(self.allocator, name) catch unreachable;
    }

    pub fn recordEntry(self: *Self, name: []const u8) void {
        self.entry_count += 1;
        self.entry_sequence.append(self.allocator, name) catch unreachable;
    }

    pub fn recordExit(self: *Self, name: []const u8) void {
        self.exit_count += 1;
        self.exit_sequence.append(self.allocator, name) catch unreachable;
    }

    pub fn recordEffect(self: *Self, name: []const u8) void {
        self.effect_count += 1;
        self.effect_sequence.append(self.allocator, name) catch unreachable;
    }
};

// Entry/Exit functions for tracking
fn entryA(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("A");
}

fn exitA(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("A");
}

fn entryB(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("B");
}

fn exitB(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("B");
}

fn entryParent(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("Parent");
}

fn exitParent(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("Parent");
}

fn entryChild(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("Child");
}

fn exitChild(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("Child");
}

// Effect functions
fn effectExternal(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEffect("external");
}

fn effectInternal(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEffect("internal");
}

fn effectSelf(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEffect("self");
}

fn effectLocal(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEffect("local");
}

test "External transitions with entry/exit actions" {
    const model = comptime hsm.define("ExternalTransitionTest", .{ hsm.initial(hsm.target("state_a")), hsm.state("state_a", .{ hsm.entry(entryA), hsm.exit(exitA), hsm.transition(.{ hsm.on("go_to_b"), hsm.effect(effectExternal), hsm.target("../state_b") }) }), hsm.state("state_b", .{ hsm.entry(entryB), hsm.exit(exitB), hsm.transition(.{ hsm.on("go_to_a"), hsm.effect(effectExternal), hsm.target("../state_a") }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in state_a
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state_a"));
    try testing.expect(instance.entry_count == 1);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[0]);

    // External transition to state_b
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "go_to_b"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state_b"));

    // Should have: exit A, effect, entry B
    try testing.expect(instance.exit_count == 1);
    try testing.expect(instance.effect_count == 1);
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("A", instance.exit_sequence.items[0]);
    try testing.expectEqualStrings("external", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("B", instance.entry_sequence.items[1]);

    // External transition back to state_a
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "go_to_a"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state_a"));

    // Should have: exit B, effect, entry A
    try testing.expect(instance.exit_count == 2);
    try testing.expect(instance.effect_count == 2);
    try testing.expect(instance.entry_count == 3);
    try testing.expectEqualStrings("B", instance.exit_sequence.items[1]);
    try testing.expectEqualStrings("external", instance.effect_sequence.items[1]);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[2]);
}

test "Internal transitions without state changes" {
    const model = comptime hsm.define("InternalTransitionTest", .{
        hsm.initial(hsm.target("processor")),
        hsm.state("processor", .{
            hsm.entry(entryA),
            hsm.exit(exitA),
            hsm.transition(.{ hsm.on("process"), hsm.effect(effectInternal) }), // Internal - no target
            hsm.transition(.{ hsm.on("finish"), hsm.target("../done") }),
        }),
        hsm.state("done", .{hsm.entry(entryB)}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in processor
    try testing.expect(std.mem.endsWith(u8, sm.state(), "processor"));
    try testing.expect(instance.entry_count == 1);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[0]);

    // Internal transition - should only execute effect, no entry/exit
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "processor")); // Still in same state
    try testing.expect(instance.exit_count == 0); // No exit
    try testing.expect(instance.effect_count == 1); // Effect executed
    try testing.expect(instance.entry_count == 1); // No additional entry
    try testing.expectEqualStrings("internal", instance.effect_sequence.items[0]);

    // Multiple internal transitions
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "process"));

    try testing.expect(std.mem.endsWith(u8, sm.state(), "processor"));
    try testing.expect(instance.exit_count == 0); // Still no exits
    try testing.expect(instance.effect_count == 3); // 3 effects executed
    try testing.expect(instance.entry_count == 1); // Still only initial entry

    // External transition to finish
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "finish"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "done"));
    try testing.expect(instance.exit_count == 1); // Exit A
    try testing.expect(instance.entry_count == 2); // Entry B
    try testing.expectEqualStrings("A", instance.exit_sequence.items[0]);
    try testing.expectEqualStrings("B", instance.entry_sequence.items[1]);
}

test "Self transitions with exit and re-entry" {
    const model = comptime hsm.define("SelfTransitionTest", .{
        hsm.initial(hsm.target("resettable")),
        hsm.state("resettable", .{
            hsm.entry(entryA),
            hsm.exit(exitA),
            hsm.transition(.{ hsm.on("reset"), hsm.effect(effectSelf), hsm.target(".") }), // Self transition
            hsm.transition(.{ hsm.on("leave"), hsm.target("../other") }),
        }),
        hsm.state("other", .{hsm.entry(entryB)}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in resettable
    try testing.expect(std.mem.endsWith(u8, sm.state(), "resettable"));
    try testing.expect(instance.entry_count == 1);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[0]);

    // Self transition - should exit and re-enter same state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "resettable")); // Still in same state

    // Should have: exit A, effect, entry A
    try testing.expect(instance.exit_count == 1);
    try testing.expect(instance.effect_count == 1);
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("A", instance.exit_sequence.items[0]);
    try testing.expectEqualStrings("self", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[1]);

    // Multiple self transitions
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset"));
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset"));

    try testing.expect(std.mem.endsWith(u8, sm.state(), "resettable"));
    try testing.expect(instance.exit_count == 3); // 3 exits
    try testing.expect(instance.effect_count == 3); // 3 effects
    try testing.expect(instance.entry_count == 4); // 1 initial + 3 re-entries

    // Verify all are for state A
    for (instance.exit_sequence.items) |exit_name| {
        try testing.expectEqualStrings("A", exit_name);
    }
    for (instance.entry_sequence.items) |entry_name| {
        try testing.expectEqualStrings("A", entry_name);
    }
    for (instance.effect_sequence.items) |effect_name| {
        try testing.expectEqualStrings("self", effect_name);
    }
}

test "Local transitions to child states" {
    const model = comptime hsm.define("LocalTransitionTest", .{
        hsm.initial(hsm.target("parent")),
        hsm.state("parent", .{
            hsm.entry(entryParent),
            hsm.exit(exitParent),
            hsm.initial(hsm.target("child_a")),
            hsm.transition(.{ hsm.on("dive"), hsm.effect(effectLocal), hsm.target("child_b") }), // Local to child
            hsm.transition(.{ hsm.on("leave"), hsm.target("../external") }),
            hsm.state("child_a", .{ hsm.entry(entryA), hsm.exit(exitA), hsm.transition(.{ hsm.on("switch"), hsm.target("../child_b") }) }),
            hsm.state("child_b", .{ hsm.entry(entryB), hsm.exit(exitB), hsm.transition(.{ hsm.on("switch"), hsm.target("../child_a") }) }),
        }),
        hsm.state("external", .{hsm.entry(entryChild)}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in parent/child_a
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child_a"));
    try testing.expect(instance.entry_count == 2);
    try testing.expectEqualStrings("Parent", instance.entry_sequence.items[0]);
    try testing.expectEqualStrings("A", instance.entry_sequence.items[1]);

    // Local transition from parent to child_b
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "dive"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child_b"));

    // Parent should not exit/re-enter (local transition)
    // child_a should exit, child_b should enter
    try testing.expect(instance.exit_count == 1); // Only child_a exit
    try testing.expect(instance.effect_count == 1);
    try testing.expect(instance.entry_count == 3); // Parent, child_a, child_b
    try testing.expectEqualStrings("A", instance.exit_sequence.items[0]); // child_a exit
    try testing.expectEqualStrings("local", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("B", instance.entry_sequence.items[2]); // child_b entry

    // Transition between siblings (also local within parent)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "switch"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "child_a"));

    // Should exit child_b and enter child_a, parent unchanged
    try testing.expect(instance.exit_count == 2);
    try testing.expect(instance.entry_count == 4);
    try testing.expectEqualStrings("B", instance.exit_sequence.items[1]); // child_b exit
    try testing.expectEqualStrings("A", instance.entry_sequence.items[3]); // child_a entry

    // External transition - should exit both child and parent
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "leave"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "external"));

    // Should exit child_a and parent
    try testing.expect(instance.exit_count == 4);
    try testing.expect(instance.entry_count == 5);
    try testing.expectEqualStrings("A", instance.exit_sequence.items[2]); // child_a exit
    try testing.expectEqualStrings("Parent", instance.exit_sequence.items[3]); // parent exit
    try testing.expectEqualStrings("Child", instance.entry_sequence.items[4]); // external entry
}

test "Hierarchical transitions with ancestor preservation" {
    const model = comptime hsm.define("HierarchicalTransitionTest", .{ hsm.initial(hsm.target("root")), hsm.state("root", .{ hsm.entry(entryParent), hsm.exit(exitParent), hsm.initial(hsm.target("branch_a")), hsm.state("branch_a", .{ hsm.entry(entryA), hsm.exit(exitA), hsm.initial(hsm.target("leaf_a1")), hsm.state("leaf_a1", .{ hsm.entry(entryChild), hsm.exit(exitChild), hsm.transition(.{ hsm.on("to_a2"), hsm.target("../leaf_a2") }), hsm.transition(.{ hsm.on("to_b"), hsm.target("../../branch_b/leaf_b1") }) }), hsm.state("leaf_a2", .{ hsm.entry(entryB), hsm.exit(exitB) }) }), hsm.state("branch_b", .{ hsm.entry(entryChild), hsm.exit(exitChild), hsm.state("leaf_b1", .{ hsm.entry(entryA), hsm.exit(exitA) }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in root/branch_a/leaf_a1
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a1"));
    try testing.expect(instance.entry_count == 3);
    try testing.expectEqualStrings("Parent", instance.entry_sequence.items[0]); // root
    try testing.expectEqualStrings("A", instance.entry_sequence.items[1]); // branch_a
    try testing.expectEqualStrings("Child", instance.entry_sequence.items[2]); // leaf_a1

    // Transition within branch_a (ancestor preservation)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_a2"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a2"));

    // Should exit leaf_a1, enter leaf_a2, preserve root and branch_a
    try testing.expect(instance.exit_count == 1);
    try testing.expect(instance.entry_count == 4);
    try testing.expectEqualStrings("Child", instance.exit_sequence.items[0]); // leaf_a1 exit
    try testing.expectEqualStrings("B", instance.entry_sequence.items[3]); // leaf_a2 entry

    // Reset to leaf_a1 for cross-branch test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = TransitionTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Cross-branch transition (should exit down to common ancestor)
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "to_b"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "leaf_b1"));

    // Should exit: leaf_a1, branch_a, then enter: branch_b, leaf_b1
    // Root should be preserved (common ancestor)
    try testing.expect(instance2.exit_count == 2);
    try testing.expect(instance2.entry_count == 5); // root, branch_a, leaf_a1, branch_b, leaf_b1
    try testing.expectEqualStrings("Child", instance2.exit_sequence.items[0]); // leaf_a1
    try testing.expectEqualStrings("A", instance2.exit_sequence.items[1]); // branch_a
    try testing.expectEqualStrings("Child", instance2.entry_sequence.items[3]); // branch_b
    try testing.expectEqualStrings("A", instance2.entry_sequence.items[4]); // leaf_b1
}

test "Transition types with multiple effects and complex paths" {
    var counter: i32 = 0;

    const CounterEffect = struct {
        var count: *i32 = undefined;
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
            _ = ctx;
            _ = event;
            const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
            count.* += 1;
            test_inst.recordEffect("counter");
        }
    };

    CounterEffect.count = &counter;

    const model = comptime hsm.define("ComplexTransitionTest", .{
        hsm.initial(hsm.target("multi_state")),
        hsm.state("multi_state", .{
            hsm.entry(entryA),
            hsm.exit(exitA),
            // Internal with multiple effects
            hsm.transition(.{ hsm.on("internal"), hsm.effect(.{ effectInternal, CounterEffect.func, effectInternal }) }),
            // Self with multiple effects
            hsm.transition(.{ hsm.on("self"), hsm.effect(.{ effectSelf, CounterEffect.func, effectSelf }), hsm.target(".") }),
            // External with multiple effects
            hsm.transition(.{ hsm.on("external"), hsm.effect(.{ effectExternal, CounterEffect.func, effectExternal }), hsm.target("../other_state") }),
        }),
        hsm.state("other_state", .{ hsm.entry(entryB), hsm.exit(exitB), hsm.transition(.{ hsm.on("back"), hsm.target("../multi_state") }) }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Test internal transition with multiple effects
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "internal"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "multi_state"));
    try testing.expect(instance.exit_count == 0); // No exit for internal
    try testing.expect(instance.effect_count == 3); // 3 effects executed
    try testing.expect(counter == 1);
    try testing.expectEqualStrings("internal", instance.effect_sequence.items[0]);
    try testing.expectEqualStrings("counter", instance.effect_sequence.items[1]);
    try testing.expectEqualStrings("internal", instance.effect_sequence.items[2]);

    // Test self transition with multiple effects
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "self"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "multi_state"));
    try testing.expect(instance.exit_count == 1); // Exit for self transition
    try testing.expect(instance.entry_count == 2); // Re-entry for self transition
    try testing.expect(instance.effect_count == 6); // 3 more effects
    try testing.expect(counter == 2);

    // Test external transition with multiple effects
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "external"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "other_state"));
    try testing.expect(instance.exit_count == 2); // Exit multi_state
    try testing.expect(instance.entry_count == 3); // Enter other_state
    try testing.expect(instance.effect_count == 9); // 3 more effects
    try testing.expect(counter == 3);

    // Verify effect execution order for external transition
    try testing.expectEqualStrings("external", instance.effect_sequence.items[6]);
    try testing.expectEqualStrings("counter", instance.effect_sequence.items[7]);
    try testing.expectEqualStrings("external", instance.effect_sequence.items[8]);
}

test "Transition type combinations with guards and timers" {
    const fastGuard = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
            _ = ctx;
            _ = event;
            const test_inst: *TransitionTestInstance = @ptrCast(@alignCast(inst));
            return test_inst.transition_count < 3;
        }
    }.func;

    const shortTimer = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
            _ = ctx;
            _ = inst;
            _ = event;
            return std.time.ns_per_ms * 50; // 50ms
        }
    }.func;

    const model = comptime hsm.define("GuardedTransitionTest", .{
        hsm.initial(hsm.target("guarded_state")),
        hsm.state("guarded_state", .{
            hsm.entry(entryA),
            hsm.exit(exitA),
            // Guarded internal transition
            hsm.transition(.{ hsm.on("try"), hsm.guard(fastGuard), hsm.effect(effectInternal) }),
            // Timer-based self transition
            hsm.transition(.{ hsm.after(shortTimer), hsm.effect(effectSelf), hsm.target(".") }),
            // Fallback external transition
            hsm.transition(.{ hsm.on("try"), hsm.effect(effectExternal), hsm.target("../fallback") }),
        }),
        hsm.state("fallback", .{hsm.entry(entryB)}),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = TransitionTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // First few tries should use guarded internal transition
    for (0..3) |_| {
        try sm.dispatch(&context, hsm.Event.init(testing.allocator, "try"));
        try testing.expect(std.mem.endsWith(u8, sm.state(), "guarded_state"));
        instance.recordTransition("try");
    }

    try testing.expect(instance.effect_count == 3);
    try testing.expect(instance.exit_count == 0); // All internal

    // Next try should fail guard and use fallback external transition
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "try"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "fallback"));
    try testing.expect(instance.effect_count == 4);
    try testing.expect(instance.exit_count == 1); // External transition
    try testing.expect(instance.entry_count == 2); // fallback entry
}
