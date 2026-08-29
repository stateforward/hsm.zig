const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for hierarchical state testing
const HierarchicalTestInstance = struct {
    base: hsm.Instance,
    depth_level: i32,
    state_path: std.ArrayList([]const u8),
    entry_depth: i32,
    exit_depth: i32,
    max_depth_reached: i32,
    transition_count: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .depth_level = 0,
            .state_path = .{},
            .entry_depth = 0,
            .exit_depth = 0,
            .max_depth_reached = 0,
            .transition_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.state_path.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordEntry(self: *Self, state_name: []const u8, depth: i32) void {
        self.depth_level = depth;
        self.entry_depth += 1;
        if (depth > self.max_depth_reached) {
            self.max_depth_reached = depth;
        }
        self.state_path.append(self.allocator, state_name) catch unreachable;
    }

    pub fn recordExit(self: *Self, state_name: []const u8, depth: i32) void {
        _ = state_name;
        self.depth_level = depth;
        self.exit_depth += 1;
    }

    pub fn incrementTransition(self: *Self) void {
        self.transition_count += 1;
    }
};

// Entry/Exit functions with depth tracking
fn level1Entry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("level1", 1);
}

fn level1Exit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("level1", 1);
}

fn level2Entry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("level2", 2);
}

fn level2Exit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("level2", 2);
}

fn level3Entry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("level3", 3);
}

fn level3Exit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("level3", 3);
}

fn level4Entry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordEntry("level4", 4);
}

fn level4Exit(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordExit("level4", 4);
}

fn transitionEffect(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
    test_inst.incrementTransition();
}

test "Deep nested hierarchy initialization" {
    const model = comptime hsm.define("DeepHierarchyTest", .{ hsm.initial(hsm.target("level1")), hsm.state("level1", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.initial(hsm.target("level2")), hsm.state("level2", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.initial(hsm.target("level3")), hsm.state("level3", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.initial(hsm.target("level4")), hsm.state("level4", .{ hsm.entry(level4Entry), hsm.exit(level4Exit) }) }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should initialize all levels down to level4
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level4"));
    try testing.expect(instance.entry_depth == 4);
    try testing.expect(instance.max_depth_reached == 4);

    // Verify entry sequence
    try testing.expectEqualStrings("level1", instance.state_path.items[0]);
    try testing.expectEqualStrings("level2", instance.state_path.items[1]);
    try testing.expectEqualStrings("level3", instance.state_path.items[2]);
    try testing.expectEqualStrings("level4", instance.state_path.items[3]);
}

test "Multi-branch hierarchy with sibling navigation" {
    const model = comptime hsm.define("MultiBranchTest", .{ hsm.initial(hsm.target("main")), hsm.state("main", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.initial(hsm.target("branch_a")), hsm.state("branch_a", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.initial(hsm.target("leaf_a1")), hsm.state("leaf_a1", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.transition(.{ hsm.on("to_a2"), hsm.effect(transitionEffect), hsm.target("../leaf_a2") }), hsm.transition(.{ hsm.on("to_b"), hsm.effect(transitionEffect), hsm.target("../../branch_b/leaf_b1") }) }), hsm.state("leaf_a2", .{ hsm.entry(level4Entry), hsm.exit(level4Exit), hsm.transition(.{ hsm.on("to_a1"), hsm.effect(transitionEffect), hsm.target("../leaf_a1") }) }) }), hsm.state("branch_b", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.state("leaf_b1", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.transition(.{ hsm.on("to_a"), hsm.effect(transitionEffect), hsm.target("../../branch_a/leaf_a1") }) }) }) }), hsm.state("other_root", .{ hsm.entry(level1Entry), hsm.exit(level1Exit) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in main/branch_a/leaf_a1
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a1"));
    try testing.expect(instance.entry_depth == 3);

    // Transition within branch_a (sibling transition)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_a2"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a2"));
    try testing.expect(instance.transition_count == 1);
    try testing.expect(instance.exit_depth == 1); // Only leaf_a1 exits
    try testing.expect(instance.entry_depth == 4); // leaf_a2 enters

    // Transition back to a1
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_a1"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a1"));
    try testing.expect(instance.transition_count == 2);

    // Cross-branch transition
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_b"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_b1"));
    try testing.expect(instance.transition_count == 3);
    // Should exit leaf_a1 and branch_a, then enter branch_b and leaf_b1
    try testing.expect(instance.exit_depth >= 3);
    try testing.expect(instance.entry_depth >= 6);

    // Transition back across branches
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_a"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "leaf_a1"));
    try testing.expect(instance.transition_count == 4);
}

