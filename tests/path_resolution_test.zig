const std = @import("std");
const testing = std.testing;
const hsm = @import("hsm");

// Test instance for path resolution testing
const PathTestInstance = struct {
    base: hsm.Instance,
    navigation_history: std.ArrayList([]const u8),
    current_path: []const u8,
    resolution_count: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .base = hsm.Instance.init(),
            .navigation_history = .{},
            .current_path = "none",
            .resolution_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.navigation_history.items) |navigation| self.allocator.free(navigation);
        self.navigation_history.deinit(self.allocator);
        self.base.deinit();
    }

    pub fn recordNavigation(self: *Self, from: []const u8, to: []const u8) void {
        const navigation = std.fmt.allocPrint(self.allocator, "{s}->{s}", .{ from, to }) catch unreachable;
        self.navigation_history.append(self.allocator, navigation) catch unreachable;
        self.current_path = to;
        self.resolution_count += 1;
    }

    pub fn setCurrentPath(self: *Self, path: []const u8) void {
        self.current_path = path;
    }
};

// Entry functions to track path resolution
fn absoluteEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("absolute");
}

fn relativeEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("relative");
}

fn parentEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("parent");
}

fn childEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("child");
}

fn siblingEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("sibling");
}

fn deepEntry(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.setCurrentPath("deep");
}

// Effects to track navigation
fn recordAbsoluteNav(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordNavigation("source", "absolute_target");
}

fn recordRelativeNav(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordNavigation("source", "relative_target");
}

fn recordParentNav(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordNavigation("source", "parent_target");
}

fn recordSelfNav(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx;
    _ = event;
    const test_inst: *PathTestInstance = @ptrCast(@alignCast(inst));
    test_inst.recordNavigation("source", "self_target");
}

