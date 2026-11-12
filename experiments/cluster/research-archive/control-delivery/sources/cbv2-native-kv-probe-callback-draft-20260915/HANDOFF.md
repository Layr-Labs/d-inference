# Throwing native KV probe callback

This isolated two-file patch adds an attention-only throwing forward overload to the existing CBv2NativeKVTypeProbe. It lets a stage supply validated residual forwarding without inventing a LanguageModel conformance or another state owner. MAIN is unchanged; no compiler, MLX/GPU operation, model payload or remote work ran for this patch.

```swift
CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: freshCaches) {
    phase, tokenCount, installedCaches in
    // Supply verified stage input, preserve phase/sequence and actual dtype.
    // Return the existing stage forward output root.
}
```

The callback overload is attention-only. Both overloads call the same private runProbe core; the original model overload keeps its existing recurrent specification/transaction behavior. Legacy token construction and native-error check still precede recurrent bind. The complete RecordingRow/helper body and evaluation/result-validation tail are byte-identical. The same two-token prefill plus one-token decode, shape/dtype checks, root evaluation and cache unbinding apply. Per-phase invalid/asymmetric K/V is checked before that phase's eval; cross-phase dtype consistency is checked after both phases, exactly as before.

The new callback is synchronous/non-escaping. It is not retained, and the returned Result retains only scalar/array metadata. A callback error unwinds through existing defer cleanup. This does not prove owner/device retirement: the caller still owns deadline/admission, real input/transport validation, any submitted native work and failure synchronization. Rank1 must consume an actual validated incoming residual; loaded embedding dtype is not KV or boundary dtype evidence.

Three added Swift Testing methods preserve all original fixture bytes. They compare old/new entry results and exact [prefill2, decode1] ordering; throw after cache mutation in either phase and require all rows unbound; reject malformed fresh-cache input without invocation and retain changing/asymmetric dtype refusal. These tests construct tiny MLX tensors and therefore require a separately granted native/GPU fixture slot. They have not been compiled or executed. Existing CBv2NativeKVTypeProbeTests should run with them; Qwen recurrent probe tests remain an additional regression gate before promotion.

No stage loader, boundary wire, shared request geometry, snapshot schema, capacity policy or native decoder changed. The shared window-aware state work remains a separate source slice mapped in gemma4-native-state-integration-plan-20260915.
