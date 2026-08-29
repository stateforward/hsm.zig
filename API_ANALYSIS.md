# Zig HSM API Analysis and Implementation

## Overview

I've analyzed the JavaScript HSM implementation and updated the Zig implementation to follow the same API patterns while adapting to Zig's language features.

## Key JavaScript API Patterns Identified

### 1. Define Function Structure
JavaScript uses `hsm.define()` with a builder pattern:
```javascript
const model = hsm.define('MachineName',
  hsm.initial(hsm.target('startState')),
  hsm.state('startState', 
    hsm.transition(hsm.on(event), hsm.target('nextState'))
  ),
  hsm.final('endState')
);
```

### 2. Multiple Functions Support
JavaScript supports multiple functions in actions:
```javascript
hsm.entry(func1, func2, func3)        // Multiple entry functions
hsm.exit(exitFunc1, exitFunc2)        // Multiple exit functions  
hsm.effect(effect1, effect2, effect3) // Multiple effect functions
hsm.activity(activity1, activity2)    // Multiple concurrent activities
```

### 3. Transition Composition
JavaScript composes transitions with multiple builders:
```javascript
hsm.transition(
  hsm.on('event'),           // Event trigger
  hsm.guard(guardFunc),      // Guard condition
  hsm.effect(effect1, effect2), // Multiple effects
  hsm.target('../nextState') // Target state
)
```

### 4. Function Signatures
All functions use `(ctx, inst, event)` signature:
```javascript
entry: function(ctx, inst, event) { /* sync */ }
exit: function(ctx, inst, event) { /* sync */ }
effect: function(ctx, inst, event) { /* sync */ }
guard: function(ctx, inst, event) { return boolean; }
activity: function(ctx, inst, event) { /* async */ }
```

## Zig Implementation Adaptations

### 1. Anonymous Tuples Instead of Variadic Arguments
Zig uses `.{}` syntax for grouping elements:
```zig
const model = hsm.define("MachineName", .{
    hsm.initial(hsm.target("idle")),
    hsm.state("active", .{
        hsm.entry(.{ setupState, logEntry, initializeCounters }),
        hsm.exit(.{ saveData, cleanupResources, logStateExit }),
        hsm.activity(.{ backgroundSync, heartbeat, monitoring }),
        hsm.transition(.{
            hsm.on("process"),
            hsm.effect(.{ validateInput, processData, updateUI }),
            hsm.target("."), // Self transition
        }),
    }),
    hsm.final("done"),
});
```

### 2. Compile-Time Model Description, Runtime Index Build
The Zig implementation captures model declarations at compile time and builds
the runtime model and lookup indexes when `build()` is called:
```zig
// Compile-time builder that returns a type with build() method
pub fn define(comptime name: []const u8, comptime elements: anytype) type {
    return struct {
        pub fn build(allocator: std.mem.Allocator) !Model {
            // Build the runtime model from the compile-time description
        }
    };
}
```

### 3. Function Pointer Management
Zig requires explicit function pointer types:
```zig
// Builder stores function pointers
pub fn EntryBuilder(comptime T: type) type {
    return struct {
        functions: []const *const fn (ctx: *Context, inst: *T, event: Event) void,
    };
}
```

### 4. Multiple Functions Support
Zig detects single vs multiple functions using type introspection:
```zig
pub fn entry(comptime funcs: anytype) EntryBuilder(Instance) {
    const T = @TypeOf(funcs);
    const info = @typeInfo(T);
    
    if (info == .@"fn" or info == .pointer) {
        // Single function
        return EntryBuilder(Instance).init(funcs);
    } else if (info == .@"struct" and info.@"struct".is_tuple) {
        // Multiple functions in tuple
        // Convert tuple to array of function pointers
    }
}
```

## Current Implementation Status

### ✅ Completed
1. **API Structure**: Zig HSM now supports the JavaScript-style API pattern
2. **Multiple Functions**: `entry()`, `exit()`, `effect()`, and `activity()` all support multiple functions
3. **Transition Building**: Transitions can be composed with multiple builders
4. **Function Signatures**: All functions use `(ctx, inst, event)` pattern
5. **Compile-time Processing**: Models are processed at compile time
6. **Runtime parity slice**: timers, choices, deferred events, activities,
   hierarchy, history, connection points, attributes, operations, snapshots,
   queues, per-instance models/clocks, and bounded reentrancy are covered by
   the canonical conformance runner and package tests