test "Absolute path resolution" {
    const model = comptime hsm.define("AbsolutePathTest", .{ hsm.initial(hsm.target("container")), hsm.state("container", .{ hsm.entry(parentEntry), hsm.initial(hsm.target("start")), hsm.state("start", .{ hsm.entry(childEntry), hsm.transition(.{ hsm.on("go_absolute"), hsm.effect(recordAbsoluteNav), hsm.target("/AbsolutePathTest/other/target") }) }), hsm.state("nested", .{ hsm.entry(siblingEntry), hsm.state("deep", .{ hsm.entry(deepEntry), hsm.transition(.{ hsm.on("go_root"), hsm.target("/AbsolutePathTest/container/start") }) }) }) }), hsm.state("other", .{ hsm.entry(relativeEntry), hsm.state("target", .{ hsm.entry(absoluteEntry), hsm.transition(.{ hsm.on("go_deep"), hsm.target("/AbsolutePathTest/container/nested/deep") }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in container/start
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expectEqualStrings("child", instance.current_path);

    // Absolute path transition
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "go_absolute"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "target"));
    try testing.expectEqualStrings("absolute", instance.current_path);
    try testing.expect(instance.resolution_count == 1);
    try testing.expect(std.mem.endsWith(u8, instance.navigation_history.items[0], "absolute_target"));

    // Another absolute path from nested location
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "go_deep"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "deep"));
    try testing.expectEqualStrings("deep", instance.current_path);

    // Absolute path back to start
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "go_root"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "start"));
    try testing.expectEqualStrings("child", instance.current_path);
}

test "Relative path resolution with current directory" {
    const model = comptime hsm.define("RelativePathTest", .{ hsm.initial(hsm.target("workspace")), hsm.state("workspace", .{ hsm.entry(parentEntry), hsm.initial(hsm.target("folder_a")), hsm.state("folder_a", .{ hsm.entry(childEntry), hsm.initial(hsm.target("file1")), hsm.state("file1", .{ hsm.entry(relativeEntry), hsm.transition(.{ hsm.on("to_file2"), hsm.effect(recordRelativeNav), hsm.target("../file2") }), hsm.transition(.{ hsm.on("to_folder_b"), hsm.target("../../folder_b/file3") }) }), hsm.state("file2", .{ hsm.entry(siblingEntry), hsm.transition(.{ hsm.on("to_subfolder"), hsm.target("../subfolder/nested_file") }) }), hsm.state("subfolder", .{ hsm.entry(deepEntry), hsm.state("nested_file", .{hsm.entry(absoluteEntry)}) }) }), hsm.state("folder_b", .{ hsm.entry(childEntry), hsm.state("file3", .{ hsm.entry(relativeEntry), hsm.transition(.{ hsm.on("back"), hsm.target("../../folder_a/file1") }) }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in workspace/folder_a/file1
    try testing.expect(std.mem.endsWith(u8, sm.state(), "file1"));
    try testing.expectEqualStrings("relative", instance.current_path);

    // Relative sibling navigation
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_file2"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "file2"));
    try testing.expectEqualStrings("sibling", instance.current_path);
    try testing.expect(instance.resolution_count == 1);

    // Relative navigation with current directory notation
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_subfolder"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "nested_file"));
    try testing.expectEqualStrings("absolute", instance.current_path);

    // Reset for cross-folder navigation test
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = PathTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Navigate across folders
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "to_folder_b"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "file3"));
    try testing.expectEqualStrings("relative", instance2.current_path);

    // Navigate back across folders
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "back"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "file1"));
    try testing.expectEqualStrings("relative", instance2.current_path);
}

test "Parent directory path resolution" {
    const model = comptime hsm.define("ParentPathTest", .{ hsm.initial(hsm.target("root")), hsm.state("root", .{ hsm.entry(parentEntry), hsm.initial(hsm.target("level1")), hsm.state("level1", .{ hsm.entry(childEntry), hsm.initial(hsm.target("level2")), hsm.state("level2", .{ hsm.entry(siblingEntry), hsm.initial(hsm.target("level3")), hsm.state("level3", .{ hsm.entry(deepEntry), hsm.transition(.{ hsm.on("up_one"), hsm.effect(recordParentNav), hsm.target("..") }), hsm.transition(.{ hsm.on("up_two"), hsm.target("../..") }), hsm.transition(.{ hsm.on("up_three"), hsm.target("../../..") }), hsm.transition(.{ hsm.on("to_uncle"), hsm.target("../../../level1_sibling") }) }) }), hsm.state("level2_sibling", .{hsm.entry(absoluteEntry)}) }), hsm.state("level1_sibling", .{ hsm.entry(relativeEntry), hsm.transition(.{ hsm.on("to_nephew"), hsm.target("../level1/level2/level3") }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in root/level1/level2/level3
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level3"));
    try testing.expectEqualStrings("deep", instance.current_path);

    // Go up one level to level2
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "up_one"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "level2"));
    try testing.expectEqualStrings("sibling", instance.current_path);
    try testing.expect(instance.resolution_count == 1);

    // Reset for multi-level parent navigation
    var built_model2 = try model.build(testing.allocator);
    defer built_model2.deinit();
    var instance2 = PathTestInstance.init(testing.allocator);
    defer instance2.deinit();
    var sm2 = try hsm.start(&context, &instance2, &built_model2);
    defer sm2.deinit();

    // Go up two levels to level1
    try sm2.dispatch(&context, hsm.Event.init(testing.allocator, "up_two"));
    try testing.expect(std.mem.endsWith(u8, sm2.state(), "level1"));
    try testing.expectEqualStrings("child", instance2.current_path);

    // Reset for root navigation
    var built_model3 = try model.build(testing.allocator);
    defer built_model3.deinit();
    var instance3 = PathTestInstance.init(testing.allocator);
    defer instance3.deinit();
    var sm3 = try hsm.start(&context, &instance3, &built_model3);
    defer sm3.deinit();

    // Go up three levels to root
    try sm3.dispatch(&context, hsm.Event.init(testing.allocator, "up_three"));
    try testing.expect(std.mem.endsWith(u8, sm3.state(), "root"));
    try testing.expectEqualStrings("parent", instance3.current_path);

    // Reset for uncle navigation
    var built_model4 = try model.build(testing.allocator);
    defer built_model4.deinit();
    var instance4 = PathTestInstance.init(testing.allocator);
    defer instance4.deinit();
    var sm4 = try hsm.start(&context, &instance4, &built_model4);
    defer sm4.deinit();

    // Navigate to uncle (sibling of grandparent)
    try sm4.dispatch(&context, hsm.Event.init(testing.allocator, "to_uncle"));
    try testing.expect(std.mem.endsWith(u8, sm4.state(), "level1_sibling"));
    try testing.expectEqualStrings("relative", instance4.current_path);

    // Navigate back to nephew
    try sm4.dispatch(&context, hsm.Event.init(testing.allocator, "to_nephew"));
    try testing.expect(std.mem.endsWith(u8, sm4.state(), "level3"));
    try testing.expectEqualStrings("deep", instance4.current_path);
}

test "Self-reference path resolution" {
    const model = comptime hsm.define("SelfPathTest", .{ hsm.initial(hsm.target("stateful")), hsm.state("stateful", .{ hsm.entry(parentEntry), hsm.initial(hsm.target("inner")), hsm.transition(.{ hsm.on("reset_self"), hsm.effect(recordSelfNav), hsm.target(".") }), hsm.state("inner", .{ hsm.entry(childEntry), hsm.transition(.{ hsm.on("reset_inner"), hsm.target(".") }), hsm.transition(.{ hsm.on("reset_parent"), hsm.target("..") }) }) }), hsm.state("other", .{ hsm.entry(siblingEntry), hsm.transition(.{ hsm.on("to_stateful"), hsm.target("../stateful") }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in stateful/inner
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expectEqualStrings("child", instance.current_path);

    // Self-transition on inner state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_inner"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expectEqualStrings("child", instance.current_path);

    // A parent target resolves to the parent state itself.
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_parent"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "stateful"));

    // Self-transition with effect recording
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "reset_self"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "inner"));
    try testing.expectEqualStrings("child", instance.current_path);
    try testing.expect(instance.resolution_count == 1);
    try testing.expect(std.mem.endsWith(u8, instance.navigation_history.items[0], "self_target"));
}

test "Complex mixed path resolution" {
    const model = comptime hsm.define("MixedPathTest", .{
        hsm.initial(hsm.target("app")),
        hsm.state("app", .{
            hsm.entry(parentEntry),
            hsm.initial(hsm.target("main/editor/document")), // Nested initial path
            hsm.state("main", .{ hsm.entry(childEntry), hsm.state("editor", .{ hsm.entry(siblingEntry), hsm.state("document", .{ hsm.entry(relativeEntry), hsm.transition(.{ hsm.on("absolute_nav"), hsm.target("/MixedPathTest/app/sidebar/tools/palette") }), hsm.transition(.{ hsm.on("relative_nav"), hsm.target("../../settings/preferences") }), hsm.transition(.{ hsm.on("parent_nav"), hsm.target("../../../sidebar") }) }) }), hsm.state("settings", .{ hsm.entry(deepEntry), hsm.state("preferences", .{ hsm.entry(absoluteEntry), hsm.transition(.{ hsm.on("self_reset"), hsm.target(".") }), hsm.transition(.{ hsm.on("back_to_doc"), hsm.target("../../editor/document") }) }) }) }),
            hsm.state("sidebar", .{ hsm.entry(childEntry), hsm.initial(hsm.target("tools")), hsm.state("tools", .{ hsm.entry(siblingEntry), hsm.state("palette", .{ hsm.entry(deepEntry), hsm.transition(.{ hsm.on("close"), hsm.target("/MixedPathTest/app/main/editor/document") }) }) }) }),
        }),
    });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in app/main/editor/document via nested initial path
    try testing.expect(std.mem.endsWith(u8, sm.state(), "document"));
    try testing.expectEqualStrings("relative", instance.current_path);

    // Absolute navigation
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "absolute_nav"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "palette"));
    try testing.expectEqualStrings("deep", instance.current_path);

    // Navigate back to document with absolute path
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "close"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "document"));
    try testing.expectEqualStrings("relative", instance.current_path);

    // Relative navigation with parent traversal
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "relative_nav"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "preferences"));
    try testing.expectEqualStrings("absolute", instance.current_path);

    // Self-reference navigation
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "self_reset"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "preferences"));
    try testing.expectEqualStrings("absolute", instance.current_path);

    // Navigate back with relative path
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "back_to_doc"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "document"));
    try testing.expectEqualStrings("relative", instance.current_path);

    // Parent navigation with multiple levels
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "parent_nav"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "tools")); // sidebar initial
    try testing.expectEqualStrings("sibling", instance.current_path);
}

