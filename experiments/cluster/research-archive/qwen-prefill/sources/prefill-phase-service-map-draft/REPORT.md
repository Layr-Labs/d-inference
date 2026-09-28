# Retained phase services for a bounded lookahead estimate

2026-09-14. Use the sixteen **rank0 `prepare.begin` → `prepare.committed`** durations and sixteen **rank1 `receive.beginConsumption` → `receive.consumptionAndSelectionValidated`** durations as observed stage-call service inputs. They contain no explicit inter-rank transport call. They do contain native evaluation/synchronization, validation, recorder overhead and scheduling delays; “non-wait” here means no distributed wait inside the named call, not pure CPU or GPU-kernel time. Keep each frame separately, including first-use effects and increasing KV frontier. Do not divide a stage total by its layer count to price other cuts/models.

[service-vectors.json](service-vectors.json) contains two retained cohorts, 32 frames and 64 primary local services, plus 96 optional local spans. [source-and-input-pins.json](source-and-input-pins.json) pins all 53 source/JSON inputs. Extraction joined actual action ordinals and frontiers to the sidecars, checked every primary duration against the saved passed phase audit, and rechecked input bytes. No frozen auditor, native command, compiler, SSH or model was executed. The frozen short-parity checker was untouched.

Run `python3 extract_services.py` from this directory to rebuild and compare the exact frozen vector bytes without writing files; `--emit` emits the checked vectors. The author ran this CPU-only extraction check successfully. This verifies derivation from saved evidence, not a new numerical, runtime or hardware qualification.

| Retained serial cohort | Rank0 prepare total | Rank1 consumption total, including final selection | Rank0 existing first-token interval |
| --- | ---: | ---: | ---: |
| Registered9B, 16/16, phase only | 9.372237458 s | 9.314684249 s | 18.784448750 s |
| Registered9B, 12/20, phase + frame7 owner tracing | 7.038334333 s | 11.637434582 s | 18.780559667 s |

Both are two serial processes on the same peer24 GPU, using `loopback-test`/`ring`, 8192/512/1, BF16 and `serial_v1`. These are separate instrumented requests, not a controlled split-performance experiment. The second adds eight owner observations in frame7 on each rank. No independent-device speedup, representative throughput, cross-process clock alignment or transfer qualification follows from the table. The separate balanced owner cohort also exists at `runs/qwen-long-prefill-ranks-serial-owner-sidecars-20260914`; its JSON/schema was inspected but its measurements are not pooled into these vectors.

All paths below are under `/Users/developer/DarkbloomDev/cluster-research` unless stated otherwise:

| Input | Balanced 16/16 | Cut12/20 |
| --- | --- | --- |
| Native cohort directory | `runs/qwen-long-prefill-ranks-serial-phase-peer24-20260914` | `runs/qwen-long-prefill-ranks-cut12-serial-owner-peer24-20260914` |
| Sidecar directory | `runs/qwen-long-prefill-ranks-serial-phase-sidecars-20260914` | `runs/qwen-long-prefill-ranks-cut12-serial-owner-sidecars-peer24-20260914` |
| Native stdout, relative to cohort | `rank-{0,1}/stdout.jsonl` | `rank-{0,1}/stdout.jsonl` |
| Trace, relative to sidecars | `rank-{0,1}/phase-trace.json` | `rank-{0,1}/phase/phase-trace.json` |
| Saved phase audit | `phase-audit.json` in sidecars | `phase-audit.json` in sidecars |
| Saved numerical audit, relative to cohort | `independent-cpu-audit.json` | `cpu-audit.json` |
| Native parent | `receipt.json` in cohort | `receipt.json` in cohort |

The selected plan is `2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293` for 16/16 and `8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed` for 12/20. Cut12 also has `qualification-join.json` in its sidecar directory; its exact parent, numerical and phase-audit hashes were checked here. It binds a fresh qualified cut12 pair reference, not a relabeled half-split reference. Native source/runtime qualification remains the saved parent/source-correlation audit’s responsibility; numerical state values and candidate logit values retain the original oracle’s opaque-data limitations.

The relevant schema is already present. Each trace is `kind=qwen_prefill_local_phase_trace`, `schemaVersion=1`, `clockSource=DispatchTime.uptimeNanoseconds`, `maximumEvents=512`, with 204/235 events. Its `identity.requestFingerprint` is the **full recorded-history fingerprint**, and `identity.profile`/`role` select the profile and rank. Each `events[]` item has `ordinal`, `phase`, optional `frameSequence`, `committedTokens`, and UInt64 `localUptimeNanoseconds`. The base report’s `execution.actions[]` matches these through `action`, `ordinal`, `frameSequence`, `nativeCommittedTokens`; it additionally records `completedBoundaryCount`, `explicitPreparedBoundarySlots`, and `pendingConsumedFrameSlots`.

