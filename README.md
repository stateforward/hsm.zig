# hsm.zig

`hsm.zig` is the active StateForward hierarchical state-machine package for
Zig. Models are declared at compile time and built into flat runtime storage
indexed by qualified state names, with transition paths prepared during model
construction.

Release: `v1.3.3`.

## API

The package has no external dependencies. A minimal model and runtime setup
looks like this:

```zig
const std = @import("std");
const hsm = @import("hsm");

const Controller = comptime hsm.define("Controller", .{
    hsm.initial(hsm.target("ready")),
    hsm.state("ready", .{
        hsm.transition(.{ hsm.on("stop"), hsm.target("stopped") }),
    }),
    hsm.final("stopped"),
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var model = try Controller.build(allocator);
defer model.deinit();
try hsm.validate(&model);

var context = hsm.Context.init(allocator);
var instance = hsm.Instance.init();
defer instance.deinit();
var machine = try hsm.start(&context, &instance, &model);
defer machine.deinit();
try machine.dispatch(&context, hsm.Event.init(allocator, "stop"));
```

`Instance.init()` takes no allocator. The builder API includes `define`,
`redefine`, `state`, `final`, `choice`, `initial`, `transition`, `on`, `onSet`,
`onCall`, `target`, `entry`, `exit`, `effect`, `activity`, `guard`, `after`,
`every`, `at`, `deferEvents`, `validator`, `finalizer`, and `observe`; transition
subtypes can be selected with `TransitionType(InternalKind)`,
`TransitionType(ExternalKind)`, `TransitionType(LocalKind)`, or
`TransitionType(SelfKind)`. PascalCase aliases are also exported. `New` binds
an unstarted runtime and `.start()`
enters its initial configuration; `Started` combines both operations. All
constructors return the owning `*StateMachine` handle, so callers deinitialize
that pointer directly exactly once. Copying the pointer creates a borrow, not a
second owner; borrowed aliases must not call `deinit()` after the owning handle
has been released. Zig uses
tuples where the shared DSL uses variadic arguments, for example
`Observe(callback, .{"*"})`. Initial declarations support a target alone or a
target followed by ordered effects:

Only started machines are visible through the context registry. `stop()` removes
the machine from that registry, and a later `start()` registers it again.

```zig
hsm.initial(hsm.target("ready"))
hsm.initial(.{
    hsm.target("ready"),
    hsm.effect(.{ initialize, record_start }),
})
```

Initial entry uses the canonical runtime event `hsm/initial`; construct one
directly with the public `hsm.InitialEvent(allocator)` helper. The matching
`hsm.FinalEvent(allocator)` and `hsm.ErrorEvent(allocator)` helpers create the
shared `hsm/final` and `hsm/error` completion events. Use `TimerEvent(allocator,
name)` for a manually injected timer event; ordinary `Event` values do not
activate timer transitions.

`Event.putData` and `Event.putMetadata` store borrowed `*anyopaque` values. The
runtime copies event envelopes into re-entrant, regular, deferred, and activity
queues but does not deep-copy or destroy arbitrary borrowed payloads, so that
storage must remain valid until processing completes. Runtime-generated typed
payloads such as `AttributeChange` and `CallData` are retained across queued
and deferred delivery; `CallData.ArgsAs(T)` and `CallData.ValueAs(index, T)`
provide typed pointer views. `CallWithArgs` accepts an ordered tuple of borrowed
pointers for multi-argument operation calls. Use `putOwnedData` or
`putOwnedMetadata` with a `PayloadDropFn` when the event should own an arbitrary
payload through queued delivery.

`fromContextLease` and `instancesFromContextLease` provide lifetime-safe context
lookups. `Group.Snapshots()` returns one caller-owned snapshot per member;
`Group.TakeSnapshot()` remains the aggregate snapshot API.

`Context.initWithParent` borrows its parent; the parent must outlive every
child query. A custom `RuntimeQueue` receives owned event clones: successful
`Push` transfers ownership, failed `Push` must retain nothing, and `Pop`
transfers ownership to its caller. A failed `Pop` is an atomic no-transfer
operation and may be retried once; a failed `Len` has no mutation or ownership
effect. Queue and clock callback contexts are
borrowed, must outlive the machine, and must synchronize themselves when shared
across machines or timer/activity threads. Stop drains events that were
successfully accepted by the queue. If `Pop` continues to fail after the
bounded retry, stop returns the second Pop error with those events still owned
by the custom queue; the queue owner must make them drainable before retrying
stop/deinit. The failed attempt leaves the active configuration intact, so
exit actions are not repeated on the retry; restart also retries stop before
re-entering the model.

The context passed to `start` is the machine's lifetime context and must outlive
the machine. Timer workers retain that machine context rather than an
event-local context supplied to a transition.

Activities run concurrently and receive the shared instance pointer. Activity
code must treat that pointer as actor-owned state: coordinate any mutation
with the application, honor context cancellation, and do not retain the
pointer or event after the callback returns. The runtime cancels admitted
activities before state-exit teardown and waits for them to return, except when
the callback synchronously stops its own machine. `RuntimeConfig.ActivityTimeoutNs`
sets the finite wait bound (the default is five seconds); a non-cooperative
callback causes `stop()` to return `error.ActivityTimeout` while the owner
remains alive for a later retry. `deinit()` is a `void` API: it logs the same
timeout and leaves the owner alive, so callers must retry deinitialization
after the callback finishes.

`SubmachineState(name, child_model)` flattens a reusable child model under a
boundary. For boundary-local entry/exit/activity/defer/transition behavior,
use the Zig-specific `SubmachineStateWithPartials(name, child_model, .{ ... })`
helper. The two-argument form remains source-compatible.

The compatibility `fromContext`, `instancesFromContext`, and `Group.Instances()`
forms return borrowed pointers. Do not retain those aliases across `stop()` or
`deinit()`; use the lease forms when a lookup must outlive the lookup call.

History builders accept the legacy `target(...)` default and native default
transition tuples, for example `history("h", .{ transition(.{ guard(fn),
effect(fn), target("ready") }) })`; default guards and effects retain their
declaration order.

The package exports the canonical inherited kind constants (`ElementKind`,
`StateKind`, `TransitionKind`, event kinds, pseudostate kinds, and the other
`*Kind` values). `ElementType` is the separate native enum used for flat-storage
structural tags such as `.state`, `.final`, and `.choice`.

## Build and validation

This package targets Zig 0.15.2 exactly. Verify the toolchain before building;
the guard prevents a newer incompatible Zig release from being used:

```sh
test "$(zig version)" = "0.15.2"
zig build
zig build test
```

Compile the validation test directly for the macOS target-15 surface with:

```sh
test "$(zig version)" = "0.15.2"
zig test -target aarch64-macos.15.0 \
    --dep hsm -Mroot=tests/validation_test.zig -Mhsm=src/hsm.zig \
    -fno-emit-bin
```

This target-15 command is compile validation; running the resulting binary
requires a matching target runtime. `conformance/run_case.zig` covers the
canonical JSON surface, including nested states, connection points, generated
attribute events, operations, completion transitions, activities, snapshots,
configured queues, per-instance models and clocks, deferred replay, and bounded
reentrancy. `conformance/run_all.py` provides the reproducible aggregate; the
current exact corpus result is 1396 passes, zero skips, zero failures, and zero
crashes in both Debug and `ReleaseFast`.
