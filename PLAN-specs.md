# Fix Specs (build-ready detail)

## provider-structured-admission-reason — Provider emits structured admission-rejection reason (request_too_large vs capacity_busy) so the coordinator never guesses from a stale heartbeat
- **Layer:** provider-engine  ·  **Effort:** M  ·  **Deps:** []

**Summary.** Today the engine collapses every admission failure into "token_budget_exhausted…"/HTTP 503; the coordinator (classifyRejection in inference_failure_class.go) must infer deterministic-vs-transient by comparing a STALE heartbeat budget (ActiveTokenBudgetMax) against the model context, which the file's own comment (lines 148-159) calls unsound. This fix moves the decision to where the truth lives: the provider, which knows its own hardware ceiling. The provider compares the request against a memory-pressure-BLIND node ceiling (UnifiedMemoryCap.kvBudgetBytes / kvBytesPerToken — full 90% RAM minus THIS model's weights, NOT live MLX usage) and the model context, then ships a structured InferenceErrorMessage.error_reason enum (request_exceeds_context | request_exceeds_node | capacity_busy | invalid_request) plus reserved_tokens / node_max_budget_tokens / model_context numbers, on BOTH the batched submit path and the non-batched VLM reserveVisionRequest path. The coordinator trusts the explicit reason and skips its stale-snapshot heuristic when present, while keeping the existing string heuristic as the fallback for old providers that don't send the field.

**Files:**
- `provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift` — Add a memory-blind node-ceiling helper: func nodeMaxBudgetTokens() -> Int { guard kvBytesPerToken > 0 else { return 0 }; let kv = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: UInt64(max(0, modelWeightBytes))); return Int(min(kv, UInt64(Int.max))) / kvBytesPerToken }. This is dynamicTokenBudgetMax's formula WITHOUT the 1024 floor; it ignores MLX live pressure by construction because kvBudgetBytes subtracts only this model's weights from the 0.90xphysical cap (verified UnifiedMemoryCap.swift:102-113). Add one classification helper classifyAdmission(promptTokens:requestBudget:message:) -> SchedulerRejection used by BOTH submit paths. Rule: promptTokens > maxContextLength(>0) => request_exceeds_context (fleet-wide deterministic); else requestBudget > nodeMaxBudgetTokens()(>0) => request_exceeds_node (this node can never fit it at full memory, but a bigger box might); else => capacity_busy (fits the ceiling, not the live budget right now). Replace the four bare continuation.yield(.error("token_budget_exhausted: ...")) sites in submitTokenized (~1907-1925, 1984) and submit (~2096-2117, 2182) so each carries the structured tuple. The human string stays identical for old-coordinator compatibility.
- `provider-swift/Sources/ProviderCore/Batching/BatchQueuePlanner.swift` — admit() (~302-307) already distinguishes requestExceedsActiveTokenBudget vs requestExceedsBatchTokenBudget; keep both. No structural change needed if classification happens in BatchScheduler at the call site (preferred, keeps the planner pure). The planner rejection reason is mapped to a SchedulerRejection by the scheduler which holds nodeMax/modelContext; queueFull => capacity_busy, invalidTokenCount/duplicateRequestID => invalid_request.
- `provider-swift/Sources/ProviderCore/Inference/BatchSchedulerTypes.swift` — Keep errorMessage(for:) (string unchanged). Add enum AdmissionReason: String { requestExceedsContext='request_exceeds_context'; requestExceedsNode='request_exceeds_node'; capacityBusy='capacity_busy'; invalidRequest='invalid_request' } and struct SchedulerRejection { reason; reservedTokens; nodeMaxBudgetTokens; modelContext; message }. Add static func rejectionReason(for:requestBudget:promptTokens:nodeMax:modelContext:) -> SchedulerRejection mapping each BatchRejectionReason.
- `provider-swift/Sources/ProviderCore/Inference/BatchSchedulerTypes.swift` — Add a GenerationEvent.error overload carrying SchedulerRejection (keep the existing case error(String) for legacy mid-stream .error sites to avoid a wide blast radius). Only the admission sites use the structured overload.
- `provider-swift/Sources/ProviderCore/Inference/MultiModelBatchSchedulerEngineError.swift` — Add case requestTooLarge(String, reserved: Int, nodeMax: Int, modelContext: Int) (non-retryable, maps 413) for request_exceeds_context. Keep tokenBudgetExhausted for capacity_busy AND request_exceeds_node (both retryable/failover-able). Add fromSchedulerRejection(_ r: SchedulerRejection) used by the structured submit paths so it does NOT re-parse the human string; keep fromSchedulerMessage(String) for legacy .error(String) events. errorDescription unchanged for existing cases.
- `provider-swift/Sources/ProviderCore/Inference/MultiModelBatchSchedulerEngine.swift` — VLM path (~226-235): reserveVisionRequest returns Bool. Before throwing, compute the verdict from kvTokens (prompt+vision+output, already clamped to context at 223-225) and scheduler.contextLength()/scheduler.nodeMaxBudgetTokens(): prompt+vision span > contextLength => throw .requestTooLarge (request_exceeds_context, 413); else kvTokens > nodeMax => throw .tokenBudgetExhausted carrying reason=request_exceeds_node; else throw .tokenBudgetExhausted carrying reason=capacity_busy. Add the scheduler accessor nodeMaxBudgetTokens (actor-isolated).
- `provider-swift/Sources/ProviderCore/ProviderLoop+ErrorMapping.swift` — Add case .requestTooLarge: return 413 to the MultiModelBatchSchedulerEngineError switch (single status producer mapInferenceErrorToStatus). tokenBudgetExhausted stays 503, requestRejected stays 503.
- `provider-swift/Sources/ProviderCore/Inference/InferenceErrorClassifier.swift` — Add companion classifyAdmission(_ error: Error) -> (reason: String, reserved: Int, nodeMax: Int, modelContext: Int)? that pattern-matches MultiModelBatchSchedulerEngineError.requestTooLarge/tokenBudgetExhausted to extract the structured reason+numbers. Leave classifyInferenceErrorReason (jinja_*) untouched; admission reasons are distinct.
- `provider-swift/Sources/ProviderCore/ProviderLoop.swift` — At the inferenceError send sites (the streamChatCompletionFrames catch ~1302-1307 and the other admission sites listed at 932/991/1009/1026/1082/1126/1201/1439/1484), populate the new fields: if classifyAdmission(error) returns non-nil, set errorReason to its reason and the numeric reserved_tokens/node_max_budget_tokens/model_context; else keep classifyInferenceErrorReason (jinja_*) and leave the numbers nil. statusCode already comes from mapInferenceErrorToStatus (now 413 for requestTooLarge).
- `provider-swift/Sources/ProviderCore/Protocol/Messages.swift` — InferenceError struct: add public var reservedTokens: Int?, nodeMaxBudgetTokens: Int?, modelContext: Int? (Optional => omitted on wire when nil). Add CodingKeys reservedTokens='reserved_tokens', nodeMaxBudgetTokens='node_max_budget_tokens', modelContext='model_context'. Update the inferenceError encode block AND decode block (563-569) with encodeIfPresent/decodeIfPresent. Update the .inferenceError factory used by send.send(.inferenceError(...)) to accept the new optional args defaulted nil so existing call sites still compile.
- `coordinator/protocol/messages.go` — InferenceErrorMessage (308-314): add ReservedTokens int64 `json:"reserved_tokens,omitempty"`, NodeMaxBudgetTokens int64 `json:"node_max_budget_tokens,omitempty"`, ModelContext int `json:"model_context,omitempty"`. The decode at 603-606 (json.Unmarshal) needs no change.
- `coordinator/api/inference_failure_class.go` — classifyRejection (160): add an explicit-reason short-circuit at the TOP, gated by an env kill-switch: request_exceeds_context => rejectionDeterministicUnservable (stop on attempt 1, fleet-wide); request_exceeds_node => rejectionTransientCapacity (this-node-only, fail over to a bigger box, capped); capacity_busy => rejectionTransientCapacity; invalid_request => rejectionNotCapacity (surface the 4xx). For reason=='' (old providers) fall through to the UNCHANGED string+budget heuristic. Update the doc comment (esp. the LIMITATION block at 148-159) to note the complete fix is now in place when the provider sends the reason.
- `coordinator/api/dispatch.go` — No structural change to the failover loop required: shouldStopFailover (896) and latchDeterministicLoser (931) already call classifyRejection with msg.ErrorReason as the first arg, so the new short-circuit takes effect automatically. OPTIONAL (call out in PR, do not silently flip): at the exhausted ladder (2049) the deterministic-unservable outcome currently emits 429+Retry-After to preserve OpenRouter uptime neutrality; if product wants a true 413 to the consumer for request_exceeds_context, gate that on the structured reason here. Thread msg.ReservedTokens/NodeMaxBudgetTokens/ModelContext into the rejection ledger/telemetry for observability.

**Code sketch.**

```
// ---- provider: BatchScheduler.swift ----
func nodeMaxBudgetTokens() -> Int {
    guard kvBytesPerToken > 0 else { return 0 }
    let kv = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: UInt64(max(0, modelWeightBytes)))
    return Int(min(kv, UInt64(Int.max))) / kvBytesPerToken    // memory-pressure-BLIND ceiling
}

func classifyAdmission(promptTokens: Int, requestBudget: Int, message: String) -> SchedulerRejection {
    let nodeMax = nodeMaxBudgetTokens(); let ctx = maxContextLength
    let reason: AdmissionReason
    if ctx > 0 && promptTokens > ctx            { reason = .requestExceedsContext }  // fleet-wide
    else if nodeMax > 0 && requestBudget > nodeMax { reason = .requestExceedsNode }   // this-node-only
    else                                        { reason = .capacityBusy }            // transient now
    return SchedulerRejection(reason: reason, reservedTokens: requestBudget,
                              nodeMaxBudgetTokens: nodeMax, modelContext: ctx, message: message)
}

// submit / submitTokenized: replace bare yields
let rej = classifyAdmission(promptTokens: promptTokens.count, requestBudget: requestBudget,
            message: "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available")
continuation.yield(.error(rej))

// ---- provider: ProviderLoop.swift (send site ~1302) ----
let statusCode = Self.mapInferenceErrorToStatus(error)   // 413 for requestExceedsContext, else 503
var reason = classifyInferenceErrorReason(error)         // jinja_* unchanged
var reserved, nodeMax, modelCtx: Int? = nil
if let a = classifyAdmission(error) { reason = a.reason; reserved = a.reserved; nodeMax = a.nodeMax; modelCtx = a.modelContext }
send.send(.inferenceError(requestId: requestId, error: error.localizedDescription, statusCode: statusCode,
                          errorReason: reason, reservedTokens: reserved,
                          nodeMaxBudgetTokens: nodeMax, modelContext: modelCtx))

// ---- coordinator: inference_failure_class.go ----
func classifyRejection(reason, errStr string, providerBudget int64, modelContext int) rejectionKind {
    if trustProviderRejectReason {                  // env kill-switch, default true
        switch reason {
        case "request_exceeds_context": return rejectionDeterministicUnservable // stop attempt 1
        case "request_exceeds_node":    return rejectionTransientCapacity         // bigger box may serve
        case "capacity_busy":           return rejectionTransientCapacity
        case "invalid_request":         return rejectionNotCapacity               // 4xx as-is
        }
    }
    // FALLBACK (old providers, reason==""): existing string+budget heuristic UNCHANGED.
    if !isCapacityClassProviderError(errStr) && !isCapacityClassProviderError(reason) { return rejectionNotCapacity }
    /* ...unchanged context-vs-budget inference (lines 166-200)... */
}
```

**Protocol changes.** EXACT field additions, both sides (symmetry mandatory).

SWIFT — provider-swift/Sources/ProviderCore/Protocol/Messages.swift, struct InferenceError (lines 153-170):
  add stored properties:
    public var reservedTokens: Int?       // reserved_tokens
    public var nodeMaxBudgetTokens: Int?  // node_max_budget_tokens
    public var modelContext: Int?         // model_context
  add to enum CodingKeys (the InferenceError group near 360-363):
    case reservedTokens = "reserved_tokens"
    case nodeMaxBudgetTokens = "node_max_budget_tokens"
    case modelContext = "model_context"
  decode (563-569): reservedTokens: try container.decodeIfPresent(Int.self, forKey: .reservedTokens), same for the other two.
  encode: try container.encodeIfPresent(reservedTokens, forKey: .reservedTokens), same for the other two.
  error_reason string field ALREADY exists (line 162). NEW enum VALUES (no new field): "request_exceeds_context", "request_exceeds_node", "capacity_busy", "invalid_request" — joining the documented set {jinja_channel_tags, jinja_null_bridge, jinja_template, model_load}.

