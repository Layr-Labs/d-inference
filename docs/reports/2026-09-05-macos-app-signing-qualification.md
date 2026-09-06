# macOS app signing qualification — 2026-09-05

> Last updated: 2026-09-05 · commit `63caa59f5`

The signed raw CLI inside the GUI bundle failed to launch despite passing
deep/strict signature verification. Making that CLI the main executable of a
nested provider app passed launch and, with colocated runtime payloads, the
Gemma/Paged kernel smoke. This is local qualification evidence, not release
approval or proof of persistent identity and network attestation.

## Provenance and controls

Candidate: `63caa59f53940c9cfa0e6059031f57515d115b5e`, provider version `0.8.16`.
Probe root:
`/Users/gaj/.codex/app-refresh-artifacts/20260905/signing-probes`.
The original failure and same-CLI bundle-main result below were supplied by
the operator. The documentation pass read the retained helper logs, runtime
JSON, bundle plists, and alias; it did not rerun binaries or native UI.

| Control / probe | Observed result | Scope |
|---|---|---|
| GUI main `DarkbloomApp`; raw outer `Contents/MacOS/darkbloom`, signed `io.darkbloom.provider` with matching profile/certificate | `codesign --verify --deep --strict` passed; CLI `--version` received SIGKILL, shell exit 137 | Static signature validity did not establish AMFI launch acceptance |
| Same CLI as bundle main (`LegacyMain.app`) | `--version` exited 0 | The same CLI could launch as the provisioned bundle main |
| `NestedHelper.app/Contents/Helpers/DarkbloomProvider.app`, main `darkbloom` | Direct and outer-alias `--version` passed; control log prints `0.8.16` twice | Local helper layout passed process launch |
| Helper with real colocated signed metallib/enclave and runtime resources | `nested-resource-runtime.json`: exit 0, Gemma and Paged success markers, empty stderr | Packaged configuration/kernel execution; no model serving or attestation claim |

Both retained control plists use identifier `io.darkbloom.provider` and version
`0.8.16`. The helper plist names `darkbloom`; the outer GUI plist names
`DarkbloomApp`. The exact outer CLI link is
`../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`.

Earlier attempts remain part of the evidence:

- `nested-helper-runtime-check.json` and
  `nested-helper-seeded-runtime-check.json` each record alias/direct exit 1
  with `Error: safe R1 was not latched as requested`. These are not runtime
  passes and do not establish a renewed AMFI launch failure.
- `nested-resource-signing.log` records an unsigned `mlx.metallib` subcomponent
  rejection before subsequent helper/outer re-signing. Kernel placement and
  signing must be qualified with the helper, not inferred from `--version`.
- `nested-resource-runtime.json` records the later pass:
  `gemma-optimizations-runtime-smoke: ok` and
  `paged-kernel-runtime-smoke: ok`.

Retained evidence SHA-256 values at documentation review:

```text
nested-helper-control.log
5382e641400700e09c0262595967d4f0962e737028035b322447df20965d00bf
nested-resource-runtime.json
0ef5269cc9e4a828d8bea22092d8f8ac773ccd0b4f0a409c769b3378d62392d0
```

## Implementation contract checked

The working tree implements the helper layout in
`scripts/bundle-macos-app.sh` and stages real SwiftPM resource bundles in
`scripts/stage-swiftpm-resource-bundles.sh`. The workflow signs canonical
nested metallib/enclave code, seals the provisioned helper with provider
entitlements, copies the signed compatibility payloads to the outer app for
byte parity (including metallib signature attributes), and seals the outer
GUI with network-only entitlements.

Installer, updater, and coordinator readers admit only the exact outer CLI
alias and regular nested targets; nested/outer metadata and profiles match,
and signed payload hashes agree across the nested, outer, and `bin/` views.
`ManagedProviderInstallLayout` and `ManagedProviderCLIPathValidator` provide
the real managed path for GUI and services with no-follow validation. Legacy
regular CLI fallback requires an absent helper; malformed helpers fail closed.
The [app release runbook](../operations/app-release.md) owns the live layout,
signing order, archive policy, and release checklist.

The local `origin/master` ref inspected was
`9c107e7b2b8a0b92a955e43ca13301395339742f`; it did not contain
`provider-swift/Sources/ProviderCore/Update/ReleaseArchivePreflight.swift`.
That strict reader belongs to the app branch. Earlier preview readers may
need the updated installer, but this does not imply a universal bridge release.
Deployed legacy readers still require their own exact-version upgrade and
rollback qualification.

## Remaining gates and final source stamp

| Gate | Status at this report |
|---|---|
| Local helper direct/alias launch; colocated Gemma/Paged kernel smoke | Passed for the recorded probes |
| Actual model inference, signed relocation, managed launchd lifecycle, update/rollback from each deployed reader | Not established by these probes |
| Persistent Secure Enclave key reuse and successful APNs code identity | Pending live qualification; launch/kernel success is insufficient |
| Final-artifact notarization, stapling, Gatekeeper, and MDM/MDA enrollment | Pending; no release approval implied |

The source stamp is the candidate base, plus concurrently edited helper-layout
files inspected in `/Users/gaj/.codex/worktrees/e943/d-inference`; it is not a
committed final implementation or a hash of a shipping archive. After the
workers finish, recheck and stamp the canonical docs against the final commit,
then retain qualification results for the exact signed distribution artifacts.
No builds, native UI launches, source/script edits, or commits were performed
by the documentation pass. Documentation lint is reported with the handoff,
not treated as signed-release qualification.
