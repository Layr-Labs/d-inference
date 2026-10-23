# Repository Ownership And Navigation

> Last updated: 2026-10-21

Use this map to find the provider/native owner before changing code. Centralized
backend and web-application development belongs to a different repository.

## Workspace

Coding agents share the repository instructions in [AGENTS.md](../../AGENTS.md).
[CLAUDE.md](../../CLAUDE.md) imports those instructions for Claude. The copy
fidelity rules require approved specs, Figma designs and copy files to remain
authoritative: implementation work does not authorize invented or expanded copy.

Keep sibling `Darkbloom/d-inference` and `Darkbloom/darkbloom-platform`
checkouts. Never nest them. Check remotes, branch and the full diff before pushing.
New backend, Rust sidecar, console and admin code must never be uploaded here.
The existing console snapshot and its build/test/hosting configuration remain
local; this retention does not change the platform's development ownership.

For coordinator diagnosis or changes, fetch the platform's current default
branch and read its `AGENTS.md` and relevant implementation. Old d-inference
copies and immutable evidence links do not describe the latest coordinator.

| Concern | Owner |
|---|---|
| Provider CLI and device-local HTTP APIs | `provider-swift/Sources/darkbloom/`, `provider-swift/Sources/ProviderCore/` |
| Manifest discovery, hashing and publication foundation | `provider-swift/Sources/ProviderCoreFoundation/`, `provider-swift/Sources/darkbloom-publish/` |
| Native execution, kernels and model families | `libs/mlx-swift/`, `libs/mlx-swift-lm/`, `libs/mlx/` |
| Provider and native regression coverage | `provider-swift/Tests/`, SDK test targets |
| Marketing app, including local API routes | `landing/` |
| Retained console snapshot and existing tooling | `console-ui/`; [architecture](../architecture/components/console-ui.md), new development owned by the platform |
| Shared JSON fixtures used by console tests | `coordinator/tests/protocol/testdata/paged_footprint_wire.json`, `coordinator/tests/protocol/testdata/process_memory_wire.json`; no backend implementation |
| Coordinator, private integration, consumer console and admin | [Current platform source](https://github.com/Layr-Labs/darkbloom-platform) |
| Backend contracts and deployment runbooks | [Current platform docs](https://github.com/Layr-Labs/darkbloom-platform/tree/master/docs) |

## Moving A Boundary

Preserve cohesive ownership and explicit dependencies. Check all resource readers,
test fixture paths, native package manifests, script callers and docs before a
move. Use domain names, not ticket or work-wave labels. Public golden vectors
stay public fixed-input contracts; private qualification must not become a
required checkout for provider builds. Coordinate wire, telemetry, model/load
quotations and release identity across repositories without copying implementations.

## Deployment Authority

Source ownership does not grant deployment authority. Infrastructure, hosting
and traffic changes require specific human approval. Registering an approved
release/model through an external API remains supported; building, testing or
deploying the backend here does not.

Before removal, local docs mixed provider and backend instructions. After
removal, native/provider and retained-console docs stay local and platform details have immutable
external references. Frozen records are retained unchanged or retired with
their inbound dependency closure; [historical references](historical-references.md)
explain their original source.

## Related

- [Build](build.md)
- [Test](test.md)
- [Contribution rules](../../CONTRIBUTING.md)