GO — coordinator/protocol/messages.go, type InferenceErrorMessage (308-314):
  type InferenceErrorMessage struct {
    Type                string `json:"type"`
    RequestID           string `json:"request_id"`
    Error               string `json:"error"`
    StatusCode          int    `json:"status_code"`
    ErrorReason         string `json:"error_reason,omitempty"`
    ReservedTokens      int64  `json:"reserved_tokens,omitempty"`        // NEW
    NodeMaxBudgetTokens int64  `json:"node_max_budget_tokens,omitempty"` // NEW
    ModelContext        int    `json:"model_context,omitempty"`          // NEW
  }
  Decode at 603-606 (json.Unmarshal into the struct) needs NO change.

NO change to message TYPE constants or routing. Wire stays JSON-compatible: old providers omit new fields (zero values), old coordinators ignore unknown JSON keys. Backward + forward compatible by construction.

**Tests.** PROVIDER (Swift, provider-swift/Tests/ProviderCoreTests/):
- BatchSchedulerBudgetTests.swift (extend): (a) promptTokens > maxContextLength asserts reason=request_exceeds_context; (b) requestBudget > nodeMaxBudgetTokens() but prompt<=context (pin physicalMemory + modelWeightBytes + kvBytesPerToken via the existing _setKVBytesPerTokenForTest seam) asserts request_exceeds_node; (c) requestBudget<=nodeMax but activeUsed+requestBudget > live tokenBudgetMax (admit prior requests to simulate occupancy) asserts capacity_busy. All three fail today (bare string carries no reason). Assert reserved_tokens/node_max_budget_tokens/model_context values.
- MultiModelBatchSchedulerEngineTests.swift (extend): VLM reserveVisionRequest path — prompt+vision span > contextLength throws .requestTooLarge (mapInferenceErrorToStatus==413); kvTokens>nodeMax throws .tokenBudgetExhausted with reason=request_exceeds_node (503); fits-ceiling-but-denied throws capacity_busy (503).
- NEW ProviderLoopAdmissionReasonTests.swift: build InferenceError from each engine error, round-trip JSONEncoder->JSONDecoder; assert error_reason, status_code (413 vs 503), and the three numeric fields present+correct.

COORDINATOR (Go, coordinator/api/):
- inference_failure_class_test.go (extend): classifyRejection with reason='request_exceeds_context' => rejectionDeterministicUnservable regardless of providerBudget/modelContext; 'request_exceeds_node' and 'capacity_busy' => rejectionTransientCapacity even when providerBudget>=modelContext (proves explicit reason overrides the stale heuristic); 'invalid_request' => rejectionNotCapacity; reason='' => existing string behavior UNCHANGED (mixed-fleet regression guard); with kill-switch off, all reason values ignored and fall back to the string path.
- dispatch_oversized_test.go (extend): InferenceErrorMessage{ErrorReason:'request_exceeds_context', StatusCode:413} stops failover on attempt 1 (assert attempt count==1, no storm); ErrorReason:'capacity_busy' fails over to maxCapacityClassRetries then stops.
- NEW case in dispatch_oversized_pressure_test.go: provider last-heartbeat budget>=context (heuristic alone would say deterministic) BUT provider sends capacity_busy => coordinator fails over (transient) — directly proves the LIMITATION at inference_failure_class.go:148-159 is fixed.

**Env knobs.** Coordinator kill-switch: EIGENINFERENCE_TRUST_PROVIDER_REJECT_REASON (default true). When false, classifyRejection ignores the new reason values and uses the legacy string+budget heuristic for ALL providers — instant rollback if a provider build emits a wrong verdict, no code-gated redeploy needed. No new provider-side env flag (the classification is a pure refinement of an existing reject path).

**Human-only.** none — coordinator + provider code only. Rollout note (not a human-only step): the provider half ships via a Swift provider release + fleet auto-update, so the structured reason is observed broadly only after the fleet updates; the coordinator runs the legacy fallback until then. Prod coordinator deploy itself is the standing human-only EigenCloud rule, not new to this fix.

**Risks.** MIXED FLEET (central risk): old providers (~11 on 0.4.7 + the 0.5.16 majority) do NOT send the new fields; they send the bare 'token_budget_exhausted…'+503 as today. The coordinator stays correct because classifyRejection's explicit-reason switch fires ONLY for the exact new reason strings; reason=='' falls through to the UNCHANGED DAR-347 string+budget heuristic. New providers stop guessing; old providers degrade to today's behavior. The reason=='' regression test guards this. Provider rollout latency is real: the structured reason is observed broadly only after the 90% fleet auto-updates; until then the legacy fallback runs.

HETEROGENEOUS-FLEET CORRECTNESS (why two deterministic-ish reasons, not one): a request that exceeds a 64GB box's hardware ceiling MIGHT fit a 128GB box. Collapsing 'too large' into one reason and treating it deterministic would wrongly shed a request a bigger box could serve. So the provider splits: request_exceeds_context (prompt > MODEL context — truly identical on every provider, deterministic, stop) vs request_exceeds_node (exceeds THIS node's memory-blind ceiling — node-specific, treat as transient and fail over to a bigger box, bounded by maxCapacityClassRetries). The node ceiling uses UnifiedMemoryCap.kvBudgetBytes (0.90xphysical − thisModelWeights − activationReserve), pressure-BLIND by construction, so request_exceeds_node means 'cannot fit even on a freshly-booted box with only this model' — a structural node verdict, not a momentary one.

STATUS-CODE DECISION (do NOT silently flip): the coordinator's exhausted ladder maps rejectionDeterministicUnservable to an uptime-NEUTRAL 429+Retry-After (dispatch.go:2049), deliberately, so OpenRouter fails over with no uptime penalty. The provider returns a true 413 on its OWN HTTP surface (StandaloneServer, no coordinator hop). RECOMMENDATION: keep the coordinator-emitted status as 429 for the dispatch outcome to preserve OpenRouter semantics for the legacy fleet, and thread the structured reason+numbers into telemetry to distinguish 'structurally too large' from 'fleet transient exhausted'. Flipping 429->413 for the consumer is a separate, explicitly-gated change — call it out in the PR; do not change the legacy string path's status.

WHAT BREAKS NEXT: (1) reserved_tokens/node_max_budget_tokens are evidence-only for the coordinator today; keep them so a future homogeneous-fleet optimization or a sharper Retry-After can consume them without another protocol bump. (2) If kvBytesPerToken is mis-estimated high, nodeMax is conservative (may over-classify request_exceeds_node) — acceptable: it only down-ranks one node and still fails over; it never sheds fleet-wide (that needs request_exceeds_context). (3) GenerationEvent.error gaining a structured overload touches the .error path — keep the String overload so only admission sites change; mid-stream errors are unaffected.

## harmony-parallel-toolcall-split — Normalize parallel assistant tool_calls into sequential Harmony turns (instead of 400) for gpt-oss
- **Layer:** provider-engine  ·  **Effort:** M  ·  **Deps:** []

**Summary.** OpenAI/OpenRouter clients legitimately put N parallel tool_calls in a single assistant message, but Harmony (gpt-oss) renders only one tool call per assistant turn, so validateHarmonyToolInvariants throws invalidToolPayload (→400) and these histories can NEVER succeed on gpt-oss. The fix replaces rejection with a Harmony-only, behavior-preserving rewrite: split an assistant message carrying N parallel tool_calls into N sequential single-call assistant turns, each immediately followed by its paired role:"tool" result (matched by tool_call_id). The content+thinking-with-tool_calls case is normalized the same way (content is carried on the first split turn; thinking/reasoning_content is moved to a standalone assistant turn emitted before the tool turns so no single rendered turn carries both). A clean 400 is kept only for histories that genuinely cannot be made Harmony-shaped (e.g. a tool result that pairs with no emitted tool_call_id).

**Files:**
- `provider-swift/Sources/ProviderCore/Inference/GPTOSSHarmonyTemplateFixes.swift` — Replace the throwing validateHarmonyToolInvariants with a rewriting splitHarmonyToolTurns step. normalizeMessages becomes: bridge reasoning→thinking (unchanged), then splitHarmonyToolTurns(bridged) which returns the rewritten array OR throws invalidToolPayload only for genuinely-unpairable shapes. The splitter walks messages; when it hits an assistant message with tool_calls.count>1 (or count==1 with both content and thinking), it consumes the following contiguous run of role:"tool" messages, builds an id→toolResult map, and for each of the N calls emits [assistant(single tool_call i, content only on i==0)] followed by [its paired tool result]. thinking/reasoning_content, when present alongside tool_calls, is emitted as a separate leading assistant turn (no tool_calls) so the content+thinking invariant is satisfied per-rendered-turn. Single-tool-call assistant messages with no content/thinking conflict pass through unchanged (zero behavior change for the common case). Keep isHarmonyModelHint gating via the existing applies(to:).
- `provider-swift/Tests/ProviderCoreTests/JinjaSanitizationTests.swift` — Replace testAssistantMessageWithMultipleToolCallsIsRejectedBeforeTemplate and testAssistantToolCallWithContentAndThinkingIsRejectedBeforeTemplate (which assert the old 400) with tests asserting the NEW split output shape; add the cases listed in tests. Keep testMultipleToolCallsRemainAllowedForNonHarmonyTemplates (non-Harmony still passes N calls through untouched) and the unpaired-tool 400 case.
- `coordinator/api/harmonymessages.go` — NEW (mirror of api/toolschema.go pattern). Add NormalizeHarmonyToolMessages(body []byte, model string) []byte: if !isHarmonyModel(model) return body unchanged; cheap byte-gate on "tool_calls"; JSON round-trip with UseNumber; rewrite root["messages"] applying the same split-parallel-into-sequential algorithm over the wire shape (assistant.tool_calls = [{id,type,function:{name,arguments}}], tool result = {role:"tool",tool_call_id,content}); return original bytes verbatim when nothing changed; never error a request that would otherwise work (return body on any parse failure). isHarmonyModel matches the Swift isHarmonyModelHint (substring gpt-oss/gpt_oss/gptoss).
- `coordinator/api/consumer.go` — In handleChatCompletions, after resolveRequestedModel sets the concrete build `model` (and after the existing max_tokens/reasoning_parser re-marshals), call rawBody = NormalizeHarmonyToolMessages(rawBody, model) and re-parse only if it changed (or thread the already-parsed map). This runs AFTER responsesRequestToChatCompletions for the Responses path, but that path already emits one tool_call per assistant message (responsesInputToChatMessages:1465-1483 wraps each function_call in its own single-element tool_calls), so it is a structural no-op there and is covered by a regression test. Gate strictly on the resolved gpt-oss build id so non-Harmony traffic is byte-identical.

**Code sketch.**

```
// provider-swift GPTOSSHarmonyTemplateFixes.swift
static func normalizeMessages(_ messages: [[String: any Sendable]]) throws -> [[String: any Sendable]] {
    let bridged = bridgeReasoningContentToThinking(messages)
    return try splitHarmonyToolTurns(bridged)   // replaces validateHarmonyToolInvariants
}

private static func splitHarmonyToolTurns(_ messages: [[String: any Sendable]]) throws -> [[String: any Sendable]] {
    var out: [[String: any Sendable]] = []
    var i = 0
    while i < messages.count {
        let m = messages[i]
        guard (m["role"] as? String) == "assistant",
              let calls = m["tool_calls"] as? [any Sendable], !calls.isEmpty
        else { out.append(m); i += 1; continue }

        let hasContent  = hasTruthyString(m["content"])
        let hasThinking = hasTruthyString(m["thinking"]) || hasTruthyString(m["reasoning_content"])
        let needsSplit  = calls.count > 1 || (hasContent && hasThinking)
        if !needsSplit { out.append(m); i += 1; continue }   // single, clean → unchanged

        // gather the contiguous following tool-result run, index by tool_call_id
        var j = i + 1
        var resultsById: [String: [String: any Sendable]] = [:]
        var orphanResults: [[String: any Sendable]] = []
        while j < messages.count, (messages[j]["role"] as? String) == "tool" {
            let r = messages[j]
            if let id = r["tool_call_id"] as? String { resultsById[id] = r } else { orphanResults.append(r) }
            j += 1
        }

        // content+thinking → emit thinking as its own bare assistant turn first
        if hasContent && hasThinking {
            var t = m; t["tool_calls"] = nil; t["content"] = ""
            // keep thinking/reasoning_content on t
            out.append(t)
        }
        // one assistant(single call) + its paired result, per call, in order
        for (k, raw) in calls.enumerated() {
            guard let call = raw as? [String: any Sendable] else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant tool_calls[\(k)] is not an object")
            }
            var turn: [String: any Sendable] = ["role": "assistant", "tool_calls": [call]]
            if k == 0, hasContent { turn["content"] = m["content"] }     // content rides the first call turn
            if k == 0, hasThinking && !(hasContent && hasThinking) {     // single-call content-free thinking stays inline
                if let th = m["thinking"] { turn["thinking"] = th }
                if let rc = m["reasoning_content"] { turn["reasoning_content"] = rc }
            }
            out.append(turn)
            let id = (call["id"] as? String) ?? ""
            if let res = resultsById[id] { out.append(res) }
            else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant tool_call \(id.isEmpty ? "#\(k)" : id) has no matching tool result")
            }
        }
        out.append(contentsOf: orphanResults)   // preserve any extra tool msgs (validator already gates leading orphans)
        i = j
    }
    return out
}

// coordinator/api/harmonymessages.go (mirror; same algorithm over wire shape)
func NormalizeHarmonyToolMessages(body []byte, model string) []byte {
    if !isHarmonyModel(model) || !bytes.Contains(body, []byte(`"tool_calls"`)) || len(body) > maxToolNormalizationBytes { return body }
    // decode (UseNumber) → root["messages"].([]any) → splitMessages(...) with changed flag → re-marshal only if changed
    // splitMessages mirrors splitHarmonyToolTurns: pair tool results by tool_call_id, emit single-call turns; on unpairable, return body UNCHANGED (provider issues the clean 400)
}
func isHarmonyModel(m string) bool { s := strings.ToLower(m); return strings.Contains(s,"gpt-oss")||strings.Contains(s,"gpt_oss")||strings.Contains(s,"gptoss") }
```

