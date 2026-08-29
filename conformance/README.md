# Zig conformance runner

`run_case.zig` is a small, dependency-free foundation for running one canonical
JSON case. It reads JSON from a path argument or stdin and emits one
deterministic JSON result:

```json
{"status":"pass","name":"basic_transition","reason":"matched expected state and trace","state":"/Door/open"}
```

This is intentionally a bounded corpus runner rather than a claim of complete
IR coverage. The current supported slice is:

- `hsm-conformance-v1`, including the bounded validation cases;
- flat and nested models with ordinary, final, and choice states plus string or
  object initial targets;
- boolean, integer, string, and bounded dynamic attributes, including generated
  `on_set` and `when` events;
- `entry`, `exit`, `guard`, initial effects, transition effects, operations and
  bounded reentrancy, with behavior operations (`trace`, `call`, `set_attr`,
  `set_attr_from_event_data`, `get_attr`, `return_attr`, and `return_equals`);
- activity callbacks with cooperative `sleep` and `yield`, cancellation traces,
  and generated activity events;
- `start`, `stop`, `restart`, operation calls, object or string `dispatch`, and
  bounded `set` script steps;
- group snapshots and configured FIFO/LIFO/error queue behavior;
- entry and exit connection points across flattened submachine boundaries;
- specialized entry-point validation diagnostics where the native validator
  reports a shared transition-target error;
- expected final state, supported attributes, and normalized trace records.

Malformed cases return `fail`. Schema-valid cases outside this slice return
`skip` with a reason. The runner uses the public dynamic Zig model/runtime API
and keeps unsupported features explicit as `skip` rather than silently
accepting them. `run_all.py` provides a reproducible aggregate over a checked
out corpus; it exits non-zero on any failure or runner crash.

From this package directory:

```sh
/tmp/zig-0.15.2/zig build-exe -target aarch64-macos.15.0 --dep hsm -Mroot=conformance/run_case.zig -Mhsm=src/hsm.zig -femit-bin=/tmp/hsm-zig-runner
python3 conformance/run_all.py /tmp/hsm-zig-runner ../conformance/cases
```

The same corpus is also verified under `ReleaseFast`:

```sh
/tmp/zig-0.15.2/zig build-exe -target aarch64-macos.15.0 -O ReleaseFast \
  --dep hsm -Mroot=conformance/run_case.zig -Mhsm=src/hsm.zig \
  -femit-bin=/tmp/hsm-zig-runner-release
python3 conformance/run_all.py /tmp/hsm-zig-runner-release ../conformance/cases
```

The current exact-target result for both modes is 1396 passes, zero skips, zero
failures, and zero crashes.
