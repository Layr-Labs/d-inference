# Registered 8K rank flow draft

Source-only, seven new Swift files. No existing source was modified and no Swift build, MLX execution, model payload read, SSH or native process operation was performed by this author. Root owns integration, loaded-stage/CLI admission, early arithmetic environment, collective creation, model release, parent supervision and native qualification.

```swift
func runQwenLongPrefillRankRequest(
    loaded: LoadedQwenLayerStage,
    local: QwenRegistered9BLongPrefillReferenceAdmission,
    agreement: QwenLayerStageProfiledPrefillStartAgreement,
    collective: Collective,
    onReady: () throws -> Void = {},
    check: () throws -> Void
) throws -> QwenLongPrefillRankRequestResult
```

The local admission is exactly registered9B/BF16, 8192/512/output1, 16 frames and no teacher tokens. The entry first reuses `QwenLayerStageProfiledComputeAdmission`, creates its own new v4 transport, then exchanges the separately namespaced readiness digest. The exact material is UTF8 `qwen-profiled-prefill-readiness-v1|<agreement fingerprint>`; its lowercase SHA256 hex characters are sent as 64 Int32 values/256 bytes. Rank0 sends then receives; rank1 receives then sends. Both peers have admitted their loaded local models before this exchange, and neither request context exists. The returned readiness record's `readinessMaterialSHA256` is the digest of that material, not a digest of the Int32 wire bytes.

`onReady` runs after the readiness exchange and its completed trace but before either start operation, rank0's clock or fresh request-state construction. A callback failure preserves the original error and retires the transport; the external parent must fence the peer. The callback itself is not timed.

Rank0 reads `DispatchTime.now().uptimeNanoseconds` immediately before `sendStart`. Rank1 validates the full start packet before creating its fresh context; rank0 also waits for its synchronous send completion. The existing profiled compute initializer repeats its actual source/history admission inside this interval; that cost is explicitly included. One fresh profiled owner remains the sole model/state implementation.

For each frame, the sender owns one `QwenLayerStageProfiledPrefillPrepared`. It passes the complete value to the v4 transport. After the peer's actual received ACK, an autorelease scope ends, the Prepared variable is nil, and the weak original MLXArray wrapper must be nil. Only then may lookahead prepare the next chunk. Both policies drain the exact pending consumed ticket before another header. Serial prepares after the predecessor drain; lookahead prepares before it. There is one prepared native boundary and one CPU-only pending ticket at most, with no added payload copy. Expected ahead counts are0/15 for serial/lookahead, and original-wrapper release counts16 for each rank. This does not prove absence of all underlying storage aliases.

The known receiver callback consumes the actual received boundary, returns only a CPU commit and optionally the actual final finite argmax token receipt, and never returns an MLXArray. The v4 transport retains the owned receive payload through consumption and checks original-wrapper release before consumed ACK. On the last frame, native argmax/finiteness/scalar readback and token packet validation finish before that ACK.

After all16 consumed boundaries, rank0 receives and validates the actual token packet, then records stop. No diagnostic snapshot or post-stop release starts before that timestamp. Rank1 sends only the saved validated token, then waits for the exact token-bound post-stop release. Both sides finish that release before final digest capture and request close. The start-to-token interval includes start IO, fresh context, source admission within its constructor, all prompt forwards/commits, boundary checks/transfers, scalar trace and final token return. It excludes initial loading/input distribution/readiness, final captures, post-stop acknowledgement and retirement. The separate post-stop-through-request-close observation excludes later stage-model release and cache clearing owned by root. It remains a diagnostic, not qualified throughput or a kernel timer.

The successful CPU result namespace is `qwen_long_prefill_rank_request`, schema1. It retains profile/agreement/identity, readiness, per-frame CPU commits and exact v4 envelope UTF8 JSON, distinct envelope fingerprint and raw-wire SHA, scalar actions, selected token plus exact packet JSON and both packet hashes, optional local selection, and one `QwenLayerStageProfiledPrefillFinalDigest`. Rank1 has local selection/final logit metadata; rank0 omits the optional selection and its digest omits logits. Only rank0 emits timing. No candidate raw logit row, state byte history, model, array or closure escapes. Numerical comparison is external; `independentNumericalComparisonPerformed=false`, `throughputMeasurementValid=false` and `physicalTransferQualified=false` remain explicit.

The nested final digest retains generic capture-time `requestStateRetirementStillRequired` and `externalPostStopOrderingStillRequired` flags. The enclosing rank result separately records the completed owner/transport lifecycle after those requirements have actually been discharged. Root must still release the loaded stage and inspect its weak model handle outside this function.

The action sequence adds `readiness.begin` and `readiness.completed` to the v3 phase spellings. With the agreed v4 hooks, sixteen frames produce204 rank0 and235 rank1 actions. Sender phases are the eight actual transport events plus two prepare actions, wrapper release and frame completion per frame. Receiver phases are thirteen actual events plus frame completion. The trace bounds exact16 frames and records real native frontier, completed-boundary count, explicit prepared slot and pending consumed slot. Sender committed tokens can lead completed boundaries by at most1024 tokens; receiver by at most512. For lookahead, the next prepare occurs after source release and before prior `beginConsumedDrain`. There is no claim that these serial scalar records establish overlap duration.

On any error, the entry poisons its owned transport and cancels the created context, including failures after native progress or caught phase/caller callbacks. Native error checks surround cancellation and any cleanup failure is appended while preserving the primary error. After a verified clean close, late errors do not redundantly cancel the retired context. The transport's CPU `retire()` cannot interrupt a blocked backend, and native synchronization/cancel may block: the external whole-cohort deadline remains necessary.

Integration uses the new `QwenLayerStageProfiledPrefillTransport` API in `long-prefill-native-wire-draft`. Its seven files and the existing integrated profiled codecs/compute owners are separate dependencies. Legacy v1/v2/v3 request, wire and admission bounds remain unchanged. Source review is not a native lifetime, numerical, memory or timing qualification.