**Protocol changes.** none. The fix operates entirely on the already-decoded message dict (Swift) and the JSON messages array (Go) before applyChatTemplate / before encryption. No WebSocket message type changes; coordinator/protocol/messages.go and the Swift Protocol/ types are untouched. The rewrite uses only existing fields (role, content, thinking, reasoning_content, tool_calls[].id/type/function, tool_call_id), so wire compatibility with every provider version is preserved (a lagging provider receives an already-Harmony-legal history and renders it natively).

**Tests.** Provider (provider-swift/Tests/ProviderCoreTests/JinjaSanitizationTests.swift, mirrors existing style via ChatTemplateFixes.normalizeMessages with context modelId gpt-oss-20b):
- multi(2 parallel calls)→split: user, assistant{tool_calls:[A,B]}, tool{id:a}, tool{id:b} ⇒ assistant{tool_calls:[A]},tool{a},assistant{tool_calls:[B]},tool{b}; assert count, per-turn single tool_call, tool_call_id pairing preserved, ordering stable.
- multi with N=3 and results out of order (tool{b},tool{c},tool{a}) ⇒ each assistant turn followed by ITS matching result (by id), not positional.
- single tool_call, no content/thinking ⇒ pass-through unchanged (identity; guards the common-case zero-behavior-change).
- content+thinking+single tool_call ⇒ emits standalone assistant{thinking} then assistant{content,tool_calls:[A]} then tool{a}; assert no single emitted turn has both content and thinking, content lands on the call turn.
- content+thinking+multiple tool_calls ⇒ thinking turn once, content only on first call turn.
- zero tool_calls assistant ⇒ unchanged.
- reasoning_content (not thinking) + multiple calls ⇒ bridged to thinking first, then split.
- unpaired: assistant{tool_calls:[A,B]} but only tool{a} present ⇒ still throws invalidToolPayload (clean 400) naming the missing tool_call_id (the ONLY remaining throw path).
- non-Harmony (modelId qwen3) with parallel calls ⇒ pass-through unchanged (extends existing testMultipleToolCallsRemainAllowedForNonHarmonyTemplates).
- live render: extend TemplateRenderCheck-style/MultiModelBatchSchedulerEngineTests applyTemplate over a real Harmony template fixture with 2 parallel calls to assert renderOK (no Jinja throw) — the end-to-end oracle the old 400 hid.
Coordinator (coordinator/api/harmonymessages_test.go, ported case-for-case from the Swift cases like toolschema_test.go):
- multi→split for model gpt-oss-20b; assert messages array rewritten, tool_call_id pairing, idempotency (running twice == once).
- single call / zero tool_calls ⇒ original bytes returned verbatim (changed=false path).
- non-Harmony model (gemma-4-26b) ⇒ body unchanged even with parallel calls.
- unpaired ⇒ returned unchanged (provider issues the clean 400; coordinator must never 500 or drop).
- number round-trip (UseNumber) on tool arguments; sibling-field survival.
- Responses-path regression (coordinator/api/consumer_test.go): responsesRequestToChatCompletions output fed through NormalizeHarmonyToolMessages is a structural no-op (already one call per assistant turn).
- HTTP path: POST /v1/chat/completions via httptest with a parallel-tool-call gpt-oss history reaches dispatch (no 400) — exercises the wiring in handleChatCompletions, not just the function.

**Env knobs.** Optional kill-switch EIGENINFERENCE_HARMONY_TOOLCALL_SPLIT (default on) on the coordinator step, mirroring how tool-schema normalization can be reasoned about per-deploy; the provider-side split has no flag (it replaces a hard 400, so disabling it only restores the broken behavior). No new prod secret/KMS entry. If a knob is added it is read once at startup like MIN_PROVIDER_VERSION (needs redeploy).

**Human-only.** none