Join the exact stdout bytes to `agreementFingerprint`, `agreement.recordedRequestFingerprint`, `agreement.schedulingPolicy`, `agreement.planFingerprint`, both construction/stage fingerprints, `arithmeticEnvironmentSHA256`, and `sourceLoad` source/artifact/storage identities. A phase trace alone has no plan or hardware identity. Per-frame geometry is `execution.frames[i].commit.frame`; parse `exactEnvelopeJSON` for `boundary.byteCount` and wire identities. Each retained boundary is 4,194,304 logical bytes (`[1,512,4096]` BF16). Native sends also include a four-byte header-length transfer, the actual encoded envelope, and three 256-byte ACKs. These are logical operation sizes, not physical traffic or measured TB performance.

The following Swift paths are relative to `/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/`:

| Service or excluded span | Source and interpretation |
| --- | --- |
| Producer prepare | `QwenLongPrefillRankSender.swift:28`; calls `QwenLayerStageProfiledPrefillComputeContext.prepare`, including existing stage evaluation/commit and residual handling. |
| Consumer consume + final selection | `QwenLongPrefillRankReceiver.swift:27`, `QwenLayerStageProfiledPrefillTransportReceiver.swift:48`; final frame includes finite argmax/scalar return and token-packet validation. Do not add a second final-selection service. |
| Optional producer pre-header local work | `prepare.committed` → `send.beginHeader`; sender validation and `QwenLayerStageProfiledPrefillTransportSender.makeEnvelope` include another `asData(access: .copy)`/payload-hash validation before any header IO. Totals are 28,741,499 ns and 29,220,710 ns. **Use only from serial inputs with adjacent same-frame markers**: lookahead can place a prior-frame consumed drain inside this marker gap. |
| Optional producer release | `send.receivedACKAccepted` → `producerBoundaryReleased`; original-wrapper/Prepared release and guards. |
| Optional consumer release | `receive.consumptionAndSelectionValidated` → `receive.consumedBoundaryReleased`; inner autorelease scope and weak-wrapper guard. |
| Exclude from portable measured services | All header send/receive, ready/received/consumed ACK, payload and start/token control spans cross `QwenLayerStageProfiledPrefillNativeIO` completed collective calls. They combine transfer, blocking, native synchronization, copying and/or validation. |

`QWEN_PREFILL_PHASE_TRACE.md`, `QwenLongPrefillRankTrace.swift:16`, `QwenLongPrefillRankResult.swift:32`, and `Tracing/QwenPrefillPhaseTypes.swift` define the clock/DTO limits. Rank1 has no primary request clock. Rank0 `execution.timing.elapsedNanoseconds` excludes model loading, readiness, post-stop diagnostics and retirement. Never subtract cross-rank timestamps or subtract summed stage times from this interval and call the remainder network latency. In the balanced serial trace, rank0 consumed-drain waits total 9.3183 s and rank1 header receives total 9.4109 s because these waits substantially include peer computation.

A minimal adapter can reuse `phase-clock-audit-draft/phase_clock_audit.py::check_pair` or its already passed pinned output, and select `ranks[].intervalGroups` named `stage0_prepare_cpu_observed` and `stage1_consume_and_final_selection_cpu_observed`. Preserve `intervals[].frameSequence`, `startPhase`, `endPhase`, `startOrdinal`, `endOrdinal`, `elapsedNanoseconds`. Reuse existing bounded parsing/identity checks; add only the explicit saved-parent/numerical/source join and service projection. Optional local gaps need the adjacent-marker/serial restriction above. The adapter must retain instrumented cohort, native/source/plan/device identity and point-observation provenance; it must not mint independent resource or numerical qualification.

For the prospective bounded schedule, represent producer prepare, pre-header work, handoff, producer release, consumer service/release, and consumed-ACK drain separately. `QwenLongPrefillRankSender.swift:35–74` permits one prepared residual and one pending consumed ticket. In lookahead, frame i+1 preparation starts after frame i’s received ACK and producer release, **before** draining consumed ACK i. Its next header still waits for that drain. The receiver consumes only one frame at a time. Serial adds consumed-drain completion before the next preparation. A greedy DAG schedule should preserve these dependencies and bounded slots; a formula that overlaps arbitrary producer/consumer queues does not model this protocol.

For the observed single-GPU case, retain that shared-device resource constraint; the traces do not quantify how concurrent requests contend or demonstrate GPU overlap. An independent-device projection must explicitly assume transferable service times (or supply target-specific measurements), assign distinct devices, and supply bounds for each unmeasured communication/uncovered-local operation. Evaluate the fixed 16-frame DAG at those supplied bounds. Without finite bounds, leave the projected upper makespan unknown. A zero-communication case is an explicitly hypothetical compute-only scenario, never an observed TB latency. The single recorded service samples also supply no statistical confidence interval or guaranteed runtime bound.

The ten cut12 marker/DTO/transport source files pinned here are byte-identical to their current counterparts. Seven of ten balanced phase files are identical; its sender/receiver/context differ only by the later optional owner-observer plumbing. Historical whole-file Check/Main pins are not asserted to match the current executable: retain the cut12 cohort’s `trace-source-compatibility.json` and `source-correlation.json` overlay instead. No production schema or hook change is needed for this first adapter.
