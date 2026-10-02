# Next benchmark recording seam

Keep the first worker26.2 build unchanged. The next isolated increment should expose a small value-only recording SPI on the owned resident facade, and use the existing experimental full-model executable for the first independent generation reference. No implementation is included in this map.

## Resident candidate

Map the frozen nine-file `generation-final-diagnostics-overlay-20260915/integration.json` into the shared Runtime target: eight additions and the one generation Driver replacement. Its serving function remains the same call with diagnostics:nil. All model, tensor, Plan, reservation and allocator types remain internal.

Use a benchmark-only SPI pair for recording reservation/start, plus recording readiness with the correct local ceiling. `reserveRecording(requestID:request:)` derives the base allowance through the existing owner, derives the frozen diagnostic extra host/native terms with actual allocation bounds, checks the combined named charge against the caller ceiling and stores recording mode plus the original base separately. Recording Ready advertises the matching maximum combined ceiling, only while the existing owner is ready. The parent charges both returned rank totals using its existing mechanism. Do not silently add capture storage to a normal base-only reservation; live OS checks are not a substitute for the caller ceiling.

`@_spi(Benchmark) public startRecording(requestID:onCommittedToken:)` then returns a small SPI wrapper containing the existing `QwenResidentGenerationCompletion` plus bounded CPU `Data` from `QwenGenerationDiagnosticEvidence.encoded()`. It must use that matching recording reservation; it must not accept a caller-supplied numeric base allowance or model callback. The original base remains necessary for the diagnostic driver's exact rederivation. Named capture/encoding allowances and existing headroom still are not a whole-process peak proof.

The exact seam is `QwenResidentRuntime.start` in the final policy build. Keep the operation lock, matching reservation, `control.start`, lifecycle lease, autorelease scope, request/source/build/Plan agreement, live check and callback ordinal logic. At the one driver call choose:

- serving: existing `runQwenLayerStageGenerationRequest`;
- recording: `recordQwenLayerStageGenerationRequest`, passing actual `stage.loaded`, `stage.profile`, `admission.plan`, actual collective/agreement and `reserved.allowance`.

Use a private shared execution helper in this same file so the two public entry points do not duplicate lifecycle or failure logic. `stage`, `reservation` and `lifecycle` are private; adding a separate extension file must not be used as a reason to expose those fields. The recording driver rederives the exact registered rank/request allowance and adds capture bounds before state allocation. The recording reservation must account for these named capture terms before start; no permissive extra resource callback is needed.

The driver captures rank1's final row after the final decision ACKs, captures both rank states before local finish, and only returns CPU evidence after bilateral retirement. After `lifecycle.withRequest` returns, encode that evidence, then perform `control.completed` and clear the reservation. An encode/output preparation failure must follow the existing fail/withdraw path; do not advertise capacity early. Normal serving skips capture and encoding. Callback false remains a clean stop; callback throw remains a failure requiring the outer peer fence.

The smallest first caller is a private benchmark derivative of `NativeWorkerRuntime` that invokes the SPI and retains/writes the returned CPU sidecar through an explicitly bounded exclusive sink. Reuse the existing worker command coordinator and pipes without new protocol keys. Sidecar publication failure is an operation failure; it cannot synthesize a clean retired event. Pin the completed sidecar along with original worker events. This can remain a small isolated benchmark overlay while a later package cleanup shares worker front-end code; do not copy the runtime or create a second control protocol.

The frozen serving worker has no diagnostic sink and no diagnostic request flag. Do not retrofit the sidecar into its Ready/result records or enable capture by default. Parent numerical validation consumes both retained rank sidecars after terminal retirement and source checks.

## Independent full reference

The minimal first caller stays in the existing experimental executable, whose source already owns `LoadedModel`, the full verified loader and full CBv2 session. Integrate the five reference files and additive `CBv2RequestSession.finishGeneration` from frozen full-reference overlay6b658a4, replacing Request with the separately corrected native-error V2 file6c2ae8d. These are six source changes, not a new loader.