**Risks.** Semantic fidelity of parallel→sequential: OpenAI parallel tool_calls mean "the model decided to call A and B simultaneously, given the same prior context." Serializing them as A→result→B→result re-frames B as if it were decided AFTER seeing A's result. For the model's NEXT turn this is almost always benign (it still sees all calls + all results) and is exactly how Harmony must represent multi-tool history anyway — there is no lossless alternative on a one-call-per-turn template; the only other option (the status quo) is a hard 400, so any faithful-enough split strictly dominates. Edge: ordering must be deterministic and result-pairing must be by tool_call_id, not position (out-of-order or interleaved tool results otherwise mis-pair) — covered by tests. thinking/content separation: moving thinking to its own assistant turn changes how reasoning is rendered (a bare analysis turn vs inline), acceptable since the alternative was a 400; keep it Harmony-only. Coordinator double-normalize: the provider also splits, so a request normalized at the coordinator hits an already-legal history at the provider (idempotent — assert in tests); no double-split because count==1 turns pass through. What breaks next: (1) a tool result that pairs with NO tool_call in the run is the one genuinely-unnormalizable case — kept as a clean 400 (don't silently drop it, that would hand the template an orphaned tool turn → render crash); (2) if a future Harmony template gains native multi-call support, this split becomes unnecessary overhead but stays correct; (3) the cheap byte-gate (\"tool_calls\") must fire before the JSON round-trip so non-tool gpt-oss traffic pays nothing — mirror toolschema.go's size cap + needle gate to keep it off the hot path; (4) keep the coordinator step gated on the RESOLVED gpt-oss build id (not the pre-resolution alias) so non-Harmony models stay byte-identical.

## P1-deterministic-client-4xx-stop — Stop the 29x retry storm on deterministic provider client-4xx via a StatusCode-driven non-retryable stop (string-blind)
- **Layer:** coordinator  ·  **Effort:** M  ·  **Deps:** ['P2-toolschema-normalization']

**Summary.** The dispatch loop decides retry-vs-terminal purely from the provider error STRING (shouldStopFailover -> classifyRejection), never the provider StatusCode. A deterministic provider client-4xx (invalidToolPayload/invalidRole/mediaUnsupportedByModel -> 400, invalidResponseFormatOutput -> 422, and the VLM MediaError 400s) is identical on every provider but fails over up to maxDispatchAttempts=64 (avg 29, max 63). Fix: add a StatusCode-driven non-retryable stop in shouldStopFailover BEFORE classifyRejection, using a client-shape stop set {400,413,422,415} that deliberately EXCLUDES 404/408/429 (404 = "model not loaded" cold-miss must keep failing over). Mirror the same StatusCode latch at latchDeterministicLoser so a speculative race loser can't restart the storm, and pass the provider's real 4xx through the exhausted ladder ONCE (skipping the capacity probe / 5xx->429 reclassification). A new client_error routing-outcome class keeps these deterministic 4xx out of the AdmittedButFailed admission-mismatch gauge.

**Files:**
- `coordinator/api/dispatch.go` — Add two fields to dispatchState (next to unservable/unservableReason): terminalClientError bool and terminalClientErrorCode int. In shouldStopFailover, BEFORE the classifyRejection switch (after the d.unservable early-return), add a StatusCode-driven stop: if !s.disableClientErrorStop && isTerminalClientErrorCode(d.lastErrCode) -> set d.terminalClientError=true, d.terminalClientErrorCode=d.lastErrCode, ddIncr("routing.dispatch_client_error_stop", model+code tags), return true. In latchDeterministicLoser, mirror it: after the d.unservable guard, if !s.disableClientErrorStop && isTerminalClientErrorCode(msg.StatusCode) -> set d.terminalClientError + d.terminalClientErrorCode=msg.StatusCode + ddIncr, return (latched independent of d.unservable so it survives the surviving racer's later error). In the exhausted ladder (~2032-2071), add a FIRST branch inside `if !d.committed` (before the `if d.unservable` branch): if d.terminalClientError -> statusCode = d.terminalClientErrorCode; reason = "client_error"; ddIncr("routing.client_error_passthrough", model+code); skip the QuickCapacityCheck/5xx->429 reclassification entirely so the provider's real 4xx is returned ONCE. Add helper isTerminalClientErrorCode(code int) bool returning code==400||code==413||code==422||code==415. In waitFirstChunk/waitAccepted deferred outcome blocks, route a terminal client 4xx to d.clientErrorRoutingOutcome() instead of providerFailedRoutingOutcome() (guard: outcomeRetry && isTerminalClientErrorCode(d.lastErrCode)).
- `coordinator/api/route_outcome.go` — Add a client_error class constant errorClassClientError = "client_error" and a builder clientErrorRouteOutcome / dispatchState.clientErrorRoutingOutcome() that returns errorRoutingOutcome("error", errorClassClientError, code) WITHOUT AdmittedButFailed=true (so a deterministic client 4xx never pollutes the admission-mismatch gauge that providerFailedRoutingOutcome sets). Extend inferenceErrorReason so class=="client_error" maps to a stable reason (add errorReasonClientError="client_error" to validInferenceErrorReasons and a switch arm before the code>=500 catch-all, so the Datadog reason tag is client_error not provider_error).
- `coordinator/api/server.go` — Add field disableClientErrorStop bool (kill switch) with a doc comment, and SetDisableClientErrorStop(bool) setter (mirrors SetServabilityGate; call before serving). Default false = stop enabled.
- `coordinator/cmd/coordinator/main.go` — Wire EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP: if set and parses true, srv.SetDisableClientErrorStop(true) + logger.Warn("client-error dispatch stop DISABLED — deterministic provider 4xx will failover up to maxDispatchAttempts"). Mirror the EIGENINFERENCE_SERVABILITY_GATE block at ~440.

**Code sketch.**

```
// dispatch.go — dispatchState fields (next to unservable/unservableReason)
//   terminalClientError     bool // provider returned a deterministic client 4xx (identical fleet-wide)
//   terminalClientErrorCode int  // the 4xx to surface ONCE through the exhausted ladder

func isTerminalClientErrorCode(code int) bool {
    // Client-SHAPE stop set: deterministic, identical on every provider.
    // EXCLUDES 404 (cold-miss "model not loaded" — must failover; also matches
    // capacityClassMarkers "not loaded"), 408 and 429 (transient capacity).
    switch code {
    case http.StatusBadRequest, // 400 invalidRole/invalidToolPayload/mediaUnsupportedByModel + VLM MediaError
        http.StatusRequestEntityTooLarge,    // 413 (defensive; not emitted today)
        http.StatusUnsupportedMediaType,     // 415 (defensive; not emitted today)
        http.StatusUnprocessableEntity:      // 422 invalidResponseFormatOutput
        return true
    }
    return false
}

func (d *dispatchState) shouldStopFailover() bool {
    if d.unservable {
        return true
    }
    // StatusCode-driven stop BEFORE the string classifier: a deterministic
    // provider client 4xx fails identically on every provider, so retrying is
    // pure waste (the 29x storm). String-blind on purpose — the code is the
    // ground truth here, the human-readable string drifts across versions.
    if !d.s.disableClientErrorStop && isTerminalClientErrorCode(d.lastErrCode) {
        d.s.ddIncr("routing.dispatch_client_error_stop",
            []string{"model:" + d.model, "code:" + strconv.Itoa(d.lastErrCode)})
        d.terminalClientError = true
        d.terminalClientErrorCode = d.lastErrCode
        return true
    }
    switch classifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext) {
    case rejectionDeterministicUnservable:
        // …unchanged…
    case rejectionTransientCapacity:
        // …unchanged…
    default:
        return false
    }
}

func (d *dispatchState) latchDeterministicLoser(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
    if d.unservable || d.terminalClientError {
        return
    }
    // Mirror the StatusCode stop at the race-loser site: the loser's error is
    // NOT written to d.lastErr (the survivor owns it), so without this a
    // deterministic client 4xx from the loser is masked and the storm resumes.
    if !d.s.disableClientErrorStop && isTerminalClientErrorCode(msg.StatusCode) {
        d.s.ddIncr("routing.dispatch_client_error_stop",
            []string{"model:" + d.model, "code:" + strconv.Itoa(msg.StatusCode), "src:race_loser"})
        d.terminalClientError = true
        d.terminalClientErrorCode = msg.StatusCode
        return
    }
    budget := providerReportedBudget(provider, d.model)
    if classifyRejection(msg.ErrorReason, msg.Error, budget, d.modelMaxContext) == rejectionDeterministicUnservable {
        // …unchanged (sets d.unservable)…
    }
}

// exhausted ladder (~2032) — FIRST branch inside `if !d.committed`:
//   statusCode := d.lastErrCode
//   reason := "dispatch_exhausted"
//   switch {
//   case d.terminalClientError:
//       // Deterministic provider client 4xx — pass the real code through ONCE.
//       // Skip the QuickCapacityCheck and the 5xx->429 reclassification: this is
//       // a client fault, not capacity, and must NOT become a 429/503.
//       statusCode = d.terminalClientErrorCode
//       reason = "client_error"
//       s.ddIncr("routing.client_error_passthrough",
//           []string{"model:" + d.model, "code:" + strconv.Itoa(statusCode)})
//   case d.unservable:
//       // …existing oversized 429…
//   case statusCode == 0:
//       // …existing QuickCapacityCheck 429-vs-503…
//   case statusCode >= 500 && isCapacityClassProviderError(d.lastErr):
//       // …existing 5xx->429 backstop…
//   }

// route_outcome.go
const errorClassClientError = "client_error"
func (d *dispatchState) clientErrorRoutingOutcome() *store.InferenceRouteOutcome {
    // Deterministic client 4xx: NOT AdmittedButFailed (the admission gate was
    // right; the request itself is malformed/unservable by shape, not a
    // provider/coordinator capacity mismatch).
    return d.errorRoutingOutcome("error", errorClassClientError, d.terminalClientErrorCode)
}
// + add errorReasonClientError="client_error" to validInferenceErrorReasons
//   and a switch arm in inferenceErrorReason before the code>=500 catch-all.
```

**Protocol changes.** none — InferenceErrorMessage.StatusCode (coordinator/protocol/messages.go:312) already carries the provider's HTTP-style status, populated by the Swift provider's ProviderLoop+ErrorMapping.swift mapInferenceErrorToStatus and ProviderLoop.swift inferenceError(statusCode:) sends. No wire field is added; the fix consumes a field that already crosses the boundary. NOTE the existing residual gap (documented in classifyRejection): the wire carries no rejection-time budget — out of scope here and unchanged. A future provider-side improvement to emit a distinct reason for client faults would let the coordinator drop string matching entirely, but is NOT required for this fix.

**Tests.** New file coordinator/api/dispatch_client_error_test.go (unit, mirrors dispatch_oversized_pressure_test.go style using newTestServerForDispatch): (1) TestShouldStopFailover_ClientError400 — d.lastErrCode=400, d.lastErr="invalid tool payload" -> shouldStopFailover()==true, d.terminalClientError true, d.terminalClientErrorCode==400. (2) TestShouldStopFailover_ColdMiss404StillFailsOver — d.lastErrCode=404, d.lastErr="Model 'm' is not loaded on this provider" -> shouldStopFailover()==false (404 EXCLUDED; this is the reviewer-correction regression guard — without the exclusion 404 would stop and break cold-miss failover). (3) TestShouldStopFailover_QueueFull429StillFailsOver — code=429,"queue full" -> classifyRejection still drives transient failover, terminalClientError false. (4) TestShouldStopFailover_422ResponseFormat and _413 and _415 -> stop true. (5) TestLatchDeterministicLoser_ClientError400 — latchDeterministicLoser(p, msg{StatusCode:400,Error:"invalid tool payload"}) -> d.terminalClientError true even though d.lastErr holds a transient survivor error; then shouldStopFailover()==true (race-loser latch regression guard). (6) TestClientErrorStop_KillSwitch — s.disableClientErrorStop=true -> shouldStopFailover()==false for a 400 (falls through to classifyRejection). (7) TestClientErrorRouteOutcome_NotAdmittedButFailed — assert clientErrorRoutingOutcome().AdmittedButFailed==false and ErrorClass=="client_error". Integration (extend failover_integration_test.go httptest+fake-WS-provider harness): TestProviderClientError_StopsAfterOne — a fake provider replies inference_error{status_code:400,error:"invalid tool payload"}; assert total dispatchCount()==1 (NOT 64), HTTP body status==400, and response surfaces the provider error once. TestProviderColdMiss404_FailsOverAndSucceeds — provider A replies 404 "not loaded", provider B succeeds; assert dispatchCount A==1, B==1, HTTP 200 (proves 404 still failovers). All three new-behavior tests FAIL against current code (current loop walks 64 attempts on the 400; 404 path is unchanged so its guard test passes either way and is a pure regression lock).

**Env knobs.** EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP=true (new kill switch, default off = stop enabled). When set, shouldStopFailover and latchDeterministicLoser skip the StatusCode stop and fall through to the existing string-only classifyRejection path (i.e. full pre-fix behavior — failover up to maxDispatchAttempts on a deterministic 4xx). Read once at startup in main.go (like EIGENINFERENCE_SERVABILITY_GATE / EIGENINFERENCE_TTFT_HARD_REJECT), threaded via Server.disableClientErrorStop. No new numeric tunable needed — the stop set is a code constant (isTerminalClientErrorCode).

**Human-only.** none — coordinator-only change. Prod rollout is the standard EigenCloud coordinator deploy, which is human-only per CLAUDE.md (agent prepares PR/commands, does not run `ecloud compute app deploy`).

**Risks.** RISK: stop-set membership is the whole game. Verified against provider-swift/Sources/ProviderCore/ProviderLoop+ErrorMapping.swift mapInferenceErrorToStatus — 400 (invalidRole/invalidToolPayload/mediaUnsupportedByModel + all VLM MediaError client faults) and 422 (invalidResponseFormatOutput) are deterministic client faults; 404 (modelNotLoaded/noModelLoadedForTokenization/responseNotFound) is a cold-miss/lifecycle that MUST failover and ALSO matches the capacityClassMarkers \"not loaded\" string — including 404 would regress cold-load failover (the reviewer correction). 429 (queueFull) and any 408 are transient — excluded. 413/415 are NOT currently emitted by the provider map (grep-confirmed) but are included defensively as unambiguous client shapes; harmless since they never fire today and are correct if a future provider version emits them. 501 (embeddingsNotConfigured) is a capability gap, deterministic but left OUT of the stop set (conservative — it 5xx-passes-through as today; can be added later). SOUNDNESS of StatusCode-over-string: the only coordinator-side setLastError 4xx is 402 (PaymentRequired, dispatch.go:769) which is NOT in the stop set, so a coordinator fault can never be mistaken for a provider client error — every code in {400,413,422,415} can ONLY originate from a provider InferenceErrorMessage. WHAT BREAKS NEXT: (a) If P2 lands first and removes the invalidToolPayload 400s at the source, this fix still correctly handles the residual 400s (invalidRole, mediaUnsupportedByModel, 422 response_format) and the broader client-4xx class — it is the backstop, not a duplicate of P2. (b) A provider that wrongly returns 400 for a transient condition would now stop instead of failover — mitigated by the kill switch and by the fact that the provider map only returns 400 for genuine client faults. (c) The exhausted-ladder ordering matters: terminalClientError must be checked BEFORE d.unservable and before statusCode==0, else a 400 could be reclassified to 503/429 — covered by the integration test asserting body status==400.

## P2-zombie-stable-identity-ejection — Stable-identity rolling success-rate health-ejection gate for zombie providers
- **Layer:** coordinator  ·  **Effort:** M  ·  **Deps:** ['P1-oversized-admission (request_too_large / classifyRejection)']

**Summary.** "Zombie" providers (0 successes, ~100% failures, stay routable) are not caught because the existing node-health breaker (registry/provider_breaker.go) and the inference-error cooldown are keyed by a per-SESSION UUID (api/provider.go:124 providerID=uuid.New()), and registry.Disconnect (registry.go:3527-3529) deletes all of that state on every disconnect. These boxes disconnect constantly (jetsam/OOM, ~7,880/48h), so health state never accumulates across the reconnect churn and the breaker never trips. They also frequently fail with capacity-marked 503s (token_budget) that providerOutcomeIsFault() correctly treats as healthy sheds. The fix is a NEW health-ejection gate (registry/health_ejection.go) keyed by a STABLE provider identity (SerialNumber, else "sekey:"+SEPublicKey, else "acct:"+AccountID) that survives reconnect within a coordinator lifetime, with a persistent rolling success-rate window independent of session UUID, challenge status, and reputation. It ejects a stable identity from routing only after a meaningful sample shows a near-total success-rate collapse, half-opens to re-probe, and FAILS OPEN (never ejects the last provider for a model). It does NOT delete this state on Disconnect.

**Files:**
- `coordinator/registry/health_ejection.go` — NEW FILE. Stable-identity rolling-outcome health-ejection breaker, parallel to provider_breaker.go but keyed by a stable identity and NOT wiped on disconnect. Defines: (1) stableProviderIdentityLocked(p *Provider) string — derive key with precedence SerialNumber -> sekey:+SEPublicKey -> acct:+AccountID -> "" (empty = un-attestable, skip ejection entirely, fail-open). Reads p.AttestationResult.SerialNumber / .PublicKey and p.AccountID under p.mu (caller already holds p.mu on the routing path; provide a non-locked *Locked variant). (2) healthEjectionWindow struct: time-bucketed rolling counters (success, served-fault) over healthEjectionWindow duration; reuse the fixed-ring approach from providerHealthWindow but size it larger (healthEjectionRingSize=40) and store ts+ok. (3) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string) (ejected, recovered bool) — append outcome (only successes and SERVED faults; capacity sheds via isCapacityShedError are ignored exactly like the session breaker), then evaluate healthEjectionOpenLocked. On ok==true reset consecFail and, if currently ejected, recover (clear ejectUntil/trips) -> recovered=true. (4) healthEjectionShouldEjectLocked: trip iff (windowTotal>=healthEjectionMinSample AND successRate < healthEjectionMinSuccessRate) OR consecFail>=healthEjectionConsecTrip; on trip set ejectUntil=now+backoff(trips), trips++. (5) healthEjectionOpenLocked(stableID, now) bool — read-only, ejectUntil>now. (6) HealthEjectionOpen(stableID) for tests/observability. (7) backoff: base healthEjectionBaseCooldown doubling to healthEjectionMaxCooldown. (8) opportunistic >1024 sweep mirroring provider_breaker.go (but here keys are STABLE and finite — fleet-sized — so sweep only drops entries idle for > 2*maxCooldown to preserve cross-reconnect accumulation). All under r.mu. Map field accessors live here.
- `coordinator/registry/registry.go` — (1) Add three Registry fields next to providerOutcomes (line ~1204): healthEjectionWindows map[string]*healthEjectionWindow; healthEjectionUntil map[string]time.Time; healthEjectionTrips map[string]int. (2) Initialize them in New() (line ~1278). (3) In Disconnect (lines 3527-3529): DO NOT add deletes for the new maps — explicitly comment that stable-identity ejection state MUST survive disconnect (that is the whole point). DisconnectDuplicatesBySerial calls Disconnect, so no extra change is needed there; add a one-line comment at registry.go:2657 documenting that the wipe being avoided is in Disconnect and the new ejection maps are deliberately preserved. (4) Add a helper GetProviderStableIdentity(providerID string) string that locks r.mu+p.mu, looks up r.providers[providerID], and returns stableProviderIdentityLocked(p) (empty if provider gone) — used by the api layer at outcome time.
- `coordinator/registry/scheduler.go` — In providerPassesRoutingGatesLockedEx (line 786), after the existing session-keyed providerBreakerOpenLocked gate (line 822), add a NEW gate: derive stableID := stableProviderIdentityLocked(p) (caller holds p.mu); if stableID != "" AND !ignoreProviderBreaker AND healthEjectionEnabled() (live env read) AND r.healthEjectionOpenLocked(stableID, now) -> return false. Place it under the same ignoreProviderBreaker bypass so the selectBestCandidateLockedFull fail-open rescan also bypasses health-ejection (a fleet-wide ejection can never zero a model). Update the gate-ordering doc comment (lines 757-769) to list the new gate.
- `coordinator/api/consumer.go` — In noteInferenceSuccess (line 261) and noteInferenceError (line 241): after the existing RecordProviderOutcome call, resolve the stable identity via s.registry.GetProviderStableIdentity(providerID) and call s.registry.RecordProviderServeOutcome(stableID, ok, statusCode, errStr) when stableID != "". On ejected emit ddIncr("routing.provider_ejected",["model:"+pr.Model]); on recovered emit "routing.provider_ejection_recovered". Guard the whole new block behind the live kill-switch read so disabling the feature stops both recording and gating. noteInferenceError already feeds every terminal (incl. the GatewayTimeout synthetic and Disconnect-flush 502) so served-fault coverage matches the session breaker.
- `coordinator/registry/health_ejection_test.go` — NEW FILE. Unit tests for the ejection logic + a reconnect-survival test (see tests field).

**Code sketch.**

```
// registry/health_ejection.go (NEW)
const (
  healthEjectionMinSample      = 20
  healthEjectionMinSuccessRate = 0.10            // eject when <10% success over window
  healthEjectionConsecTrip     = 8
  healthEjectionWindow         = 10 * time.Minute
  healthEjectionRingSize       = 40
  healthEjectionBaseCooldown   = 60 * time.Second
  healthEjectionMaxCooldown    = 10 * time.Minute
)

func healthEjectionEnabled() bool { // LIVE read — honored without restart
  switch strings.ToLower(strings.TrimSpace(os.Getenv(env.EnvPrefix + "_HEALTH_EJECTION"))) {
  case "off", "0", "false", "no": return false
  default: return true // default ON
  }
}

// stable identity precedence (caller holds p.mu)
func stableProviderIdentityLocked(p *Provider) string {
  if p.AttestationResult != nil {
    if p.AttestationResult.SerialNumber != "" { return p.AttestationResult.SerialNumber }
    if p.AttestationResult.PublicKey != ""    { return "sekey:" + p.AttestationResult.PublicKey }
  }
  if p.AccountID != "" { return "acct:" + p.AccountID }
  return "" // un-attestable -> fail open, never eject
}

func (r *Registry) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string) (ejected, recovered bool) {
  if stableID == "" || !healthEjectionEnabled() { return }
  r.mu.Lock(); defer r.mu.Unlock()
  now := time.Now()
  r.healthEjectionSweepLocked(now)              // idle > 2*maxCooldown only
  w := r.healthEjectionWindowLocked(stableID)
  if ok {
    w.record(true, now)
    if _, had := r.healthEjectionUntil[stableID]; had {
      delete(r.healthEjectionUntil, stableID); delete(r.healthEjectionTrips, stableID)
      return false, true                        // half-open probe succeeded -> recover
    }
    return false, false
  }
  // SERVED faults only — capacity sheds (incl. deterministic-unservable per P1 risk
  // decision, and synthetic disconnect-flush 502 / GatewayTimeout) are neutral.
  if !providerOutcomeIsFault(statusCode, errStr) { return false, false }
  w.record(false, now)
  if until, had := r.healthEjectionUntil[stableID]; had && now.Before(until) { return false, false }
  trips := r.healthEjectionTrips[stableID]
  total, fails := w.windowStats(now, healthEjectionWindow)
  rate := total >= healthEjectionMinSample && float64(total-fails) < healthEjectionMinSuccessRate*float64(total)
  if trips == 0 && w.consecFail < healthEjectionConsecTrip && !rate { return false, false }
  r.healthEjectionUntil[stableID] = now.Add(healthEjectionBackoff(trips))
  r.healthEjectionTrips[stableID] = trips + 1
  return true, false
}

func (r *Registry) healthEjectionOpenLocked(stableID string, now time.Time) bool {
  until, ok := r.healthEjectionUntil[stableID]
  return ok && now.Before(until)
}

// scheduler.go — inside providerPassesRoutingGatesLockedEx, after the session breaker gate:
if !ignoreProviderBreaker && healthEjectionEnabled() {
  if sid := stableProviderIdentityLocked(p); sid != "" && r.healthEjectionOpenLocked(sid, now) {
    return false // zombie quarantined by stable identity, independent of session UUID
  }
}

// api/consumer.go — noteInferenceError (after RecordProviderOutcome):
if sid := s.registry.GetProviderStableIdentity(providerID); sid != "" {
  if ejected, _ := s.registry.RecordProviderServeOutcome(sid, false, statusCode, errStr); ejected {
    s.ddIncr("routing.provider_ejected", []string{"model:" + pr.Model})
  }
}
// noteInferenceSuccess (after RecordProviderOutcome ok):
if sid := s.registry.GetProviderStableIdentity(pr.ProviderID); sid != "" {
  if _, recovered := s.registry.RecordProviderServeOutcome(sid, true, 200, ""); recovered {
    s.ddIncr("routing.provider_ejection_recovered", []string{"model:" + pr.Model})
  }
}

// registry.go Disconnect — NO new deletes; explicit comment:
//   stable-identity health-ejection state (healthEjectionWindows / *Until / *Trips)
//   deliberately SURVIVES disconnect — keying it by stable identity instead of the
//   per-session UUID is the whole point; wiping it here would reproduce the zombie bug.
```

**Protocol changes.** none — coordinator-only. No WebSocket message-type changes, so no edits to coordinator/protocol/messages.go or the Swift Protocol. The fix is entirely in the coordinator's routing/health layer; providers already report SerialNumber/SEPublicKey via attestation and AccountID via device auth, which are the stable-identity inputs.

**Tests.** NEW coordinator/registry/health_ejection_test.go (mirror provider_breaker_test.go harness — *Locked pokes under r.mu, seed helper, expireHealthEjection rewind helper, no sleeps):
- TestHealthEjection_TripsOnSustainedFailRate: feed healthEjectionMinSample served-faults (e.g. 20 of 20) for a stable id -> ejected==true, HealthEjectionOpen(id)==true.
- TestHealthEjection_NotTrippedByCapacitySheds: feed 30 capacity-503s (token_budget / out of memory) -> never ejected (proves load can't trip it).
- TestHealthEjection_BelowMinSample: 4 faults < min sample -> not ejected.
- TestHealthEjection_ConsecutiveTrip: healthEjectionConsecTrip faults in a row -> ejected even below windowed min sample.
- TestHealthEjection_HalfOpenRecovery: trip, expire cooldown, one success -> recovered==true, open==false, trips reset.
- TestHealthEjection_HalfOpenReprobeFault: trip, expire, one fault -> re-ejected with larger backoff (assert ejectUntil delta grows).
- TestHealthEjection_SurvivesDisconnect (THE regression test that fails without the fix): build a Registry, register provider with session id u1 + SerialNumber S, drive RecordProviderServeOutcome(S,...) to ejection, call r.Disconnect(u1), assert HealthEjectionOpen(S)==true AFTER disconnect (today's session breaker would be gone). Then register a NEW session id u2 with the same Serial S, assert providerPassesRoutingGatesLockedEx returns false for that provider while ejected — i.e. the zombie stays de-routed across the reconnect churn.
- TestHealthEjection_FailOpenLastProvider: ensure the selectBestCandidateLockedFull rescan path (ignoreProviderBreaker=true) bypasses the gate — add a scheduler-level test: single ejected provider for a model -> normal scan yields no candidate, full-fidelity rescan still selects it (routing never zeroed). Reuse the existing scheduler test harness that exercises selectBestCandidateLockedFull.
- TestHealthEjection_KillSwitchLiveRead: set the disable env var, assert gating + recording are skipped at evaluation time without restart (set env, call gate, expect pass even when window is full of faults).
- TestStableProviderIdentity_Precedence: Serial wins over sekey wins over acct; empty when none -> ejection skipped (fail-open).
API-layer test (api package): drive noteInferenceError repeatedly for a provider with a stable Serial through httptest-style registry wiring (mirror failover_p2_integration_test.go) and assert the provider becomes unroutable for the model, then a success recovers it.

**Env knobs.** NEW live-read kill switch: EIGENINFERENCE_HEALTH_EJECTION (default "on"; set to "off"/"0"/"false" to fully disable both gating and recording — read via os.Getenv at evaluation time so it takes effect without restart). Optional tuning (read once at startup, OK to leave as constants for v1): EIGENINFERENCE_HEALTH_EJECTION_MIN_SAMPLE (default 20), EIGENINFERENCE_HEALTH_EJECTION_MIN_SUCCESS_RATE (default 0.10 — eject when success rate < 10% over the window, i.e. ~90%+ served-fault), EIGENINFERENCE_HEALTH_EJECTION_CONSEC (default 8). Cooldown/backoff constants: healthEjectionBaseCooldown=60s, healthEjectionMaxCooldown=10m, healthEjectionWindow=10m (longer than the session breaker's 120s so it accumulates across the reconnect churn). Existing related knobs untouched: the session-keyed provider_breaker.go constants and EIGENINFERENCE_DEDICATED_MODELS.

**Human-only.** none — coordinator-only code change. No KMS, no protocol, no provider release. Ships via a normal coordinator deploy (EigenCloud prod deploy remains human-only per CLAUDE.md, but no new secret is required; the kill switch defaults to on, and EIGENINFERENCE_HEALTH_EJECTION can be flipped via KMS env at deploy time by a human if a rollback is needed).

**Risks.** P1 interaction (the explicit question): classifyRejection (api/inference_failure_class.go) splits an over-context request into rejectionDeterministicUnservable (every provider rejects identically — a true model/workload mismatch) vs rejectionTransientCapacity (this node's shrunk KV budget). For the ejection gate these must be handled DIFFERENTLY from the session breaker's blunt isCapacityShedError: (a) rejectionTransientCapacity and all classic capacity sheds -> NEVER count (healthy-but-busy); this is the default and matches isCapacityShedError, so no behavior change if P1 is absent. (b) rejectionDeterministicUnservable -> by the CLAUDE.md principle \"a box too-small for the workload SHOULD be de-routed for that model,\" these SHOULD count toward ejection — BUT only per-(stableID,model), NOT fleet-wide, or a giant prompt would eject every box for that model and the fail-open rescan would just re-admit them in a storm. RECOMMENDATION: keep v1 SIMPLE and SAFE — treat deterministic-unservable as a capacity shed (do NOT count it) so the gate only ejects on genuine served faults (500/502/504, fault-503, disconnect-flush 502). De-routing too-small boxes is better handled by P1's first-rejection-stop + the servability preflight, not by this rolling breaker. Document this as the chosen interaction and gate the \"count deterministic-unservable\" variant behind a future per-model ejection key if needed. Sequencing: errStr/reason classification strings P1 introduces must be stable before this lands so the shed-vs-fault split stays correct; if P1's classifier strings change, this gate's isCapacityShedError view must stay aligned (both read the same provider error vocabulary).
OOM-disconnect (reviewer correction d): noteInferenceError is fed a synthetic 502 \"provider disconnected\" on the Disconnect pending-flush for in-flight requests; ClassifyDisconnectReason marks OOM-suspected drops. As written, a 502-disconnect-flush counts as a served fault and WILL push toward ejection. DECISION: OOM-disconnect is a CAPACITY symptom (the box was overloaded), not a node-software fault — counting it would eject boxes for being busy, exactly what fail-open is meant to prevent. MITIGATION: in noteInferenceError, when the error is the Disconnect-flush 502 AND the box's last DisconnectDiagnostics indicate OOM-suspected, pass it as a capacity shed (don't record it). Simplest implementation: only record SERVED faults that arrived as real InferenceErrorMessages from the provider (statusCode set by the provider), and treat the synthetic disconnect-flush 502 + synthetic GatewayTimeout as capacity/neutral for the ejection gate. This keeps the gate firing on the actual zombie signature (provider returns fault-503/500 for served requests) and not on the churn itself.
In-memory-store reliance (reviewer correction a): the design does NOT touch storedProviders or GetReputation — stable identity is derived live from the connected Provider's attestation/account fields, and ejection state lives in registry maps that survive reconnect WITHIN a coordinator lifetime only. Documented explicitly: ejection state does NOT survive a coordinator restart (acceptable — a restart is rare and the window re-accumulates in minutes; over-claiming cross-restart durability would require store-backed persistence which is out of scope and the prod store is in-memory anyway).
Live kill-switch (reviewer correction c): config is read once via ReadConfig at startup, so the kill switch is implemented as an os.Getenv read at EVALUATION time (gate + record), not cached — disabling it stops gating immediately without a redeploy. Tiny per-request getenv cost is acceptable on this path (already done for dedicated-models-style features); if measured hot, cache in an atomic.Bool refreshed by a 10s ticker.
What breaks next: (1) A genuinely-bad fleet-wide rollout that fault-500s everywhere trips ejection on every stable id -> the fail-open rescan (ignoreProviderBreaker) re-admits them, so routing is never zeroed but every request pays a double-scan; mitigated because the session breaker already has this exact fail-open and the rescan is cheap. (2) Identity collision: two different physical boxes presenting the same Serial (spoof) would share an ejection bucket — bounded blast radius (one bucket), and serial spoofing is already a trust-layer concern, not this gate's. (3) A box whose only identity is acct:+AccountID (un-attested self-route owner box) shares a bucket with all that owner's boxes — acceptable for self-route, and self-route relaxes trust anyway; could refine to per-(account,model) later.

## P2-coordinator-oversized-predispatch-429 — Make predictable oversized requests a pre-dispatch 429/413 instead of a dispatched 503/504
- **Layer:** coordinator  ·  **Effort:** M  ·  **Deps:** ['P1-provider-request-too-large-reason']

**Summary.** Today, oversized requests (e.g. prompt ~18k + max_tokens=32k = ~50k) slip past every size gate because each gate is fail-open against a stale ~5s heartbeat and compares against the FLEET-MAX or the selected provider's full advertised budget — not its live remaining budget net of committed/queued tokens. PredictServable Tier 2 (servability.go:214) takes the raw activeTokenBudgetMax of the largest box (an idle box advertising the full 131072 context makes 50k always "servable"), and freeMemoryAdmits (scheduler.go:1121) is a binary pass/fail that never clamps max_tokens. So the request dispatches, then 503s (token_budget_exhausted) or 504s (first_chunk_timeout from a huge prefill). This fix (1) subtracts committed+queued from each provider's budget in PredictServable so the fleet-budget tier reflects live headroom, (2) adds a route-time clamp/reject in buildCandidateWithReason that validates the request against the SELECTED provider's live remaining budget and rejects pre-dispatch when even prompt+256 won't fit anywhere, (3) clamps explicit max_tokens to min(modelContext-prompt, fleet headroom) in ensureMaxTokensBound, and (4) converts the predictable-oversized first_chunk_timeout to an uptime-neutral 429 instead of a bare 504. All gated, fail-open, and it consumes P1's definitive request_too_large reason when present (falls back to its own estimate for old providers).

**Files:**
- `coordinator/registry/servability.go` — Tier 2 (lines 209-217): replace `budget, known := snapshotStructuralBudget(snap)` accumulation of raw activeTokenBudgetMax with a LIVE-REMAINING budget = budget - committedTokenBudget(snap) for resident slots (cold slots keep the optimistic post-load estimate, which is already net of weights). Add a new helper liveStructuralBudget(snap) that returns max(0, structural - committed) for resident, estimate for cold. Keep fail-open: unknown budget still sets sawUnknown. This makes a busy idle-advertising box stop masking the shed. Add a floor mode: expose a second verdict field MinFloorTokens (prompt + floorMaxTokens(256)) so the caller can distinguish 'cannot fit ANY provider even at floor' (413) from 'too large at requested max_tokens but floor would fit' (429-clamp candidate).
- `coordinator/registry/scheduler.go` — buildCandidateWithReason (~1090-1123): after computing reqMax/reqPrompt and BEFORE freeMemoryAdmits, compute the selected provider's live remaining budget when activeTokenBudgetMax>0: remaining = activeTokenBudgetMax - committedTokenBudget(snap) - coordinatorExtra. If reqPrompt + floorMaxTokens(256) > remaining AND > the cold post-load estimate -> return a NEW rejection kind rejectOversizedDeterministic (does not inflate the transient busy 429; routes to the unservable/413-or-429 path). Add an optional CLAMP: when reqPrompt+reqMax > remaining but reqPrompt+floor fits, record a suggested clamped max into the RoutingDecision (ClampedMaxTokens) so dispatch can shrink the outgoing request rather than reject. Add rejectOversizedDeterministic to the candidateRejection enum + RoutingDecision counter OversizedRejections, mirroring ModelTooLargeRejections (permanent, not transient-capacity).
- `coordinator/api/consumer.go` — ensureMaxTokensBound (~1374): add an optional hard upper bound parameter (contextHeadroom = modelMaxContext - estimatedPromptTokens, fleetBudgetHeadroom from a new registry.FleetMaxLiveBudget(model) read). When an explicit max_tokens is present and exceeds min(contextHeadroom, fleetBudgetHeadroom, maxOutputBound), clamp it down (never up) and re-marshal. This is the cheap structural clamp that turns 'prompt 18k + max 32k on a 24k-context model' into 'prompt 18k + max ~6k' so it fits, instead of a guaranteed dispatch-time 503. Wire the headroom values at the existing call sites (consumer.go:1795, 4731). Gate the new clamp behavior behind the existing servabilityGate flag so it ships dark first.
- `coordinator/api/dispatch.go` — waitFirstChunk deadlineTimer.C arm (~1054-1086): when the deadline fires with zero held chunks AND the request is structurally oversized (estimatedPromptTokens+requestedMaxTokens > d.lastErrProviderBudget-equivalent for the just-tried provider, or modelMaxContext exceeded), latch d.unservable=true + reason=rejectionReasonOversized BEFORE the bare 504 path, so the exhausted ladder emits a 429 not a 504. Also in the exhausted block (~2052), when statusCode==0 (timeout-only) and the request was predictably oversized, prefer 429. Keep the existing QuickCapacityCheckForRequest fallback for the non-oversized timeout case.
- `coordinator/api/inference_failure_class.go` — classifyRejection (~160): consume the P1 provider signal — when reason=="request_too_large" (or a sub-reason like "request_exceeds_context" vs "request_exceeds_node_budget"), return rejectionDeterministicUnservable for the context variant and rejectionTransientCapacity for the node-budget variant DIRECTLY, bypassing the stale-snapshot inference. Fall back to the existing string+budget heuristic when the reason is absent (old providers). Add the new reason markers to capacityClassMarkers.
- `coordinator/api/servability_gate.go` — shedIfUnservable: also handle the new 413 case — when PredictServable returns Servable=false AND even MinFloorTokens cannot fit any provider's live budget (truly nothing can serve it), return http.StatusRequestEntityTooLarge (413, non-retryable) instead of 429. Keep 429 for ContextExceeded/PromptTooLong where a smaller request or a later retry could succeed. Update unservableMessage accordingly.
- `coordinator/cmd/coordinator/main.go` — No new top-level env needed if reusing EIGENINFERENCE_SERVABILITY_GATE; optionally add EIGENINFERENCE_OVERSIZED_CLAMP=true to independently toggle the route-time max_tokens clamp (item 3) from the predict/shed gate, so the riskier auto-clamp can be enabled separately from the read-only shed. Log the chosen mode at startup like the existing gate.

**Code sketch.**

```
// registry/servability.go — live remaining budget in Tier 2
func liveStructuralBudget(snap routingSnapshot) (budget int64, known bool) {
    if snap.activeTokenBudgetMax > 0 {
        rem := snap.activeTokenBudgetMax - committedTokenBudget(snap)
        if rem < 0 { rem = 0 }
        return rem, true
    }
    if snap.modelLoaded { return 0, false } // legacy resident, unknown
    if snap.totalMemoryGB <= 0 || snap.modelSizeGB <= 0 { return 0, false }
    return coldTokenBudgetEstimate(snap.totalMemoryGB, snap.modelSizeGB, snap.kvBytesPerToken), true
}
// in PredictServable Tier 2 loop: budget, known := liveStructuralBudget(snap)
// fleetMax = max over providers; reject when providerCount>0 && !sawUnknown && budgetRequestTokens > fleetMax (unchanged shape).
// also track fleetMaxFloor over (prompt+floorMaxTokens) to set verdict.CanFitAtFloor.

// registry/scheduler.go — route-time clamp/reject against SELECTED provider
const floorMaxTokens = 256
func (r *Registry) buildCandidateWithReason(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, candidateRejection, bool) {
    // ... existing reqMax/reqPrompt ...
    if snap.activeTokenBudgetMax > 0 {
        coordExtra := int64(snap.pendingMaxTokens) - committedTokenBudget(snap)
        if coordExtra < 0 { coordExtra = 0 }
        remaining := snap.activeTokenBudgetMax - committedTokenBudget(snap) - coordExtra
        if remaining < 0 { remaining = 0 }
        if int64(reqPrompt+floorMaxTokens) > remaining {
            return nil, rejectOversizedDeterministic, false // even floor won't fit -> not transient
        }
        if int64(reqPrompt+reqMax) > remaining {
            pr.SuggestedClampMax = int(remaining) - reqPrompt // dispatch may shrink instead of reject
        }
    }
    // ... existing freeMemoryAdmits etc ...
}

// api/inference_failure_class.go — consume P1 reason
func classifyRejection(reason, errStr string, providerBudget int64, modelContext int) rejectionKind {
    switch reason {
    case "request_exceeds_context": return rejectionDeterministicUnservable
    case "request_exceeds_node_budget": return rejectionTransientCapacity
    }
    // ...existing string+budget heuristic fallback for old providers...
}

// api/consumer.go — clamp explicit max_tokens DOWN to fit
func ensureMaxTokensBound(parsed map[string]any, isResponsesAPI bool, bound, hardMax int) bool { // hardMax = min(ctxHeadroom, fleetHeadroom)
    if n := explicitMaxTokens(parsed); n > 0 {
        if hardMax > 0 && n > hardMax { n = hardMax; setMaxTokens(parsed, isResponsesAPI, n); return true }
        // ...existing alias-normalize...
    }
    // ...existing inject-when-absent (use min(bound,hardMax) if hardMax>0)...
}
```

**Protocol changes.** No protocol change is REQUIRED for this coordinator-only fix (it works on the existing wire). It OPTIONALLY consumes a new field added by P1. If P1 adds it, the symmetric change is: coordinator/protocol/messages.go InferenceErrorMessage already has `ErrorReason string` (line 313) and provider-swift Messages.swift already has `errorReason` (line 162) — so NO new field is needed. P1 only needs to POPULATE errorReason with a definitive value at the two BatchScheduler.swift reject sites (1907-1916 = context/budget bound; distinguish via `requestBudget > contextWindow` -> \"request_exceeds_context\" else \"request_exceeds_node_budget\") and at BatchQueuePlanner.swift requestExceedsBatchTokenBudget (307). The coordinator's classifyRejection must accept those exact strings. So the contract to agree with P1: the reason-string vocabulary {\"request_exceeds_context\",\"request_exceeds_node_budget\"} (or P1's chosen spellings) must be mirrored in inference_failure_class.go markers. No new message type, no new struct field.

**Tests.** registry/servability_test.go: add TestPredictServableSubtractsCommitted — fleet of one provider with activeTokenBudgetMax=131072 but activeTokenBudgetUsed+queuedTokenBudget=100000; a 50k request must now be unservable (was servable pre-fix); a 20k request still servable. TestPredictServableFloorFitsButRequestedDoesnt — request prompt+max exceeds live budget but prompt+256 fits → verdict carries the clamp signal, not a hard 413. registry/scheduler_test.go: TestBuildCandidateRejectsOversizedAgainstLiveBudget — snapshot with small remaining budget, reqPrompt+reqMax over it, prompt+floor over it → rejectOversizedDeterministic (NOT rejectCapacity); and the clamp case where prompt+floor fits → ClampedMaxTokens populated. api/servability_gate_test.go: TestServabilityGate413WhenNothingCanServe — empty/all-zero-live-budget fleet, oversized → 413 not 429; TestServabilityGate429WhenRetryCouldHelp → 429. api/dispatch_oversized_test.go (extend): TestPredictableOversizedTimeoutBecomes429 — dispatch a request that exceeds the only provider's budget, first_chunk_timeout fires with zero chunks → exhausted emits 429 not 504. api/inference_failure_class_test.go: TestClassifyRejectionHonorsRequestTooLargeReason — reason=\"request_exceeds_context\" → deterministic even with a stale budget>=context; reason=\"request_exceeds_node_budget\" → transient; empty reason falls back to existing heuristic. api/consumer_test.go: TestEnsureMaxTokensBoundClampsExplicit — explicit max_tokens=32000 with contextHeadroom=6000 → clamped to 6000 (gate on); unchanged when gate off (regression-safe). Each test must FAIL on master (verified: master's Tier 2 uses raw budget, ensureMaxTokensBound only injects-when-absent, timeout path emits 504).

**Env knobs.** Reuse existing EIGENINFERENCE_SERVABILITY_GATE (default off) to gate the PredictServable live-budget subtraction + the 413/shed path. Add optional EIGENINFERENCE_OVERSIZED_CLAMP (default off) to independently toggle the route-time/ensureMaxTokensBound max_tokens DOWN-clamp (item 3), since auto-shrinking an explicit max_tokens is behaviorally observable and riskier than the read-only shed. Both logged at startup like the existing gate. No new prod secret. Kill-switch: setting both to false restores exact current behavior (fully behavior-neutral), which is the safe rollback.

**Human-only.** none — coordinator-only change, no KMS/secret/prod-deploy action by the agent. Prod activation (flipping EIGENINFERENCE_SERVABILITY_GATE / EIGENINFERENCE_OVERSIZED_CLAMP in EigenCloud KMS and the EigenCloud deploy) is human-only per project rules, but no NEW secret is introduced.

**Risks.** OVER-SHED is the primary risk: subtracting committed+queued from a STALE ~5s heartbeat can transiently under-report a provider's true headroom right after a batch of requests completes (the heartbeat hasn't caught up), making a valid mid-size request shed as 429. Mitigations: (a) the budget tier remains fail-open on sawUnknown; (b) PredictServable still uses the RAW (uncalibrated) estimate for the budget tier so it under-counts prompt tokens (the safe direction); (c) keep everything behind EIGENINFERENCE_SERVABILITY_GATE/EIGENINFERENCE_OVERSIZED_CLAMP, ship dark, watch routing.oversized_request_rejected{stage:preflight} vs {stage:dispatch} to confirm preflight catches real oversized traffic without inflating total rejections. CLAMP risk (item 3): silently shrinking a consumer's explicit max_tokens changes observable behavior — only clamp DOWN, never up, log it, and bound by the SAME value the request would have been rejected for, so a clamped response is strictly better than a 503. 413 risk: 413 is non-retryable in OpenRouter, so only emit it when NOTHING (not even prompt+floor) fits ANY provider's live budget — otherwise stay 429. WHAT BREAKS NEXT: (1) if P1's reason strings drift from the coordinator markers, classifyRejection silently falls back to the stale-snapshot heuristic (degrades to current behavior, not a regression) — pin the vocabulary in a shared test. (2) The live-remaining subtraction interacts with coordinatorExtra double-count guard in freeMemoryAdmits (scheduler.go:993) — reuse committedTokenBudget()/the same coordinatorExtra clamp so the two gates can't disagree and bounce a request between 'predict says fits' and 'route says no'. (3) A model whose context window is larger than every provider's KV budget (memory-constrained) will now 429 at the fleet-budget tier — correct, but verify the message says 'reduce max_tokens / retry' not 'context exceeded'.

## C5-gemma-vision-remote-url-400 — Coordinator pre-dispatch media-URL-shape validation for vision requests (reject remote/non-data: URLs cleanly; optional fetch-and-inline)
- **Layer:** coordinator  ·  **Effort:** S  ·  **Deps:** ['C1-4xx-non-retryable']

**Summary.** The provider's VLM path accepts ONLY inline base64 `data:` URIs (VLMRequestInference.swift:408-411, 456-461, 707-709, 756-758 → MediaError.invalidURL → terminal 400). The dominant client (OpenRouter) sends OpenAI-style REMOTE `image_url:{url:"https://…"}` parts. The coordinator validates media PRESENCE (detectMediaRequirement/contentPartsHaveMedia, consumer.go:1011-1054) and provider vision-capability (HasVisionProviderForModel + scheduler.go:290/477/1654 routing gate) but NEVER the media URL SHAPE — so every remote-URL vision request dispatches, gets a provider 400, and (pre-C1) storms up to maxDispatchAttempts=64 (consumer.go:77) because the ErrorCh handler returns outcomeRetry unconditionally (dispatch.go:1003/1045) and EVERY vision provider rejects identically. Fix: add a pre-dispatch validateMediaParts gate in the coordinator that walks every image_url/input_image/image/video_url/input_video/video part across messages[] and Responses input[], and returns ONE terminal 400 (invalid_request_error) mirroring the provider's data:-only contract when any media URL is not an inline `data:` URI. This stops the storm at the source and gives the caller an actionable error instead of a generic capacity failure. Option B (fetch-and-inline) is laid out as a follow-on product decision.

**Files:**
- `coordinator/api/consumer.go` — Add mediaPartURLString(pm map[string]any) (url string, isMedia bool) helper near isMediaPartType (~:899) that extracts the URL/inline-data reference for each media part type: image_url → image_url as bare string OR image_url["url"]; input_image → image_url string OR image_url["url"]; video_url/input_video → analogous (video_url field); Anthropic image/video → source["type"] ('url' is remote → its source["url"]; 'base64' is inline RAW base64, NOT a data: URI). Add isInlineDataURI(s string) bool (strings.HasPrefix(s, "data:")). Add validateMediaParts(parsed map[string]any) (badURL string, ok bool) that walks messages[].content and input[].content parts; returns the first offending URL (remote http(s)://, file://, or any non-data: reference, AND Anthropic source.type=='url') so the caller can emit one terminal 400. Reuse contentPartsHaveMedia's iteration shape. Inline-base64 Anthropic blocks (source.type=='base64') are a SEPARATE provider-contract concern — flag them only if the provider does not normalize them to data: before sealing (see protocol_changes/risks); default the first cut to rejecting only remote-URL references to avoid over-rejecting working Anthropic base64 traffic.
- `coordinator/api/inference_preprocess.go` — Extend visionToolsFailFast (or add a sibling validateMediaShapeFailFast called immediately after it at both callsites) so that when requiresVision is true, it runs validateMediaParts(parsed) and, on a bad URL, writes ONE terminal writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", <message mirroring VLMRequestInference.MediaError.invalidURL: 'media must be sent as an inline base64 data: URI … remote http(s):// and file:// URLs are rejected … Got: <truncated url>'>, withParam("messages"))) and records a recordRejection{stage:"validation", reasonCode:"bad_param", httpStatus:400, requiresVision:true,…} mirroring consumer.go:1812-1828, then returns handled=true. This sits BEFORE balance reservation and dispatch so no provider is ever contacted. Gate behind env DARKBLOOM_VISION_REJECT_REMOTE_URLS (default on) so it is a kill-switch; when off, fall through to today's dispatch-and-400 behavior (still bounded by C1).
- `coordinator/api/consumer.go` — Wire the call: in the chat-completions handler add validateMediaShapeFailFast right after the visionToolsFailFast block (~:1757-1760) — parsed is hot there and requiresVision is computed at :1748. In the generic handler add it after the visionToolsFailFast block (~:4715-4718). Pass parsed (the already-lowered providerParsed is built later for Responses, but Responses media is already rejected by visionToolsFailFast rejectResponsesMedia=true, so chat/generic are the only surfaces that reach dispatch with media).
- `coordinator/api/consumer_test.go` — Add unit tests for mediaPartURLString + validateMediaParts covering every shape; add an httptest.NewServer(srv.Handler()) integration test asserting a remote-URL vision request gets exactly ONE 400 with invalid_request_error and ZERO dispatch attempts (assert via a fake provider whose ChunkCh/ErrorCh is never touched, or via the dispatches metric counter).

**Code sketch.**

```
// consumer.go — near isMediaPartType (~:899)
func isInlineDataURI(s string) bool { return strings.HasPrefix(s, "data:") }

// Returns the URL/inline reference for a media part and whether it IS a media part.
func mediaPartURLString(pm map[string]any) (ref string, isMedia bool) {
    typ, _ := pm["type"].(string)
    if !isMediaPartType(typ) { return "", false }
    switch typ {
    case "image_url", "input_image", "video_url", "input_video":
        // OpenAI chat: object {url}. Responses: bare string. OpenRouter tolerates both.
        field := "image_url"; if typ == "video_url" || typ == "input_video" { field = "video_url" }
        switch v := pm[field].(type) {
        case string: return v, true
        case map[string]any: if u, ok := v["url"].(string); ok { return u, true }
        }
        return "", true // media part but unreadable url → fail-open (not rejected)
    case "image", "video": // Anthropic source block
        if src, ok := pm["source"].(map[string]any); ok {
            st, _ := src["type"].(string)
            if st == "url" { u, _ := src["url"].(string); return u, true } // REMOTE
            if st == "base64" { return "data:base64-block", true }          // inline (treated OK in v1)
        }
        return "", true
    }
    return "", true
}

// validateMediaParts walks every media part; returns first offending REMOTE ref.
func validateMediaParts(parsed map[string]any) (badURL string, ok bool) {
    if !visionRejectRemoteEnabled() { return "", true } // env kill-switch
    check := func(content any) (string, bool) {
        parts, ok := content.([]any); if !ok { return "", true }
        for _, p := range parts {
            pm, ok := p.(map[string]any); if !ok { continue }
            ref, isMedia := mediaPartURLString(pm)
            if !isMedia || ref == "" { continue }
            if !isInlineDataURI(ref) { return ref, false } // remote/file/non-data:
        }
        return "", true
    }
    if msgs, ok := parsed["messages"].([]any); ok {
        for _, m := range msgs { if mm, ok := m.(map[string]any); ok {
            if u, good := check(mm["content"]); !good { return u, false } } }
    }
    if input, ok := parsed["input"].([]any); ok {
        for _, it := range input { if im, ok := it.(map[string]any); ok {
            if u, good := check(im["content"]); !good { return u, false } } }
    }
    return "", true
}

// inference_preprocess.go — called right after visionToolsFailFast at BOTH callsites
func (s *Server) validateMediaShapeFailFast(w http.ResponseWriter, r *http.Request,
    parsed map[string]any, publicModel, model string, requiresVision, hasTools, stream bool,
    estPrompt, reqMax int) (handled bool) {
    if !requiresVision { return false }
    badURL, ok := validateMediaParts(parsed)
    if ok { return false }
    shown := badURL; if len(shown) > 200 { shown = shown[:200] + "…" }
    s.recordRejection(rejectionInfo{r: r, stage: "validation", reasonCode: "bad_param",
        httpStatus: http.StatusBadRequest, requestedModel: publicModel, resolvedModel: model,
        stream: stream, estimatedPromptTokens: estPrompt, requestedMaxTokens: reqMax,
        requiresVision: true, hasTools: hasTools, params: rejectionSamplingParams(parsed),
        keyID: keyIDFromContext(r.Context()),
        consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context()))})
    s.ddIncr("inference.media_remote_url_rejected", []string{"model:" + model})
    writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
        "media must be sent as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); "+
        "remote http(s):// and file:// image/video URLs are not supported on this end-to-end-"+
        "encrypted endpoint. Got: "+shown, withParam("messages")))
    return true
}

// consumer.go chat handler ~:1760, generic handler ~:4718:
if s.validateMediaShapeFailFast(w, r, parsed, publicModel, model, requiresVision, hasTools,
    stream, estimatedPromptTokens, requestedMaxTokens) { return }

// OPTION B sketch (gated, follow-up): in validateMediaParts, when visionFetchRemoteEnabled(),
// replace the `return ref,false` branch with: data, ct, err := s.fetchInlineMedia(ref) //
// SSRF-guarded (deny private/link-local, no redirect-to-private, size<=MAX_MEDIA_MIB, timeout,
// content-type image|video); on success rewrite the part in-place to "data:"+ct+";base64,"+b64,
// then re-marshal rawBody before sealing; on err fall through to the clean 400.
```

**Protocol changes.** none. No WebSocket/wire message type changes — this is a pure coordinator-side request-validation gate on plaintext the coordinator already sees (sealedTransport decrypts before the handler). The provider's data:-only contract (VLMRequestInference.swift) is unchanged and is the spec the coordinator mirrors. NOTE on Anthropic base64: the provider accepts ONLY data:-prefixed URIs, so Anthropic source.type=="base64" (RAW base64 in source.data, no data: prefix) would ALSO 400 at the provider today. That is a pre-existing, separate gap from the remote-URL storm. If the coordinator already normalizes Anthropic image blocks to data: URIs before sealing, no action; if it does NOT (verified: /v1/messages goes through handleGenericInference and forwards the body largely as-is, with no Anthropic→data: image normalizer found), then either (a) reject Anthropic base64 blocks in validateMediaParts too, or (b) add a coordinator-side normalizer that rewrites source:{type:base64,media_type,data} → data:<media_type>;base64,<data>. Recommend (b) as a follow-up so Anthropic vision works at all; keep this fix scoped to remote-URL rejection to match the verified 537/hr root cause.

**Tests.** coordinator/api/consumer_test.go (new): (1) TestMediaPartURLString_AllShapes — table over image_url-object {url:https}, image_url-bare-string, input_image-string, input_image-object, Anthropic image source{type:url,url:https}, Anthropic image source{type:base64,data:…}, video_url-object — asserts extracted URL + isMedia. (2) TestValidateMediaParts_RejectsRemote — messages with a remote https image_url returns badURL non-empty, ok=false; data: image_url returns ok=true; mixed (one data:, one https) returns the https one; Responses input[] with https input_image rejected; text-only returns ok=true. (3) TestValidateMediaParts_KillSwitch — env DARKBLOOM_VISION_REJECT_REMOTE_URLS=0 disables. (4) TestVisionRemoteURLReturnsSingle400_NoDispatch (httptest.NewServer(srv.Handler())): POST /v1/chat/completions with {messages:[{role:user,content:[{type:image_url,image_url:{url:"https://example.com/x.png"}}]}]} against a registry holding a fake is_vision provider; assert resp.StatusCode==400, body.error.type=="invalid_request_error", message contains "data:" and "remote", and the fake provider received ZERO inference dispatches (inspect a dispatch-count hook or the inference_dispatches_total metric == 0). This FAILS today (request dispatches and either storms or — with C1 — returns a provider-origin 400 only after contacting a provider). (5) Regression for the storm: assert attempt count stays at 0 (vs up to 64). All tests use isolated in-memory store + fake providers, never prod.

**Env knobs.** DARKBLOOM_VISION_REJECT_REMOTE_URLS (new, default ON) — kill-switch for the reject-cleanly gate; OFF restores today's dispatch-and-400 (still bounded by C1). DARKBLOOM_VISION_FETCH_REMOTE (new, default OFF) — reserved for Option B fetch-and-inline; when ON the gate fetches+inlines instead of rejecting (SSRF-hardened fetcher required before enabling). Reuse DARKBLOOM_MAX_MEDIA_MIB (25) as the fetch size cap to mirror the provider. No new prod secrets.

**Human-only.** none. Coordinator-only change; deploy is via the normal coordinator deploy (prod EigenCloud deploy is human-only per CLAUDE.md, but no KMS/secret changes are required for the default reject-cleanly behavior).

**Risks.** REJECT-CLEANLY (this fix) risks: (a) Over-rejection if a legitimate client relies on remote URLs working — but they DON'T work today (provider 400s), so rejecting cleanly is strictly better UX, never a regression in capability. (b) Shape-coverage gaps: if a part shape isn't enumerated, it falls through to today's behavior (dispatch+400, bounded by C1) — fail-OPEN on unknown shapes is the safe default (never wrongly 400 a request we don't understand). Enumerate the full state space: image_url(obj|string), input_image(string|obj), image(Anthropic source url|base64), video_url, input_video, video — all covered. (c) The Anthropic base64 nuance (above): scoping to remote-URL only avoids breaking any Anthropic base64 traffic that the provider might already handle, at the cost of leaving that separate gap for a follow-up. WHAT BREAKS NEXT: once remote URLs are rejected cleanly, the next complaint is 'why don't remote image URLs work at all' — which motivates Option B.

OPTION B — FETCH-AND-INLINE (coordinator fetches remote URLs server-side and rewrites the part to a data: URI before sealing). Tradeoffs: PRO — OpenRouter/OpenAI clients that send https image_url 'just work', matching consumer expectation; this is the dominant client's actual intent. CON/RISKS: (1) SSRF — the coordinator becomes a fetcher of arbitrary client-controlled URLs; must enforce an allowlist or block private/link-local/metadata ranges (169.254.169.254, 10/8, 127/8, ::1, fc00::/7), disable redirects to private hosts, cap response size to maxMediaDecodedBytes (25 MiB, mirror the provider), enforce content-type image/video, and a tight timeout. (2) Egress + latency — adds a network RTT + download to TTFT for every remote-image request, on the coordinator's critical path (TEE egress cost). (3) E2E-encryption tension — the coordinator currently NEVER touches media bytes beyond routing-estimate header reads; fetching+inlining means the coordinator handles plaintext image bytes (it already sees plaintext prompts post-sealedTransport, so this is consistent, but it widens the coordinator's data exposure). (4) Caching/dedup needed to avoid re-fetching. Recommendation: ship REJECT-CLEANLY now (kills the 537/hr storm + gives actionable errors), gate Option B behind an explicit env flag (DARKBLOOM_VISION_FETCH_REMOTE=0 default) as a later product decision with an SSRF-hardened fetcher and size/timeout caps; the two compose (fetch-when-enabled, else reject).

## gemma-decode-quality-floor — Use tps_registry per-(model,chip) median in the decode-floor soft preference so idle-but-historically-slow gemma boxes are deprioritized
- **Layer:** coordinator  ·  **Effort:** S  ·  **Deps:** []

**Summary.** A SOFT decode-floor preference already exists at registry/scheduler.go:577 (driven by EIGENINFERENCE_MIN_DECODE_TPS, default 15): it keeps only candidates whose projected per-request decode TPS clears the floor, and never fails closed. The ~9 tok/s gemma boxes slip through it because projectedPerRequestDecodeTPS (scheduler.go:1483) only consults the LIVE per-slot observedDecodeTPS, then falls straight back to the static benchmark (snap.decodeTPS, ~23 solo for gemma) — so an IDLE slow box (NumRunning=0, no live observed value) projects ABOVE the floor, is not deprioritized, and then serves a 9 tok/s stream (p90 112s, client_gone). The fix is small: feed the durable tps_registry per-(model,chip) observed median (already in snap.fleetMedianTPS at scheduler.go:942) into the projection as the solo-rate signal when no live per-slot rate exists, instead of jumping to the static benchmark. This deprioritizes chips that have historically decoded this model below the floor even while idle, preserving the existing never-fail-closed semantics. Deprioritize, not reject; no zero-out; no warm-pool/cold-spill change.

**Files:**
- `coordinator/registry/scheduler.go` — Rewrite projectedPerRequestDecodeTPS (~line 1483) to resolve the SOLO decode rate via a durable 3-tier chain instead of live-observed-or-static. Tier order for the solo base: (1) live per-slot observedDecodeTPS unwound from the current batch to solo = obs*(1+k*b) (unchanged — the box's own measured rate right now); (2) NEW: when no live observed rate, use snap.fleetMedianTPS (the tps_registry per-(model,chip) median) as the solo proxy — the durable historical observed rate that exists even when the box is idle and is exactly the signal that captures 'this chip decodes gemma at ~9'; (3) snap.decodeTPS static benchmark as last resort. Then apply the existing rate(b+1)=solo/(1+k*(b+1)) batch-degradation step unchanged. Net: an idle box on a chip that has historically decoded this model at 9 now projects ~9 (was ~23 static) and is dropped by the existing >= MinDecodeTPS check at scheduler.go:580. Leave the filter body at 577-587 exactly as-is (still SOFT, never-fail-closed). Add a package-level live-read helper decodeFloorUseFleetMedian() bool gated by EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN (default true) via env.EnvBool read inside the function each call (no restart; false = byte-for-byte pre-fix projection). Optionally bump a routing counter (decode_floor.fleet_median_deprioritized) in the filter when the fleet-median tier is what pulled a candidate below floor — telemetry-only, no protocol change.
- `coordinator/registry/scheduler_test.go` — Add regression tests (see tests field). Reuse makeSchedulerProvider + reg.tpsRegistry.Record + Hardware.ChipFamily ('M3' default from testRegisterMessage).

**Code sketch.**

```
// scheduler.go ~1483 — was live-observed-or-static; now a durable 3-tier solo chain.
func projectedPerRequestDecodeTPS(snap routingSnapshot) float64 {
    k := effectiveTPSLoadFactor
    if k < 0 { k = 0 }
    b := snap.backendRunning
    if b < 0 { b = 0 }

    solo := snap.decodeTPS // tier 3: static benchmark (last resort)
    switch {
    case snap.observedDecodeTPS > 0:
        // tier 1: this box's own LIVE measured rate, unwound from batch b to solo.
        solo = snap.observedDecodeTPS * (1 + k*float64(b))
    case decodeFloorUseFleetMedian() && snap.fleetMedianTPS > 0:
        // tier 2 (NEW): durable per-(model,chip) observed median from tps_registry.
        // Exists even when this box is IDLE, so a historically-slow chip is
        // deprioritized BEFORE it gets packed. Conservative: a median that
        // understates true solo biases AWAY from borderline-slow boxes — the safe
        // direction for a quality floor.
        solo = snap.fleetMedianTPS
    }
    if solo <= 0 { return 0 }
    return solo / (1 + k*float64(b+1))
}

// live kill-switch, read per-call (no restart)
func decodeFloorUseFleetMedian() bool {
    return env.EnvBool(env.EnvPrefix+"_DECODE_FLOOR_USE_FLEET_MEDIAN", true)
}

// filter at scheduler.go:577 — UNCHANGED (SOFT, never-fail-closed):
//   if pr.MinDecodeTPS > 0 {
//       quality := candidates where projectedPerRequestDecodeTPS(c.snapshot) >= pr.MinDecodeTPS
//       if len(quality) > 0 { pool = quality }   // whole-fleet-slow => keep full pool, still serve
//   }
// Decision: DEPRIORITIZE, not reject. If EVERY candidate is below floor the pool
// is left intact and the request is still served. Genuine peak overflow stays a
// pre-dispatch 429 (C3's capacity gate), untouched here.
```

**Protocol changes.** none — coordinator-internal routing only. No change to coordinator/protocol/messages.go or the provider-swift Protocol. snap.fleetMedianTPS is already populated from heartbeat-fed tps_registry samples (registry.go:2761-2764 records slot.ObservedDecodeTPS; scheduler.go:942 reads tpsRegistry.Median into the snapshot). No new wire field is read or sent.

**Tests.** coordinator/registry/scheduler_test.go (go test ./registry/...):
1. TestProjectedDecodeTPSUsesFleetMedianWhenIdle — unit test directly on projectedPerRequestDecodeTPS: routingSnapshot{decodeTPS:23, fleetMedianTPS:9, observedDecodeTPS:0, backendRunning:0} → assert projected ≈ 9/(1+k), NOT 23/(1+k). FAILS without the fix. Also assert live-observed tier still wins: {observedDecodeTPS:20, fleetMedianTPS:5, backendRunning:2} → 20*(1+2k)/(1+3k) (unchanged).
2. TestProjectedDecodeTPSFallsBackToStaticWhenNoFleetMedian — {decodeTPS:23, fleetMedianTPS:0, observedDecodeTPS:0} → 23/(1+k): tier-3 fallback preserved (no regression for chips with no samples yet).
3. TestReserveProviderDeprioritizesIdleHistoricallySlowBox — end-to-end via reg.ReserveProviderEx (mirrors TestReserveProviderDecodeFloorPrefersAboveFloor). Two IDLE providers (NumRunning=0) for 'gemma', both static decodeTPS=23, but DIFFERENT chip families (set Hardware.ChipFamily='M3' on slow, 'M4' on fast — the tps_registry keys on (model,chip), which matches the task's per-(model,chip) framing and the real prod shape where slow gemma boxes are a chip cohort). Seed reg.tpsRegistry.Record('gemma','M3',9) and Record('gemma','M4',25). req with MinDecodeTPS=15. Assert the M4 box is selected. FAILS without the fix (both project ~23 static → either chosen).
4. TestReserveProviderDecodeFloorNeverFailsClosedWithFleetMedian — single IDLE box, static 23, seed Record('gemma','M3',6) several times, MinDecodeTPS=50 (above everything). Assert selected != nil — SOFT gate still serves the only box. Guards the don't-zero-out-gemma risk.
5. TestDecodeFloorFleetMedianKillSwitch — t.Setenv('EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN','false'); repeat scenario 1 → projected returns to ~23/(1+k) static. Confirms live kill-switch.
Existing TestReserveProviderDecodeFloorPrefersAboveFloor / NeverFailsClosed stay green (they exercise live observedDecodeTPS, unaffected by the new tier-2).

**Env knobs.** Reuse EIGENINFERENCE_MIN_DECODE_TPS (existing, default 15) unchanged — the floor value plumbed via Server.minDecodeTPS → PendingRequest.MinDecodeTPS (api/server.go:1082, api/consumer.go:606/5123, api/dispatch.go:655). NEW live kill-switch EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN (bool, default true) read LIVE via env.EnvBool inside projectedPerRequestDecodeTPS on each call (no restart; false = byte-for-byte pre-fix behavior). No prod-config flip needed to ship — on by default in code with an env off-ramp. The existing MIN_DECODE_TPS startup-read path stays as-is; only the new behavior toggle is read live (satisfies 'any new knob read live').

**Human-only.** none — coordinator-only code change, ships via normal coordinator deploy (EigenCloud prod deploy itself is human-only per repo policy, but no KMS/secret/prod-config change is required; the kill-switch defaults on in code).

**Risks.** Risk 1 (whole-fleet-slow zero-out — the explicit constraint): NOT possible. The change only alters the solo-rate INPUT to projectedPerRequestDecodeTPS; the filter at 577-587 is unchanged and only narrows the pool `if len(quality) > 0`, so when every gemma box is below floor the full pool survives and the request is still routed (no 429, no zero-out — verified by test 4). No reject branch added. Risk 2 (over-deprioritization / hot-spotting onto a few fast boxes): fleet median is per-(model,chip), so an entire slow chip cohort is deprioritized at once; if only fast boxes remain they could hot-spot. Mitigated by (a) the filter is a pre-filter to the SAME cost-based selection + near-tie queue-depth tie-break + random spread at scheduler.go:589-627, so load still balances across the above-floor set; (b) the QualityCap concurrency gate (snap.hasHeadroom, scheduler.go:914) already stops over-packing a fast box, so demand that can't fit spills to the next-best (incl. below-floor) box rather than queueing forever. Risk 3 (fleetMedianTPS is an under-load median, not a solo rate, so using it as `solo` understates the projection): intentional and safe-direction for a quality floor (bias toward routing AWAY from borderline boxes); the kill-switch reverts instantly if too aggressive. Risk 4 (cold start with no samples): tier-2 is skipped (fleetMedianTPS==0 → static), identical to today; no new behavior until real observations accumulate. What breaks next: if a chip's median is dragged down by a few overloaded samples it could deprioritize a chip that is fine at low batch — bounded by the 50-sample ring + the live kill-switch, and since it only ever DEPRIORITIZES (never rejects), worst case is mild mis-ranking, not lost capacity.
