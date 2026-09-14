# Find and organize code

> Last updated: 2026-09-13 · commit `8670b2a08`

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
| Process startup, configuration binding and shutdown | `coordinator/cmd/coordinator/main.go` (`main`); follow each named setup function to its subsystem file in the same command package. [Startup source map](../architecture/components/coordinator.md#startup-sequence) |
| API request handling, auth, attestation, dispatch | `coordinator/api/`; server construction in `server.go` (`NewServer`) |
| Metrics and asynchronous observation writes | `coordinator/telemetry/metrics/`, `coordinator/telemetry/routequeue/`, `coordinator/telemetry/profilequeue/`, `coordinator/telemetry/outcomequeue/`; API adapters supply request context and persistence dependencies |
| Profile construction, provider diagnostics and sampling | `coordinator/telemetry/profiler/` (`Builder`, `Profiler`); request/terminal lifecycle wiring remains in `coordinator/api/profiler.go` |
| Durable device evidence, revocation and reconnect continuity | `coordinator/providercontrol/trustreuse/` (`Manager`); HTTP lifecycle integration remains in `coordinator/api/` |
| Provider challenge nonces, replies and verification | `coordinator/providercontrol/challenge/` (`Session`, `Verifier`); `coordinator/api/provider_challenge.go` binds current dependencies and `providerReadLoop` owns the connection lifecycle |
| Registration, reconnect state and device verification | `coordinator/providercontrol/verification/` (`Verifier`, `Attempt`); `coordinator/api/provider_verification.go` binds current resources; scheduler claims and late-command ownership remain in `coordinator/api/mdm_scheduler.go` and `coordinator/api/mdm_scheduler_callbacks.go` |
| Code-identity proof, APNs budgets and encrypted resume | `coordinator/providercontrol/codeidentity/` (`Manager`); the API adapter binds the release snapshot, startup proof store and live coverage store |
| Readiness, admin draining and graceful shutdown | `coordinator/api/readiness/` (`Controller.Gate`, `Ready`, `Drain`, `WaitForInflightZero`); `coordinator/api/drain.go` binds one owner for routes and public shutdown methods |
| Downloading a coordinator state archive | `coordinator/api/statearchive/` (`Controller.Download`, root selection, streamed byte accounting); `coordinator/stateexport/` (`Archiver.Stage`, `Write`, `EncryptWriter`) |
| Release HTTP, artifact validation, discovery and deactivation | `coordinator/api/releases/` (`Controller`); `coordinator/api/releases.go` binds current inventory, cache and policy dependencies; `coordinator/api/admin_auth.go` retains admin authorization and OTP |
| Active releases, binary allowlists, runtime verification and evidence generations | `coordinator/providercontrol/releasepolicy/` (`Manager`, `Snapshot`); `coordinator/api/release_policy.go` binds inventory and fleet |
| Provider selection, admission, queueing | `coordinator/registry/`; request eligibility in `request_traits.go` (`providerEligibleForTraitsLocked`) |
| Billing and durable state | `coordinator/billing/`, `coordinator/payments/`, `coordinator/store/` |
| Provider inference, downloads, security, local serving | `provider-swift/Sources/ProviderCore/`; entrypoints in `provider-swift/Sources/darkbloom/` |
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

Use the feature followed by the behavior: `code_attest_reuse_policy_test.go`
groups the attestation reuse policy cases, and `stripe_transfer_reversal_test.go`
groups transfer reversal cases. A shared fixture belongs in a domain-specific
helper file, such as `coordinator/api/attestation_helpers_test.go`
(`testStatusSignature`).

Split unrelated test collections by the contracts they verify. Work-wave,
priority, and ticket labels belong in commit history. Meaningful protocol,
engine, model, and fixture-version identifiers belong in names when they
distinguish supported behavior.

Keep Go tests beside their owning package: a new directory creates a new Go
package and may change access to unexported code. Within a SwiftPM target or UI
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

## Related

- [Build](build.md)
- [Test](test.md)
- [Repository structure and contribution rules](../../AGENTS.md)
