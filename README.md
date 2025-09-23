# HSM (Hierarchical State Machine) for Zig

A simplified state machine framework for Zig that provides basic state machines with entry/exit actions, guard conditions, effect actions, and activities.

**Note**: This is a simplified implementation that demonstrates the core HSM concepts. The full compile-time hierarchical implementation is available in `src/hsm.zig` but requires additional work for Zig compatibility.

## Features

- **Compile-time Model Definition**: State machines are built at compile time for zero runtime cost
- **Hierarchical States**: Support for nested states with proper entry/exit semantics
- **Multiple Action Support**: Entry, exit, effect, and activity functions with multiple function support
- **Guard Conditions**: Boolean conditions to control transitions
- **Choice States**: Conditional branching with required guardless fallback
- **Path Resolution**: Relative and absolute path navigation (`../`, `./`, `/absolute/path`)
- **Activity Support**: Long-running async operations with cancellation
- **Timer Transitions**: `after` and `every` timer-based transitions
- **Compile-time Validation**: Extensive validation catches errors at compile time
- **Memory Safe**: Proper memory management with explicit allocator patterns

## Quick Start

```zig
const std = @import("std");
const hsm = @import("hsm");

// Define your instance type
const MyInstance = struct {
    base: hsm.Instance,
    counter: i32,
    
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .base = hsm.Instance.init(allocator),
            .counter = 0,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.base.deinit();
    }
};

// Define action functions (all use (ctx, inst, event) signature)
fn incrementCounter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    _ = ctx; _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    my_inst.counter += 1;
}

fn checkCounter(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {
    _ = ctx; _ = event;
    const my_inst: *MyInstance = @ptrCast(@alignCast(inst));
    return my_inst.counter >= 5;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Define state machine at compile time
    const model = comptime hsm.define("CounterMachine", .{
        hsm.initial(hsm.target("counting")),
        
        hsm.state("counting", .{
            hsm.entry(resetCounter),
            hsm.transition(.{ hsm.on("increment"), hsm.effect(incrementCounter) }),
            hsm.transition(.{ hsm.on("check"), hsm.guard(checkCounter), hsm.target("done") })
        }),
        
        hsm.final("done")
    });
    
    // Validate at compile time
    hsm.validate(model);
    
    // Create context and instance
    var context = hsm.Context.init(allocator);
    var instance = MyInstance.init(allocator);
    defer instance.deinit();
    
    // Start the state machine
    var sm = try hsm.start(&context, &instance, &model);
    defer sm.deinit();
    
    // Dispatch events
    try sm.dispatch(&context, hsm.Event.init("increment"));
    try sm.dispatch(&context, hsm.Event.init("check"));
}
```

## Core Concepts

### Function Signatures

All HSM functions follow the same signature pattern:

```zig
fn myAction(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {}
fn myGuard(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) bool {}
fn myActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {} // Async
fn myTimer(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {} // Returns nanoseconds
```

### Multiple Functions

All action types support multiple functions executed in sequence:

```zig
hsm.entry(.{ setupState, logEntry, initializeCounters })
hsm.exit(.{ saveData, cleanup, logExit })
hsm.effect(.{ validate, process, update })
hsm.activity(.{ backgroundSync, heartbeat, monitoring }) // Run concurrently
```

### State Types

```zig
// Regular state with full functionality
hsm.state("processing", .{
    hsm.entry(processingEntry),
    hsm.exit(processingExit),
    hsm.activity(backgroundWork),
    hsm.transition(.{ hsm.on("complete"), hsm.target("done") })
})

// Final state - no transitions, activities, or substates allowed
hsm.final("completed")

// Choice state - must have guardless fallback
hsm.choice("decision", .{
    hsm.transition(.{ hsm.guard(condition1), hsm.target("path1") }),
    hsm.transition(.{ hsm.guard(condition2), hsm.target("path2") }),
    hsm.transition(.{ hsm.target("default") }) // Required guardless fallback
})
```

### Path Resolution

```zig
hsm.target("child")           // Direct child of current state
hsm.target("../sibling")      // Up one level to sibling
hsm.target("/root/absolute")  // Absolute path from machine root
hsm.target(".")               // Self transition (exit and re-enter)
hsm.target("..")              // Parent reference
```

### Hierarchical States

```zig
hsm.state("parent", .{
    hsm.initial(hsm.target("child1")),
    
    hsm.state("child1", .{
        hsm.transition(.{ hsm.on("next"), hsm.target("../child2") })
    }),
    
    hsm.state("child2", .{
        hsm.transition(.{ hsm.on("up"), hsm.target("../../other") })
    })
})
```

### Activities and Cancellation

```zig
fn longRunningActivity(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) void {
    while (!ctx.is_done()) {
        // Do work in chunks
        performWork();
        
        // Check cancellation periodically
        std.time.sleep(std.time.ns_per_ms * 100);
        if (ctx.is_done()) break;
    }
}
```

### Timer Functions

```zig
fn shortDelay(ctx: *hsm.Context, inst: *hsm.Instance, event: hsm.Event) u64 {
    _ = ctx; _ = inst; _ = event;
    return std.time.ns_per_ms * 500; // 500 milliseconds
}

// Usage
hsm.transition(.{ hsm.after(shortDelay), hsm.target("timeout_state") })
hsm.transition(.{ hsm.every(shortDelay), hsm.effect(periodicAction) })
```

## Building and Testing

```bash
# Build the library
zig build

# Run tests
zig build test

# Run the basic example
zig build example
```

## Directory Structure

```
zig/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── src/
│   └── hsm.zig            # Main HSM implementation
├── examples/
│   └── basic.zig          # Basic usage example
├── tests/
│   ├── basic_test.zig     # Basic functionality tests
│   ├── hierarchical_test.zig # Hierarchical state tests
│   └── choice_test.zig    # Choice state tests
└── README.md              # This file
```

## Best Practices

### Performance
- Use `comptime` for model definition when possible
- Prefer stack allocation over heap when feasible
- Keep guard functions lightweight and deterministic
- Check `ctx.is_done()` in long-running activities

### Memory Safety
- Always pair `init()` with `deinit()`
- Use arena allocators for temporary state machines
- Pass allocators explicitly through instance structs
- Check for null before accessing optional data

### State Machine Design
- Use absolute paths when unsure about relative paths
- Keep guard functions fast and side-effect free
- Put long-running work in activities only
- Handle all error cases with explicit error states
- Use specific, domain-relevant event names
- Avoid deep hierarchies (>4 levels recommended)

## Critical Rules

### MUST Do
- **Context first**: `(ctx, inst, event)` signature in ALL functions
- **Event objects only**: Use `hsm.Event.init()` or `hsm.Event.withData()`
- **Sync functions**: entry/exit/effect/guard - NO spawning threads
- **Async functions**: activities only - for long-running cancellable tasks
- **Memory management**: Always pair init/deinit calls
- **Cancellation**: Check `ctx.is_done()` in activities

### MUST NOT Do
- Spawn threads in sync functions (entry/exit/effect/guard)
- Ignore context cancellation in activities
- Use string events - only Event objects
- Forget to call deinit() on instances
- Create choice states without guardless fallback
- Access freed memory after instance.deinit()

## License

This implementation follows the same license as the parent HSM project.