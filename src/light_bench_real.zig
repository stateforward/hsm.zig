const std = @import("std");
const hsm = @import("hsm.zig");

// Light instance for the HSM
const LightInstance = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self; // No cleanup needed for this simple example
    }
};

// Simple benchmark entry function for quick test
pub fn runBenchmarkQuickTest() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Testing Zig Real HSM API...", .{});
    
    // Try to create a simple instance and context
    var instance = LightInstance.init(allocator);
    defer instance.deinit();
    
    var context = hsm.Context.init(allocator);
    
    std.log.info("Basic setup successful", .{});
    
    // Try to create an event
    var event = hsm.Event.init(allocator, "test");
    defer event.deinit();
    
    std.log.info("Event creation successful", .{});
    std.log.info("Real Zig HSM API is accessible!", .{});
}

pub fn main() !void {
    try runBenchmarkQuickTest();
}