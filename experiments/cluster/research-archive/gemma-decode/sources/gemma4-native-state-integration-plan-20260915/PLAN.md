# Gemma stage: native probe and shared state integration

The compiled stage is a Module with a throwing residual entry point. It is not a LanguageModel or a new request owner. The existing CBv2 native probe and owned-state machinery can serve it through two separate additive changes. No model payload/forward has run in this work; the native build passed seven value-only groups and all 29 metadata cuts.

## Existing probe and precise gap

`MLXLMCommon/ContinuousBatchingV2/Paged/NativeKVTypeProbe.swift:30` accepts a `CBv2SteppableModel`, validates fresh empty caches, installs one private RecordingRow per storage owner, then runs two-token prefill and one-token decode. It records transformed native K/V, rejects asymmetric or phase-varying types before graph evaluation, evaluates output + recurrent + KV roots, and unbinds all caches in defer. The recorders are three-token full buffers even for window kinds; the existing attention mask supplies the correct short-probe visibility. There is no current one-token-only probe contract.

`SteppableAdapterV2.swift:24` wraps a LanguageModel and exposes a nonthrowing tokens→logits operation. Making Gemma4LayerStage pretend to be a LanguageModel would misrepresent rank1 input/head responsibility and cannot propagate its throwing residual checks. The stage's requirement for one live row is compatible after the existing probe installs its recorders. Its distinct-row/equal-frontier checks should remain intact.

Add an attention-only throwing-forward overload to the same probe, sharing the existing recorder/validation/evaluation/result implementation. The callback receives phase, bounded count and installed caches and returns only the output root; no tensors escape in Result. The original model overload keeps token validation, recurrent transaction setup/rollback/commit, exact 2+1 sequence and observed result semantics. Do not duplicate RecordingRow or replace existing callers.

Rank0's callback uses its verified loaded embedding and existing stage forward. Rank1 must receive the actual preceding stage residual with explicit observed shape/dtype and preserved phase/sequence. Its output dtype and K/V types cannot be inferred from `loadedEmbeddingOutputDType`, packed weights, or a guessed zero residual. The first paired native probe therefore still requires a tiny ordered residual transfer through the existing serialized collective path. The public callback addition alone is not that physical proof. Preserve the two-token prefill plus one-token decode unless a separately reviewed recipe is introduced; the decode step already exercises the one-token shape.

Probe work must remain under canonical device exclusion, pre-reserved short-probe allocations, active native error handling, fixed local deadline and failure poisoning. Do it after verified assignment but before request geometry/readiness. Keep probe caches separate from request caches; after probe scope ends only CPU observations may survive. Recheck actual stage K/V metadata against the admitted observations on every later forward before state commit.

## Shared state consumer map

The complete MAIN direct consumer search for CBv2RequestGeometry/CBv2OwnedRequestState/CBv2OwnedStateSnapshot is confined to these sources:

| File | Current constraint and required treatment |
| --- | --- |
| `Runtime/CBv2RequestGeometry.swift` | Qwen-only constructor, all-full attention, uniform known KV dtype, exact compact attention/recurrent union. Keep that initializer and behavior; add a separately validated stage-layout path with per-layer observed K/V dtypes. |
| `Runtime/CBv2OwnedRequestState.swift` | One backend/bank/recurrent owner and existing run/eval/commit/retire ordering. Keep ownership. Validation currently demands retainedCount == absolute count, full-length snapshots and one dtype. Add explicit per-layer retention/type validation. |
| `Runtime/CBv2OwnedStateSnapshot.swift` | Requires full retention and nonnil recurrent snapshot; global map and CPU-owned copy/digest are already reusable. Accept absent recurrent snapshot only for a validated empty recurrent spec, and capture window logical ranges explicitly. |
| `Runtime/QwenLayerStageSession.swift` | Sole MAIN constructor of owned state. Its loaded Qwen guards, schedule, native dtype and boundary contract remain unchanged. |
| `Runtime/QwenRecordedState.swift` | Full-model/stage reconciler only admits full_attention or linear_attention, checks global components/frontier and established fingerprint. Preserve it as the Qwen adapter; a common reconciliation helper may consume explicit expected component descriptors, with identical old serialization. |
| `Runtime/QwenLayerStageRankStateCapture.swift` | Same Qwen-only component policy and fingerprint. Retain its adapter's exact expected coverage and identity; do not label a Gemma state as Qwen. |

No other MAIN source directly instantiates these types. Private frozen full-reference/qualification source closures must remain unchanged and be compared separately when deriving later candidates.

## State representation and accounting

A healthy fresh request has one immutable local/global map, one attention kind per cache, per-layer measured K/V dtype, and a committed absolute frontier. For this initial prefix-off/MTP-off stage path, full rows retain `[0, frontier)` and window rows retain `[max(0, frontier-window), frontier)`. Physical ring order is not chronological order. All caches must still bind exactly the owned rows and publish the same absolute position; retain count must not be used as RoPE position.

`WindowedSequenceKV.swift:307` snapshots concatenate temporal slices when the ring wraps. This is suitable for explicit diagnostics, but calling it for every successful decode could allocate a window copy. Prefer a small value-only storage-metadata accessor inside MLXLMCommon for healthy-step validation (stored shapes/types, absolute range and allocation bytes), while explicit snapshots keep chronological CPU-owned copies. This adds no second KV storage or ownership implementation.

`ContiguousKVBackend.swift:17` has one admission dtype; actual rows adopt first K/V dtype. `AdmissionV2.Config.layerElementBytes` already supports per-layer sizes. A mixed-type stage must not feed a narrower single dtype into the backend. Either add the same exact per-layer size table to its reservation estimates, or conservatively charge the widest measured type across all rows and make that conservative cost explicit in the outer ceiling. The former is the precise reusable option; neither may advertise more capacity than actual Ready/live admission.

Contiguous window rows allocate all 1024 slots on the first write, even for a short request. Include that fixed ring plus retained chunk views/temporary attention work under the existing activation bound. The three-token dtype probe uses its own full recorder and does not demonstrate the physical window allocation needed for serving. Zero recurrent layers means a valid empty state, not a missing observed recurrent contract. Never relax the nonempty-Qwen checks.

Snapshots should bind absolute frontier, logical retained start/end, shape/dtype/global layer/component and digest. Existing Qwen fingerprints/serializations must stay byte-identical when every retained start is zero and its recurrent spec is unchanged. A future window reconciler should compare logical chronological contents and explicit bounds, never ring physical order or only retained byte count. Keep failures fatal to that request; no healthy-path rollback is introduced.

## Small implementation and validation order

1. Add the throwing probe overload with common existing loop. Test both overloads' same phase/count/result, throw after partial cache update, malformed/native mixed types and guaranteed unbinding; no Gemma loader yet.
2. Add pure per-layer state geometry/retention validation and backing metadata, then thread it through the existing owned state and diagnostic snapshot. Test full/window frontiers below/at/after 1024, mixed observed types, empty recurrent, overflow/refusals, nonmatching owner rows, and unchanged Qwen fingerprints. Existing actual tiny Session tests remain the regression gate.
3. Only then bind the verified Gemma descriptor/loading, exact selected tensor assignment, short paired probe, request owner and existing transport. Native acceptance requires real constructor/load/probe/allocation and whole-vs-split state/logit comparison at wrap-crossing chunks. No new decoder, engine, RPC, prefix cache or speculative path is needed.

The required registered Gemma payload/owner integration remains unimplemented. Neither the passing metadata fixture nor these source findings establishes loaded readiness, state capacity, numeric equality or performance.
