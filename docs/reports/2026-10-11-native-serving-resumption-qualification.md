# Native loaded-engine endpoint resumption qualification

> Last updated: 2026-10-11

The isolated Stage C signed provider passed the full-router native resumption
gate on an Apple Silicon Mac: encrypted inference before and after a
125.001-second transport break, without another model load, engine replacement,
process-key change or Apple assertion. This is local candidate evidence, not a
production release, fleet approval or Stage D worker-recovery qualification.

## Qualified identities

| Input | Exact value |
|---|---|
| Provider source | `847691126bbab642f8f5ef31865fb90e85aaf48f` in `Layr-Labs/d-inference` |
| Provider tree | `fd935211dcc3be6a61ce9a063bbeb5cdc9b202be` |
| Platform/harness source | `90f1c5f92b33158bc0c6ce75bf168ca72e751174` in `Layr-Labs/darkbloom-platform` |
| Platform tree | `c44dbe40027f15dcadb33604f5d4d347221d8ecb` |
| Provider version | `0.9.19`, unchanged |
| Signed executable SHA-256 | `8d057a7aeeebed9881ba65f3159803947e0321b541d739201fdfff78012008a1` |
| Full SHA-256 CodeDirectory hash | `813a13073a23dc76292322dbb4f8229ea234934e95627a8d4bdc71690ecfdc31` |
| Loaded metallib SHA-256 | `fb1ba8f90b9f1cc346246b7240c3986771464bd977c67f0ef03186811f16c85c` |
| Local model ID / revision | `local/Qwen3.5-9B-MLX-4bit-MTP` / `1-mtp-inline` |
| Model aggregate SHA-256 | `e37ad6bd9e24102c0821764cee7267ccdb93f6dfe8f58acd95c311d6726447cf` |
| Host | `Mac16,5`, macOS `27.0.1`, `137438953472` physical RAM bytes (128 GiB) |
| Toolchain | Xcode 27, Apple Swift `6.4`, linked macOS SDK `27.0` |
| Signing | Developer ID Application: Eigen Labs, Inc.; team `SLDQ2GJ6TL`; identifier `io.darkbloom.provider`; hardened runtime |

Source-matched dependencies were `mlx-swift` at
`6923a80f624f5c91fbf456efe4e00e9698a72961`, its nested MLX at
`cb77239be31b1df7f5db895226af55c39fc4f093`, nested mlx-c at
`02cf6f4d099023e4e0c0357248b8b3f83110e29d`, and `mlx-swift-lm` at
`3fd4944c3b3ee5cb45c5cbfac8805876332d3a29`. The unused top-level MLX submodule
was not initialized. No release version was assigned or bumped.

The machine-readable [result record](evidence/native-serving-2026-10-11/result.json)
contains only nonsecret identities, scalar measurements and passed assertions.

## Actual result

`TestSignedProviderLoopLoadedEngineResumption` passed in **178.67 seconds**
(Go package elapsed **179.356 seconds**).

| Check | Observed result |
|---|---|
| Initial identity | Real Apple enrollment/assertion accepted by the full Go coordinator, with the provider's real ephemeral Secure Enclave verification key |
| First inference | Successful sealed consumer request/response and encrypted provider request/chunks, with nonempty generated content and completion usage |
| Live interruption | Request-specific encrypted generation chunk, fresh native inflight observation and coordinator first-content ingress preceded the cut |
| Network outage | **125.001 s** of refused provider transports; coordinator/store and provider process remained running |
| Reconnect delay | **20.599 s** from reopening the fault gate to the replacement WebSocket |
| Interrupted request | HTTP **502**; real nonzero balance reservation finalized; exactly **one** matching full refund; no successful usage charge |
| Request cleanup | Fresh post-cut native inflight count **0**, old provider pending count **0**, old terminal replay count **0** |
| Resumption | New connection with original proof session, issue time, credential and endpoint; expiry no later than the matching policy cap observed immediately before the first cut |
| Process / endpoint | PID plus kernel start time and process endpoint hash unchanged |
| Model / engine | Model instance and unique engine-bundle identity unchanged; load count remained **1**, loaded model count **1** |
| Apple assertion counter | **1** before and after resumption; no additional App Attest shadow challenge on reconnect |
| Replacement readiness | Fresh capacity on the new connection, followed by an advancing capacity sequence |
| Second inference | Successful encrypted inference through the same loaded engine |
| Cleanup | Graceful diagnostic completion, captured child reaped, scoped LaunchServices registration restored |

