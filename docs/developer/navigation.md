# Find and organize code

> Last updated: 2026-10-02

Use this guide to find the code behind a behavior and place new files beside
their owners. Start from the subsystem, then search for the request, command,
type, or test name you are investigating.

## Prerequisites

Run the commands below from the repository root with `rg` installed.
Build and test prerequisites are in [build.md](build.md) and [test.md](test.md).

## Steps

### 1. Choose the owning subsystem

| Behavior | Start here |
|---|---|
| Process assembly and shutdown | `coordinator/app/`; command parsing stays in `coordinator/cmd/coordinator/` |
| HTTP composition | `coordinator/api/`; `NewServer` binds domain owners to the real router |
| Authentication, principals, keys and device login | `coordinator/api/access/`, `access/keys/`, `access/device/` |
| Request admission, dispatch and settlement | `coordinator/api/inference/`; request/response codecs in its `request/` and `response/` packages |
| Provider sessions and trust | `coordinator/api/provider/` and `provider/trust/`; terminal inference events return to the shared inference owner |
| Catalog publication and release policy | `coordinator/api/catalog/` and `coordinator/api/releases/` |
| Accounts, billing HTTP and payouts | `coordinator/api/accounts/`, `coordinator/api/billing/`, `billing/payouts/` |
| Public projections and operational endpoints | `coordinator/api/reporting/` and `coordinator/api/operations/` |
| Profiles, request outcomes and route sinks | `coordinator/api/observation/`; separate bounded queues retain their own loss/flush rules |
| Prompt accounting and planning | `coordinator/api/promptwork/` and the inference owner |
| Pure deadline calibration | `coordinator/registry/firstcontent/`; runtime adapters remain in `coordinator/registry/` |
| Provider selection, admission, queueing | `coordinator/registry/`; pure calculations in `registry/admission/` and `registry/selection/`, atomic transitions in the registry parent |
| Autopilot admin HTTP contract | `coordinator/api/autopilot/`; parent API adapter supplies authorization and dependencies |
| Autopilot demand, placement and donor coverage | `coordinator/registry/autopilot/`; the registry adapter owns live sessions, reservations and transport |
| Accounting and durable state | `coordinator/billing/`, `coordinator/payments/`; contracts/decorator in `coordinator/store/`, implementations in `store/memory/` and `store/postgres/` |
| Provider inference, downloads, security, local serving | `provider-swift/Sources/ProviderCore/`; entrypoints in `provider-swift/Sources/darkbloom/` |
| Autopilot runtime and operator controls | `ProviderCore/Autopilot/`, `ProviderCore/Protocol/Autopilot/`, and `darkbloom/Autopilot/` under `provider-swift/Sources/`; startup is in `darkbloom/Start/` |
| Portable model manifests and hashing | `provider-swift/Sources/ProviderCoreFoundation/`; target defined in `provider-swift/Package.swift` (`package`) |
| Console, operations dashboard, landing page | `console-ui/src/`, `admin-ui/src/`, `landing/` |
| System tests and shared inputs | `e2e/`, `fixtures/`; lifecycle harness in `e2e/testbed/` |
| Build, install, release, deploy | `Makefile`, `scripts/`, `.github/workflows/`, `deploy/` |

The dependency repositories are Git submodules under `libs/`, declared in
`.gitmodules`. The [docs index](../README.md) separates current instructions
from historical designs and reports.

### 2. Search filenames, then symbols

Find likely files before searching their contents:

```bash
rg --files coordinator/api -g '*attest*'
rg --files provider-swift/Sources provider-swift/Tests -g '*PrefixCache*'
rg --files console-ui/src -g '*Auth*' -g '*auth*'
```

Then find the implementation and its callers or tests:

```bash
rg -n 'recordRequestOutcome|classifyOutcomeByCode' coordinator/api
rg -n 'StatusCanonical' provider-swift/Sources provider-swift/Tests coordinator/attestation
```

Scope runtime searches to source and test directories. Search `docs/reports/`
separately when you need measurements or the state at a historical commit.

### 3. Name and place files by responsibility

Group a feature's independent logic and tests in its own directory. For example,
`coordinator/api/autopilot/` owns its HTTP validation and response tests.
`coordinator/registry/autopilot/` owns pure policy and demand tests; it imports no registry
or live-provider types. The registry captures detached values and retains session
identity beside them before revalidating a plan. Go methods that need registry,
HTTP-server or store receivers stay in their owning package as integration files.
Swift sources and tests use matching `Autopilot/` feature folders within their
existing targets; the CLI entry point delegates to enrollment, policy, status and
configuration files.

Use the feature followed by the behavior: `code_attest_reuse_policy_test.go`
groups the attestation reuse policy cases, and `stripe_transfer_reversal_test.go`
groups transfer reversal cases. A shared fixture belongs in a domain-specific
helper file, such as `coordinator/api/attestation_helpers_test.go`
(`testStatusSignature`).

Split unrelated test collections by the contracts they verify. Work-wave,
priority, and ticket labels belong in commit history. Meaningful protocol,
engine, model, and fixture-version identifiers belong in names when they
distinguish supported behavior.

Keep private Go invariant tests beside their owner. Public HTTP/WebSocket
contracts belong under `coordinator/api/tests/<domain>/` and use the composed
router fixture in `api/tests/internal/testkit`; backend conformance lives under
`coordinator/store/tests/`. Do not export implementation state merely to move
a test. A new directory creates a new Go package and may change access to
unexported code. Within a SwiftPM target or UI
feature, use folders for cohesive subsystems. Keep small, already focused
targets flat. Put a fixture beside its users; use a shared helper location when
several subsystems actually need it.

### 4. Check consumers before moving a file

Search the old full path and basename across tracked source, scripts, CI,
and current docs. Check relative imports, source-relative fixture lookups,
symlink destinations, build source lists, generated entrypoints, and command
paths. Preserve exported APIs and test names when only changing organization.

Historical reports, release notes, and frozen design bodies retain the paths
from their original source snapshots; follow [the docs rules](../AGENTS.md).
Public script entrypoints and release lookup paths need a compatibility plan
before renaming.

## Verify

Compare the original and moved files, account for every declaration, and
confirm that test discovery still includes the same cases. Run the affected
tests, build or typecheck where imports or source membership changed, and run
`make docs-check` after updating current links. A path move must still load
the same fixture bytes and preserve the same test selection.

The coordinator runner instruments the selected production packages and the
owners of external contract suites before merging atomic coverage profiles.
Do not use a contract package's own statement percentage as coverage of the
implementation it imports. Store test processes allocate separate disposable
databases before running backend fixtures; package parallelism must never make
one suite truncate another suite's tables.

## Related

- [Build](build.md)
- [Test](test.md)
- [Repository structure and contribution rules](../../AGENTS.md)