test "Path resolution edge cases and error conditions" {
    // Test with states that have conflicting names at different levels
    const model = comptime hsm.define("EdgeCasePathTest", .{ hsm.initial(hsm.target("container")), hsm.state("container", .{ hsm.entry(parentEntry), hsm.initial(hsm.target("state")), hsm.state("state", .{ hsm.entry(childEntry), hsm.transition(.{ hsm.on("to_nested_state"), hsm.target("../nested/state") }), hsm.transition(.{ hsm.on("to_deep_state"), hsm.target("../nested/deep/state") }) }), hsm.state("nested", .{ hsm.entry(siblingEntry), hsm.state("state", .{ hsm.entry(relativeEntry), hsm.transition(.{ hsm.on("to_parent_state"), hsm.target("../../state") }) }), hsm.state("deep", .{ hsm.entry(deepEntry), hsm.state("state", .{ hsm.entry(absoluteEntry), hsm.transition(.{ hsm.on("to_root_state"), hsm.target("/EdgeCasePathTest/container/state") }) }) }) }) }) });

    var built_model = try model.build(testing.allocator);
    defer built_model.deinit();
    try hsm.validate(&built_model);

    var context = hsm.Context.init(testing.allocator);
    var instance = PathTestInstance.init(testing.allocator);
    defer instance.deinit();

    var sm = try hsm.start(&context, &instance, &built_model);
    defer sm.deinit();

    // Should start in container/state
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container") != null);
    try testing.expectEqualStrings("child", instance.current_path);

    // Navigate to nested state with same name
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_nested_state"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "nested") != null);
    try testing.expectEqualStrings("relative", instance.current_path);

    // Navigate back to parent state
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_parent_state"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container") != null);
    try testing.expectEqualStrings("child", instance.current_path);

    // Navigate to deeply nested state with same name
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_deep_state"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "deep") != null);
    try testing.expectEqualStrings("absolute", instance.current_path);

    // Navigate back to root state using absolute path
    try sm.dispatch(&context, hsm.Event.init(testing.allocator, "to_root_state"));
    try testing.expect(std.mem.endsWith(u8, sm.state(), "state"));
    try testing.expect(std.mem.indexOf(u8, sm.state(), "container") != null);
    try testing.expectEqualStrings("child", instance.current_path);
}