test "Hierarchical states with overlapping names" {
    const model = comptime hsm.define("OverlappingNamesTest", .{ hsm.initial(hsm.target("container_a")), hsm.state("container_a", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.initial(hsm.target("state")), hsm.state("state", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.transition(.{ hsm.on("to_b"), hsm.effect(transitionEffect), hsm.target("../../container_b/state") }) }) }), hsm.state("container_b", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.state("state", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.transition(.{ hsm.on("to_a"), hsm.effect(transitionEffect), hsm.target("../../container_a/state") }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in container_a/state
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container_a") != null);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));

    // Transition to container_b/state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_b"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container_b") != null);
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(instance.transition_count == 1);

    // Should have exited container_a and its state, entered container_b and its state
    try testing.expect(instance.exit_depth == 2);
    try testing.expect(instance.entry_depth == 4); // 2 initial + 2 transition

    // Transition back
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_a"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container_a") != null);
    try testing.expect(instance.transition_count == 2);
}

test "Complex hierarchy with choice states and guards" {
    const depthGuard = struct {
        fn func(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
            _ = ctx;
            _ = event;
            const test_inst: *HierarchicalTestInstance = @ptrCast(@alignCast(inst));
            return test_inst.depth_level >= 3;
        }
    }.func;

    const model = comptime hsm.define("ComplexHierarchyTest", .{ hsm.initial(hsm.target("root")), hsm.state("root", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.initial(hsm.target("intermediate")), hsm.state("intermediate", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.initial(hsm.target("deep")), hsm.state("deep", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.transition(.{ hsm.on("navigate"), hsm.target("../decision") }) }), hsm.choice("decision", .{ hsm.transition(.{ hsm.guard(depthGuard), hsm.effect(transitionEffect), hsm.target("../../shallow") }), hsm.transition(.{ hsm.effect(transitionEffect), hsm.target("../deep") }) }) }), hsm.state("shallow", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.transition(.{ hsm.on("go_deep"), hsm.effect(transitionEffect), hsm.target("../intermediate/deep") }) }) }), hsm.state("shallow", .{ hsm.entry(level1Entry), hsm.exit(level1Exit) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in root/intermediate/deep (depth 3)
    try testing.expect(std.mem.endsWith(u8, sm.state(), "deep"));
    try testing.expect(instance.depth_level == 3);

    // Navigate to choice - should take first guard (depth >= 3)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "navigate"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "shallow"));
    try testing.expect(instance.transition_count == 1);

    // Should have exited deep and intermediate but stayed in root, then entered shallow
    try testing.expect(instance.exit_depth == 2);
    try testing.expect(instance.entry_depth == 4); // root, intermediate, deep, shallow
}

test "Hierarchy with multiple initial transitions at different levels" {
    const model = comptime hsm.define("MultiInitialTest", .{
        hsm.initial(hsm.target("workspace")),
        hsm.state("workspace", .{
            hsm.entry(level1Entry),
            hsm.exit(level1Exit),
            hsm.initial(hsm.target("main_panel")),
            hsm.state("main_panel", .{
                hsm.entry(level2Entry),
                hsm.exit(level2Exit),
                hsm.initial(hsm.target("editor/document")), // Path to nested state
                hsm.state("editor", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.state("document", .{ hsm.entry(level4Entry), hsm.exit(level4Exit), hsm.transition(.{ hsm.on("switch_panel"), hsm.target("../../../side_panel/tool") }) }) }),
            }),
            hsm.state("side_panel", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.initial(hsm.target("tool")), hsm.state("tool", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.transition(.{ hsm.on("switch_back"), hsm.target("../../main_panel/editor/document") }) }) }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should follow initial path to workspace/main_panel/editor/document
    try testing.expect(std.mem.endsWith(u8, sm.state(), "document"));
    try testing.expect(instance.entry_depth == 4);
    try testing.expect(instance.max_depth_reached == 4);

    // Verify correct initialization sequence
    try testing.expectEqualStrings("level1", instance.state_path.items[0]); // workspace
    try testing.expectEqualStrings("level2", instance.state_path.items[1]); // main_panel
    try testing.expectEqualStrings("level3", instance.state_path.items[2]); // editor
    try testing.expectEqualStrings("level4", instance.state_path.items[3]); // document

    // Switch to side panel
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "switch_panel"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "tool"));

    // Should exit document and editor, then enter side_panel and tool
    try testing.expect(instance.exit_depth == 3);
    try testing.expect(instance.entry_depth == 6); // 4 initial + 2 new

    // Switch back
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "switch_back"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "document"));
}

