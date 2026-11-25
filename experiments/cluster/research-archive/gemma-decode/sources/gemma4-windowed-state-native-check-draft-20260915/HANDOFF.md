# Actual window-state fixture, pending native validation

The private `WindowedRequestStateCheck` exercises the real callback probe, cache bank, contiguous rows, owned request evaluation/commit/retirement and explicit CPU snapshots. It introduces no model admission, replacement cache implementation or Gemma weights. No Swift compiler, GPU, model, remote operation or cache clone has run for this package.

The fixed two-layer geometry uses a BF16 full row (one KV head × 32), an FP32 sliding row (two KV heads × 64, window 4), global indices 5/6, capacity 32 and maximum chunk 7. The actual prefill-2/decode-1 probe must confirm both types before request construction. The fixture asserts 8,192 native KV bytes, 12,288 backend reservation bytes and a 14,336-byte retained-window temporary bound. These small values and the fixed native-active ceiling authorize only the synthetic fixture.

The pending native cases cover:

- Frontiers 1/2/3/4/5/12/16/21, including a chunk larger than the window and repeated wraps. CPU-generated little-endian bytes establish chronological key/value contents without using the native snapshot to derive expectations.
- Metadata-only inspection of wrapped rows, stable storage identities/reservations and immutable CPU snapshots across later writes. Equal retained bytes remain distinct when logical range, global indices or layout identity changes.
- Real wrong-row binding, device-position mutation, changed first-write dtype, descriptor shape/window mismatch, destructively lost history, pending speculative window writes, invalid output, excess chunk and post-evaluation cancellation. Each refusal must close the actual owner, release backend reservations and drop row ownership. The shape/window cases deliberately corrupt the fixture's expected descriptor; they do not exercise malformed native SDPA inputs.
- Empty recurrent generations across all ordinary mixed-row steps; actual four-layer Qwen forwards through the legacy full-attention/recurrent path; byte-identical legacy v1 snapshot fingerprints against the previous capture body; retained refusal for missing nonempty recurrence.

`core-composition.json` records the only three changes to the successful target-transaction core. Reversing them restores that exact source, including its progressive target commit/reconcile and retirement paths. `WindowedStateLegacySnapshotControl.swift` is the exact prior capture body with only its type name changed and the duplicate owner entry extension omitted. All fixture Runtime additions are behind `CBV2_WINDOW_STATE_FIXTURE`.

The existing tiny Session/proposal/target products remain unchanged and still need reruns against the composed native build. Actual Gemma stage forward, measured boundary/KV types, paired numerical equality, outer allocator/activation admission and production eligibility remain separate. These checks do not enable windowed speculative target verification.
