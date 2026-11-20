# Registered Gemma full/staged forward source

This is an uncompiled private Runtime slice. It implements real verified text loading, actual full-model or selected-stage forward, and shared window-aware request ownership. It adds no command, installed eligibility, native capability, resource permit, expert parallelism, or performance claim. No Gemma payload was read or model constructed while preparing it.

## Implemented cut

- `Gemma4RegisteredSource` verifies the pinned checkpoint and compares every one of its 1,697 actual descriptors with the sealed artifact metadata. Text selection contains 1,339 whole tensors; the 358 excluded vision tensors are never materialized. `Gemma4ForwardSelection` is the same selection used by the loader and the staged Foundation fixture.
- `Gemma4PreparedForwardModel` constructs the existing `Gemma4Model` for a full reference or the frozen `Gemma4LayerStage` for a selected rank. It retains the original global configuration. Only the quantizer table is relocated. Exact destination keys, packed shapes, per-projection 4/8-bit affine policy and final loaded layout are checked. Each stage owns its embedding object; rank1 uses its copy for the tied output head.
- `materializeRegisteredGemma4` uses the existing verified descriptor reader, cache bypass/aligned scratch, ordered mandatory pre-read checks, F16-to-BF16 conversion, native compact-storage checks and exact read accounting. The loaded value has a file-private initializer. The source checkpoint does not escape into it. Load provenance explicitly does not establish resource admission.
- `Gemma4ForwardProbe` uses the existing real two-token prefill / one-token decode recorder. Rank1 requires a supplied actual rank0 residual of the admitted type for each phase. The probe is bound to the loaded layout and Plan; it retains no arrays. A nested native-error handler preserves native faults before callback validation/cancellation errors. Actual cross-rank phase/producer authorization is still the caller's obligation.
- `Gemma4OwnedForwardSession` dispatches the real model through `CBv2OwnedRequestState`. Full and sliding attention use the compiled generic geometry and actual observed per-layer K/V types. The existing frame/EOS schedule is reused under a distinct Gemma profile. Failure retires the whole request. Snapshots use the existing logical chronology implementation; routine healthy validation does not copy full KV contents.
- `Gemma4ForwardBoundary` is a local correctness boundary with frame/token/Plan/stage identities and an owned-copy operation. Its mapping fingerprint is metadata, not an invented physical storage commitment. It adds no transport protocol. The scoped entry returns only `Data`, requires explicit healthy retirement, checks weak model release and clears allocator cache on success/error.

## Exact prerequisites

Use the qualified `gemma4-windowed-state-build-20260916/workspace` state/loader ancestry. Its retained source snapshot is `cbe0586202236cbc225e4de06bbaad28139c20612b49142e6b3310c08f24a3e8`; dependency snapshot is `d63cf7457244c7b67b48f3aa7ff3ea1b421dc0239717e2a7eb8f05411cb12707`. These are provenance pins, not a new full-tree revalidation here.

That workspace does not contain the native Gemma stage constructor. Compose the five runtime changes from `gemma4-native-layer-stage-draft-20260915`, manifest `ceb44868d0f05139a04f85f449a12df66d8de9555c768b43d6c0396f7a0a88e4`, before the eight additions here. Its four additions are absent in both MAIN and the qualified window workspace; its `Gemma4Text.swift` preimage matches both exactly. `integration.json` records all five checks and eight additions. No existing Qwen source changes are included.

`source-controls.json` binds the selected actual APIs and all Foundation fixture inputs. The native stage candidate and generic window state were compiled separately; their combination with this new code has not been typechecked. Root's three successful window/session/target GPU controls do not establish Gemma weight, full-forward or bilateral correctness.

## Next gate

The precise blocker is a closed registered Gemma MoE resource owner, described in `RESOURCE-GAPS.md`. Four mandatory callbacks identify its construction, ordered load, probe and request boundaries. They are low-level obligations, not a caller-supplied capacity attestation. No top-level executable entry is provided while that owner is missing.

After source review, schedule the 26-source Foundation check in `Tests/run.py`. Then build this Runtime composition without a model run, using a fresh private source/cache snapshot. Only after resource admission is implemented should an existing guarded native controller invoke this scoped entry and the normal greedy sampler for an actual registered full-versus-split short comparison. `VALIDATION.md` specifies the evidence and refusal cases. Do not enable installed Gemma or copy Qwen's model-bound admission to open this gate.
