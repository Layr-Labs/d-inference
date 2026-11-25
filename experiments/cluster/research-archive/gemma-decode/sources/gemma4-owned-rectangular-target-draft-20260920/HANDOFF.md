# Owned rectangular attention target verification

Source-only private successor, 2026-09-20. Nothing here was compiled, run on a
GPU, loaded with registered weights, promoted, or enabled for serving.

This adds one bounded attention-only transaction to the existing
`CBv2OwnedRequestState`. The original owner, contiguous backend, row identities,
native error checks and retirement remain authoritative. The existing Qwen
serial/recurrent `CBv2TargetVerification` is byte unchanged. The 14-file overlay
has four exact preimages and ten new paths; `integration.json` names each.
`source-context.json` pins the ordinary Gemma/SDK/fixture context. No active
workspace was changed.

## APIs for the actual Gemma adapter

```swift
try state.beginAttentionVerification(
    steps: width, captureLayerIndices: [28, 29],
    admit: admitActualAdditionalResources, check: check)
var hidden: MLXArray?
let logits = try state.stageAttentionVerification(
    check: check, additionalTargets: { hidden.map { [$0] } ?? [] },
    forward: { caches in
        let result = textModel.cbv2ForwardWithHidden(tokens, caches: caches)
        hidden = result.lastHidden
        return result.logits
    }, validateOutput: validateAllWidthLogitRows)
// Decide the accepted INPUT prefix, including the seed token.
let frontier = try state.reconcileAttentionVerification(keeping: acceptedInputs, check: check)
// Only now may the same owner publish tokens/update its request schedule and
// snapshot its actual full29/window28 rows for the next assistant seed.
```

The model-call spelling above is illustrative; the adapter must use the actual
Gemma overload and cache type conversion. The three owner method signatures are
concrete. Each stage returns all caller-produced logits. `additionalTargets`
keeps the actual pre-normalization hidden result in the same eval and error
check boundary. Width is 1...4, at most the unchanged maximum chunk, and fits
the unchanged admitted context. Exactly one stage and one reconciliation are
allowed. `keeping` is an input count (0...width), not the count of newly emitted
tokens; zero is useful for cancellation/controls. The normal greedy round must
account for seed input and correction/bonus output separately.

The mandatory admission callback receives a pure named-array ledger. It must
not mutate the owner and is not authority by itself. The outer session must
admit the additional rounded arrays, model graph/head/hidden terms and any
assistant/transport overlap before returning. The ordinary layout fingerprint
continues to identify an ordinary request; the new plan adds a distinct
verification fingerprint. No public capability or model eligibility changes.

The SDK SPI borrows the existing serial-query rectangular attention flags and
the existing capture fence. It does not change attention math. Contiguous
captures retain pre-write descriptors; recyclable-backend captures would use
the existing fence/fallback, but this owner currently accepts only full and
windowed contiguous rows. Stage eval includes output, hidden/other targets,
position/full/ring roots, staged window tensors and borrowed chunk views.
Pending validation reads scalar/shape/dtype metadata plus existing one-element
positions, without snapshotting full KV. After rollback/commit, the owner
evaluates actual ring writes, rebinds positions and restores base capacity
before publishing the frontier. A failure retires the whole original request.

## Resource boundary

See `RESOURCE-LIFETIMES.md` and `resource-ledger.json`. The ledger is derived
logical state accounting, not a measurement or proof of the whole process.
The original allocator limit, native error handler and fresh 6/4/2 GiB resource
checks remain required. No floor is lowered. The target adapter and assistant
must retain their existing owners, load gates and cleanup responsibilities.

## Qualification staged here

`Tests/compile-command.json` is a jobs=2 Foundation-only plan check command
template. A root-owned bounded runner must supply a fresh output, preserve all
receipts and bind the pinned inputs. It covers the exact 30-layer Gemma
geometry, BF16/F32, P4096/O128, widths 1...4, named byte sums and refusals.

The native product is `AttentionTargetVerificationCheck`; build the composed
worker package with the existing macOS 26.2/jobs=2/no-resolution settings and
`-Xswiftc -DCBV2_WINDOW_STATE_FIXTURE`. Its two accepted arguments are
`check-arguments` (no GPU) and `run-attention-target-on-gpu` (explicit later
physical grant). Main retains the actual canonical device exclusion through
stdout and uses a 60-second alarm. The check retains 55 seconds, 64 MiB native
active increment and the existing resource environment guard. A parent must
continuously drain bounded output, own/reap the full process group, and verify
the same empty lease inode and raw resource history. Nothing runs during build.

Native output has 24 named groups. It executes 56 width/accepted-prefix cases
at frontiers 2/3/4/9 using actual mixed BF16/F32 full/window caches and a real
prefill2/decode1 type probe. It compares the new owner with an independent
direct SDK transaction of the same width, an ordinary accepted prefix,
independent CPU-encoded chronological bytes, and the next decode. It also
checks repeated rounds, retained pre-write captures, admission/width/partial
forward/cancellation/replay/reentrancy failures and row/capacity retirement.
Run the unchanged WindowedRequestStateCheck and both Qwen target/session
controls as separate regression products under their existing qualification
settings. This new native product does not silently rerun those controls.

## Real-model validation still required

The synthetic tests isolate storage and serial-query attention. Gemma's other
GEMMs still use the width of the rectangular pass. A real-model width-4 pass may
therefore have different bytes from four one-token forwards. Record greedy
tokens, every logit row (max absolute/relative error and argmax), preNorm hidden
and post-reconcile state. Require exact same-shape rollback/reference state;
report rectangular-versus-serial differences separately. Do not relabel an
existing strict numerical failure or infer model equivalence from the tiny
cache fixture. Actual assistant draft/finalization, remote transfer and
end-to-end accepted-prefix publication remain in the parent adapter work.
