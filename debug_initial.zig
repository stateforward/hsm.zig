const std = @import("std");
const hsm = @import("src/hsm.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Testing initial transition API...", .{});

    // Test backward compatible API
    const old_model = comptime hsm.define("OldTest", .{ hsm.initial(hsm.target("start")), hsm.state("start", .{}) });

    var built_old = try old_model.build(allocator);
    defer built_old.deinit();
    std.log.info("Old API works", .{});

    // Test new API with just target
    const new_model = comptime hsm.define("NewTest", .{ hsm.initial(.{hsm.target("start")}), hsm.state("start", .{}) });

    var built_new = try new_model.build(allocator);
    defer built_new.deinit();
    std.log.info("New API works", .{});
}
