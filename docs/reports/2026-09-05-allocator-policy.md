# Detached allocator sizing policy

> Last updated: 2026-09-05 · commit `2dcec3574`

Allocator bounds can now be projected from an immutable policy value without
entering the allocator, allocating memory, waiting, throwing or invoking an
error callback. This supports conservative auxiliary-memory admission while
keeping logical tensor geometry separate from allocator backing.

`Memory.allocationFootprintPolicy()` exposes the backend's five sizing
parameters. Its checked `upperBound(byteCount:)` and `maximumExtraBytes`
projections return nil on invalid input or overflow. The existing throwing
prediction API uses the same arithmetic; actual allocation behavior is unchanged.

| Validation | Result |
|---|---|
| CPU allocator | Four cases pass: policy, bound, prediction and cache regression |
| Metal allocator | The same four cases pass |
| Swift wrapper | Six functions / six cases pass; build 46.43 seconds |
| Source identity | 12 changed files and 1,356 dependency inputs verified; no drift |

The new coverage comprises one C++ policy test and two Swift functions. The
policy test also exercises CUDA's sizing parameters as data; no CUDA backend
was compiled or executed. The existing Foundation import and completion-fenced
ownership fixtures were preserved. No test or production correction was needed.
The native source remains `a486a55d032deae001190bf9795ece1cb3d9a609`;
the [foundation's 404 native cases](2026-09-05-allocator-footprint.md) were
not rerun in this dependency-only gate.

Committed pins are Swift `67153a874b6d8dd0e1ad04c256298eaae8249cd7`,
MLX `30ae65605cca3fa9f9d5548e7f4fee07cd1e267c`, and
mlx-c `3ccef143eaa28658f8d095fdbc8ff0e9049e2449`. Provider accounting, full checkpoint
integration and all five fleet-model tests remain pending; this report makes
no latency, usable-capacity or rollout claim.

The [manifest](evidence/allocator-policy-2026-09-05/manifest.json)
(SHA-256 `44489c2bdfbe2eaa2edd529911f9cff1131d97daa8bd20cefe7403b7a48fed57`) records 60 verified
payloads, including all 55 validation records, source archives, compiler graphs,
test logs and commit verification. The
[archive](evidence/allocator-policy-2026-09-05/payloads.tar.gz) has SHA-256
`72bb105e02fffc56f92423345b61e98d829fe51a4105ceffaa6f8dd65b053d79`. The accepted validation manifest is
`45fa645950258545f9b1942f1db585007e8b16607afdf5dc42f48949acd541a9`.
Build products and model weights are excluded. Current APIs are documented in
the [MLX stack](../architecture/components/mlx-swift.md#allocator-footprint-and-backing-ownership).