Use the ownership pattern in `QwenLongPrefillReferenceProducer.swift:9–50`: scoped `loadVerifiedQwenLayerStageBaseline`, weak model tracking, autorelease scope, synchronize and weak-release proof, cache clear, and primary-error-preserving cleanup. In that loaded scope call `runQwenGenerationReference(loaded:admission:admitResources:check:)`. Emit a new generation-result schema; the helper reports request retirement and modelRemainsResident because the outer producer still owns the model. Only the outer completed wrapper may report model release.

The old CLI is not reusable unchanged: `QwenLongPrefillReferenceCLI.validateOptions` requires output1, and `preflight` invents a fresh UUID. The new bounded private entry must retain the raw prompt pin and common caller-supplied request UUID, construct the existing source admission with that UUID, then construct the exact same GenerationRequest/profile/output count/stop IDs as the candidate. Keep the selected Plan/cut identical for source identity. Do not call the old output1 request function or relabel its receipt as an O128 allocation permit.

Initial reference scope remains registered9B,8192 prompt,chunk512,output1...128,BF16,greedy,MTP off. At O128 it executes16 prefill plus127 decode frames and ends at committed frontier8319 if no earlier EOS. The current reference admission explicitly refuses other chunk sizes; a later smaller-chunk study needs a separately reviewed reference admission change.

`admitResources` is a real missing owner hook, not an optional stub: derive actual allocation bounds for the named P+O state/boundary terms, full-model fusion and capture temporary row, allow the two CPU rows, account for already loaded full weights and existing headroom, and preserve6GiB/zero-swap/power/thermal/deadline checks. Reuse actual checked arithmetic and allocator APIs; do not reuse the stage-only allowance or short3-token admission. The full materializer already has `beforeTensor`; the legacy baseline wrapper currently supplies native-error checks only during load. If in-process per-tensor OS/deadline sampling is required, thread that existing hook through a narrow full-load wrapper while retaining legacy storage caps. The hard parent sampler/deadline is still required for blocked native work.

Do not import `ModelLoading.swift` wholesale into the shared serving library: `LoadedModel` also names direct-shard/partition/Gemma fields and that file owns broad Options dispatch. A later shared full-owner move needs a separate narrow extraction and native closure check. The24-source Foundation fixture list is not the full native source closure. The first experimental reference entry reuses the already present closure and does not create another full-model implementation.

## What the new comparison can establish

Join exact raw prompt/request/profile/output/stop policy, source/configuration, selected Plan, BF16/arithmetic and actual final frontier. Compare selected token history and finish reason, the last full row (with the retained policy), and the disjoint global state-entry union. The candidate has only final logits; reference per-token compact row hashes do not establish comparison of intermediate candidate rows. Candidate agreement-bound token-chain SHA and reference plain token-ID SHA are different recipes. State bytes are still not exported independently.

These are correctness diagnostics. Full-reference continuation timestamps include prior evidence capture; candidate recording includes capture/validation work. Neither is serving external TTFT or a throughput benchmark. Keep the existing text-streaming measurement separate. The new physical cut4 output-one baseline does not qualify these new128-token helpers.

## Required next checks

1. Typecheck the nine-file diagnostic overlay and the single private facade dispatch against the actual shared module. Preserve serving nil-diagnostic call bytes and ownership/error order.
2. CPU cases use fake driver/sink boundaries to prove no early capacity/retirement on capture or encode failure, and unchanged normal callback/stop paths. The existing diagnostic20/28 and reference7/24 fixtures remain separate evidence.
3. Build the private full-reference entry on the existing native closure; real resource hook and raw request pins are mandatory. Run a guarded small output count before128, then both rank sidecars plus independent full reference under the same request identity.

Only source and retained metadata were read for this map. No source edits, compiler, model, GPU or SSH execution, or current candidate-output access occurred. Pins below bind the inspected source only.