7. **Version and build surface**: `v1.3.3`, Zig 0.15.2, target-15 compile
   checks, and the examples/benchmarks are aligned
8. **Declarative extension slice**: `Redefine`, `Validator`, `Finalizer`, and
   `Observe` are native compile-time builders. Zig adapts variadic DSL forms
   to tuples; model hooks accept callbacks and observation accepts callback plus
   a tuple of target patterns.
9. **Event-kind parity slice**: change, call, and timer events expose dedicated
   inherited kind identifiers, snapshots preserve the change/call/time tags,
   and manually injected timer events use the low-ceremony `TimerEvent` helper.
10. **Initial declaration/effects slice**: `initial(target(...))` and
    `initial(.{ target(...), effect(...), ... })` are native declarations.
    Initial effects execute in declaration order, startup and lifecycle
    re-entry use the canonical runtime event `hsm/initial`, and the public
    `hsm.InitialEvent`, `hsm.FinalEvent`, and `hsm.ErrorEvent` helpers create
    the shared runtime completion events directly.
11. **Transition topology validation**: `validate()` rejects non-initial
    transitions that have neither a target nor an effect, including guard-only
    and event-only transitions, while preserving effect-only internal
    transitions. The conformance runner maps this native error to the
    canonical `missing_target` validation code.
12. **Transition subtype and ownership APIs**: transition subtype markers and
    inferred kinds preserve internal, external, local, and self semantics;
    context leases hold a live machine through lookup; and `Group.Snapshots()`
    returns ordered per-member snapshots alongside the aggregate API.
13. **History default transitions**: shallow and deep history builders accept
    native default transition partials with ordered guards and effects, while
    preserving the legacy target-only form.
14. **Submachine model-member flattening**: composed child attributes and
    operations are redefined into the parent model namespace alongside the
    child state/transition topology; completion selection is scoped to the
    immediately completing composite.

### Explicit residuals
The canonical JSON/runtime surface is green, but native-runtime boundaries
remain intentionally explicit. `Observe` now instruments entry, exit, activity,
effect, operations, guards, timers, and matching transition events through
direct compile-time wrappers. Observation envelopes expose the qualified
behavior/transition source while `ObservationData.event` remains the original
event passed to the wrapped callback. `Redefine` implements same-category named overlays
for vertex-like states (`State`, `Final`, `Choice`, `History`, and
`Submachine`), attributes, operations, and connection points; it also replaces
an inherited root `Initial` when additions provide a replacement. Source-owned
transition-subtree removal is implemented for inherited transitions whose explicit
source or target paths touch a replaced vertex subtree. Composite `State` overlays
recursively merge nested additions, so a child replacement keeps unrelated
siblings while final, history, choice, and submachine replacements remain full
subtree replacements. Initial declaration/effects and the canonical initial event
are implemented; they are not residual parity work. Transition topology validation
is implemented. Runtime constructors now return the pointer to the embedded
`RuntimeOwner.machine`, keeping the owner allocation and its deinit lifecycle
tied to the public handle. The returned pointer is the single owning handle;
pointer copies are borrows and callers must invoke `deinit()` exactly once on
the owner. Finalizers support
`void`/`!void` and `*Model`/`!*Model` only when a returned pointer is the
in-place model; normal `Model.build` runs default validation and finalization,
while explicit hooks override those defaults by the last marker. Custom
    finalizers run before the default index finalizer and are responsible for any
    required preparation. Arbitrary opaque event data passed through putData remains
    intentionally borrowed and is not deep-copied; putOwnedData and putOwnedMetadata
    provide an explicit drop-callback ownership path through queued or deferred
    delivery. Timer/activity teardown, lifecycle serialization, transition
    subtypes, multi-argument CallData, context lookup leases, and per-member group snapshots are implemented
    and covered by the current test matrix. Native history defaults accept ordered
    guarded/effectful transition partials and preserve the target-only form; unsupported
    history triggers/source/timers are rejected at compile time. Strict end-to-end O(1) proof remains a
    residual because exit/entry/effect execution is proportional to the affected
    configuration. The compatibility `fromContext`, `instancesFromContext`, and
    `Group.Instances()` APIs return borrowed pointers/slices and do not pin lifetime;
    callers requiring a retained lookup must use the lease APIs. Stop preflights
    its bookkeeping allocations before teardown, but a user callback or future
    internal teardown error is not advertised as a transactional rollback boundary.
    `RuntimeQueue` now documents clone ownership, atomic failed-Push behavior,
    Pop transfer, borrowed callback contexts, and the stop drain boundary;
    `Context.initWithParent` explicitly documents its borrowed-parent lifetime.
    Persistent custom-queue Pop failure is bounded to two drain attempts and
    explicitly returns the second Pop error before state teardown and leaves
    not-yet-returned events owned by that queue for a later retry. A failed
    drain leaves the active configuration intact; restart retries stop before
    re-entry. Snapshot construction now cleans identity/state/event/transition/
    attribute allocations when RuntimeQueue.Len fails. Activity teardown has a
    finite `RuntimeConfig.ActivityTimeoutNs` bound (five seconds by default).
    `stop()` returns `error.ActivityTimeout` without releasing the owning
    machine when a callback does not cooperate; the existing `void deinit()`
    logs that timeout and leaves the owner available for a later retry.
    Activity callbacks remain a deliberately low-level concurrent callback API
    matching the sibling runtimes: cancellation is cooperative and completion
    or failure is observed by the callback's shared application state rather
    than synthesized into a new public event protocol.
    Qualified runtime timer events now use indexed current-state/
    event lookup; generic/manual timer names retain the bounded transition-list
    fallback. Zig exposes boundary partials through `SubmachineStateWithPartials`
    because Zig cannot express a default `anytype` parameter on the compatibility
    `SubmachineState(name, child)` signature.