The outage measurement excludes the reconnect backoff, second inference and
shutdown. Fresh sequence/timestamp checks prevent an old `inflight=0` or old
model snapshot from satisfying a post-cut or post-inference assertion.

## Isolation and trust

The hidden diagnostic called the real `ProviderLoop.run`, its normal
`CoordinatorClient`, registration `AttestationBuilder`, security-hardening path,
startup preload and MLX engine. It created its own real ephemeral Secure Enclave
signer and process encryption key; the harness could not supply keys, signatures,
hardware/privacy claims or a binary hash to the provider. Apple's real service
used bounded in-memory key-ID/budget storage. No software credential, inserted
Apple key, fabricated trust grant or skipped challenge was used.

The loopback coordinator used a real in-memory store and distinct synthetic
provider/consumer accounts. It seeded exact local release/runtime/model facts
and explicitly enabled the candidate App Attest serving/resumption policy only
inside that coordinator. A real billing service with an empty configuration
enabled ledger accounting without mock mode, Stripe credentials or external
payment rails. Platform/provider price rows and the actual reservation
calculator were checked in a CPU-only test before the successful native launch.

The app ran from its isolated `.build` bundle. Private inputs/state and `TMPDIR`
were constrained to the run directory. Installed auth/config, persistent SE
signing keys, `Start`, `ServiceDrain`, launch agents, APNs registration, update
installation and automatic installed-service stall restarts were not used.
Live memory protection used the normal MLX ceiling and pressure monitor with
private marker/watermark paths. MTP and prefix caching were explicitly off;
normal OS, activation and KV admission safeguards remained intact.

The existing authorized provisioning profile was copied only into the staged
app. Requested App Attest/team grants were checked against that profile, then
the final app was signed and verified before the harness's scoped public
LaunchServices registration. No OS security setting, RDMA configuration,
installed daemon, production coordinator, account or release was changed.
RDMA was enabled on this Mac and reported truthfully; it was not treated as a
restriction or worked around.

## Preserved failed attempts

The same signed provider was used in all three attempts. Two earlier harness
failures did **not** establish the complete native gate:

| Attempt | Duration | Failure and disposition |
|---|---|---|
| Initial harness | 48.94 s | Apple authorization, first encrypted inference, live cut, 502 and native cleanup passed; reservation-finalization assertion failed because the coordinator had no billing service and intentionally made requests free |
| Positive-price precondition | 29.03 s | The strengthened nonzero-reservation assertion failed before the cut. A blank-account price row was not the platform price, and nil billing still bypassed reservations |
| CPU-preflighted paid ledger | 178.67 s | Passed the complete native gate with real billing enabled, separate authenticated owners, correct platform/provider price rows, positive reservation and exactly-one-refund checks |

These were local harness assembly errors, not product resumption failures. The
positive-reservation, cleanup, refund and two-minute break assertions were kept,
not removed to obtain a pass. No proof/verifier policy was weakened.

## Reproduction and validation

Build in an independent worktree with the dependency pins above. The successful
optimized build used:

```bash
env GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
  swift build -c release --build-system native --skip-update \
  --disable-automatic-resolution --disable-keychain --disable-netrc -j 4
```

`scripts/fetch-metallib.sh` supplied the source-matched metallib.
`scripts/provider-signing-validation.py stage` staged the release products and
SwiftPM bundles; `scripts/prepare-app-attest-entitlements.py` derived App Attest
grants from the authorized profile. The staged entitlements also included that
profile's `com.apple.developer.team-identifier` grant. After signing the helper,
metallib, enclave executable, main executable and app, `codesign --verify
--deep --strict` passed. No new notarization or publication was performed.

The successful native command, from the platform repository, was:

```bash
env DARKBLOOM_RUN_NATIVE_SERVE=1 \
  DARKBLOOM_RUN_NATIVE_APP_ATTEST=1 \
  DARKBLOOM_NATIVE_QUALIFICATION_APP="$PROVIDER_SOURCE/provider-swift/.build/native-serve-847691126/Darkbloom.app" \
  DARKBLOOM_NATIVE_MODEL_SNAPSHOT="$HOME/.cache/huggingface/hub/models--local--Qwen3.5-9B-MLX-4bit-MTP/snapshots/1-mtp-inline" \
  go test ./coordinator/tests/appattest/nativequalification \
  -run '^TestSignedProviderLoopLoadedEngineResumption$' -count=1 -v -timeout=15m
```