test "Deep hierarchy with self-transitions and internal events" {
    const model = comptime hsm.define("SelfTransitionHierarchyTest", .{
        hsm.initial(hsm.target("outer")),
        hsm.state("outer", .{
            hsm.entry(level1Entry),
            hsm.exit(level1Exit),
            hsm.initial(hsm.target("middle")),
            hsm.transition(.{ hsm.on("reset_outer"), hsm.effect(transitionEffect), hsm.target(".") }), // Self transition
            hsm.state("middle", .{
                hsm.entry(level2Entry),
                hsm.exit(level2Exit),
                hsm.initial(hsm.target("inner")),
                hsm.transition(.{ hsm.on("reset_middle"), hsm.effect(transitionEffect), hsm.target(".") }), // Self transition
                hsm.transition(.{ hsm.on("internal"), hsm.effect(transitionEffect) }), // Internal transition
                hsm.state("inner", .{
                    hsm.entry(level3Entry),
                    hsm.exit(level3Exit),
                    hsm.transition(.{ hsm.on("reset_inner"), hsm.effect(transitionEffect), hsm.target(".") }), // Self transition
                }),
            }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in outer/middle/inner
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expect(instance.entry_depth == 3);

    // Self transition at inner level
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_inner"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expect(instance.transition_count == 1);
    try testing.expect(instance.exit_depth == 1); // Only inner exits
    try testing.expect(instance.entry_depth == 4); // Inner re-enters

    // Self transition at middle level (should re-enter middle and inner)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_middle"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expect(instance.transition_count == 2);
    try testing.expect(instance.exit_depth == 3); // inner and middle exit
    try testing.expect(instance.entry_depth == 6); // middle and inner re-enter

    // Internal transition at middle level (no state changes)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "internal"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expect(instance.transition_count == 3);
    try testing.expect(instance.exit_depth == 3); // No additional exits
    try testing.expect(instance.entry_depth == 6); // No additional entries

    // Self transition at outer level (should re-enter entire hierarchy)
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_outer"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expect(instance.transition_count == 4);
    try testing.expect(instance.exit_depth == 6); // All three levels exit
    try testing.expect(instance.entry_depth == 9); // All three levels re-enter
}

test "Maximum depth hierarchy stress test" {
    const model = comptime hsm.define("MaxDepthTest", .{ hsm.initial(hsm.target("d1")), hsm.state("d1", .{ hsm.entry(level1Entry), hsm.exit(level1Exit), hsm.initial(hsm.target("d2")), hsm.transition(.{ hsm.on("escape"), hsm.effect(transitionEffect), hsm.target("../escape") }), hsm.state("d2", .{ hsm.entry(level2Entry), hsm.exit(level2Exit), hsm.initial(hsm.target("d3")), hsm.state("d3", .{ hsm.entry(level3Entry), hsm.exit(level3Exit), hsm.initial(hsm.target("d4")), hsm.state("d4", .{ hsm.entry(level4Entry), hsm.exit(level4Exit), hsm.transition(.{ hsm.on("bubble_up"), hsm.effect(transitionEffect), hsm.target("../../../../escape") }) }) }) }) }), hsm.state("escape", .{ hsm.entry(level1Entry), hsm.exit(level1Exit) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = HierarchicalTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start at maximum depth
    try testing.expect(std.mem.endsWith(u8, sm.state(), "d4"));
    try testing.expect(instance.max_depth_reached == 4);
    try testing.expect(instance.entry_depth == 4);

    // Bubble up from deepest level
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "bubble_up"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "escape"));
    try testing.expect(instance.transition_count == 1);

    // Should have exited all 4 levels and entered escape
    try testing.expect(instance.exit_depth == 4);
    try testing.expect(instance.entry_depth == 5);
}