## Key Differences from JavaScript

### Language-Specific Adaptations
1. **Anonymous Tuples**: Zig uses `.{func1, func2}` instead of `func1, func2`
2. **Compile-time vs Runtime**: Zig processes models at compile time, JavaScript at runtime
3. **Type Safety**: Zig requires explicit function pointer types
4. **Memory Management**: Zig requires explicit allocation/deallocation

### API Consistency Maintained
1. **Function Names**: Same function names (`entry`, `exit`, `effect`, etc.)
2. **Builder Pattern**: Same composable builder approach
3. **Function Signatures**: Same `(ctx, inst, event)` pattern
4. **Hierarchical Structure**: Same nested state structure

## Example Usage Comparison

### JavaScript
```javascript
const model = hsm.define('MyMachine',
  hsm.initial(hsm.target('idle')),
  hsm.state('idle',
    hsm.entry(setupIdle, logEntry),
    hsm.transition(hsm.on('start'), hsm.target('active'))
  ),
  hsm.state('active',
    hsm.entry(setupActive),
    hsm.exit(cleanupActive, saveState),
    hsm.transition(
      hsm.on('process'),
      hsm.effect(validateInput, processData),
      hsm.target('.')
    )
  )
);
```

### Zig
```zig
const model = hsm.define("MyMachine", .{
    hsm.initial(hsm.target("idle")),
    hsm.state("idle", .{
        hsm.entry(.{ setupIdle, logEntry }),
        hsm.transition(.{
            hsm.on("start"), 
            hsm.target("active")
        }),
    }),
    hsm.state("active", .{
        hsm.entry(setupActive),
        hsm.exit(.{ cleanupActive, saveState }),
        hsm.transition(.{
            hsm.on("process"),
            hsm.effect(.{ validateInput, processData }),
            hsm.target("."),
        }),
    }),
});
```

## Conclusion

The Zig HSM implementation successfully adapts the JavaScript API pattern while maintaining:
- **API Consistency**: Same function names and patterns
- **Polyglot Compatibility**: Developers familiar with JavaScript HSM can easily use Zig HSM
- **Language-Appropriate Design**: Uses Zig's compile-time features and type safety
- **Performance**: Compile-time model description with precomputed runtime
  indexes; ordinary events and qualified runtime timer events use average O(1)
  state/event lookup, while generic/manual timer names retain the bounded
  fallback. Model construction and transition execution retain their
  proportional work, so full strict end-to-end O(1) dispatch remains unclaimed
  because exit/entry/effect execution is proportional to the affected
  configuration.

The implementation provides a solid foundation for a polyglot HSM library that maintains consistency across languages while leveraging each language's strengths.