The test creates its own `0700` inputs and synthetic token; its child receives
`DARKBLOOM_NATIVE_SERVE_QUALIFICATION=1`. Never replace these resources with a
production URL/token or point the app variable at the installed provider.

Focused validation also passed: four native Swift guard tests; 27 focused
Swift/XCTest guard, OOM, pressure and stall/lifecycle checks before the final
identity-only addition; five CPU-only Go harness tests under `-race`; provider
documentation/impact/changelog checks. Independent safety/refactor rechecks
closed bounded-file, real-progress, snapshot freshness, interval measurement
and failed-drain lifetime findings before the successful launch.

This one-model B=1 target-only result does not qualify MTP, SSD persistence,
APNs, installed-service replacement, cross-process continuity, a coordinator
restart, Stage D worker recovery, fleet deployment or a future differently
signed binary. Those remain separate gates.

## Final coordinator rerun

`TestSignedProviderLoopLoadedEngineResumption` passed again against final
coordinator source `99bec4f3ae97b2d496ad7e3dae2c01617c3d003b` in **165.30 seconds**
(Go package elapsed **165.897 seconds**). This is a separate native run; the
initial result and failed fixture attempts above remain unchanged. Its
machine-readable evidence is appended under `reruns` in the
[result record](evidence/native-serving-2026-10-11/result.json).

| Input | Exact rerun value |
|---|---|
| Platform/harness source | `99bec4f3ae97b2d496ad7e3dae2c01617c3d003b` |
| Platform tree | `809ce74f225573d604639bf4d3763205f4ddbfac` |
| Provider integration source | `d3d2038d720735c5333a1ab96d4570f4146bd058` |
| Artifact's qualified provider source | `847691126bbab642f8f5ef31865fb90e85aaf48f`; tracked `provider-swift/`, `libs/` dependency gitlinks and `scripts/` are byte-identical at the integration source |
| Reused signed executable SHA-256 | `8d057a7aeeebed9881ba65f3159803947e0321b541d739201fdfff78012008a1` |
| Full SHA-256 CodeDirectory hash | `813a13073a23dc76292322dbb4f8229ea234934e95627a8d4bdc71690ecfdc31` |
| Model aggregate SHA-256 | `e37ad6bd9e24102c0821764cee7267ccdb93f6dfe8f58acd95c311d6726447cf` |

The same signed artifact was reused, not replaced by a newly qualified binary
from later provider merges. The source comparison was
`git diff --exit-code 847691126bbab642f8f5ef31865fb90e85aaf48f d3d2038d720735c5333a1ab96d4570f4146bd058 -- provider-swift libs scripts`
and produced no differences. The qualification checkout retains the operational
log at `provider-swift/.build/native-serve-847691126/native-run-final-platform-99bec4f3.log`;
raw credentials, proof blobs and inference content are not copied into this record.

| Check | Final coordinator rerun result |
|---|---|
| Transport break / reconnect | **125.001 s** of refused transports; **4.281 s** from reopening to the replacement WebSocket, measured separately |
| Encrypted inference | Successful consumer request/response and provider request/chunk encryption in both directions before and after the break |
| Process / endpoint / engine | Same PID and kernel start, endpoint key `K`, model instance and engine-bundle UUID; load count and loaded-model count remain **1** |
| Apple proof | Assertion counter remains **1**; custody-only reconnect preserves original proof identity and bounded expiry |
| Interrupted request | HTTP **502**; positive real balance hold finalized and refunded exactly **once**, matching the full reservation; no usage record or successful charge |
| Request cleanup | Fresh native inflight count **0**, old pending count **0**, old terminal replay count **0** |
| Replacement readiness | Fresh capacity followed by an advancing capacity sequence |
| Process cleanup | Owned child reaped; scoped LaunchServices registration restored |

This rerun qualifies the recorded Stage C transport-break scenario against the
final coordinator revision, not a general rollout matrix. Sleep/wake, reboot,
security-setting transitions and full loaded-engine Stage D callback recovery
remain unqualified by this run. It does not approve a release, deployment,
environment change or later differently signed provider. The initial one-model,
B=1 target-only scope and other limitations above still apply.
