# Native whole-expert comparison

This candidate executes quantized whole-expert projections and original-slot reassembly. It is staged for the root-owned disposable clone at `../gemma4-execution-20260920/build/workspace`. No original workspace, MAIN or vendor file was edited, and the author has not compiled or run it.

Apply the additions in `files.txt` and the small `Package.patch` to that clone, preserving any separately staged resident benchmark target. All ten Runtime files are additions. The two pure ownership/dispatch files are byte-exact copies of the previously root-qualified sixteen-group contract. The other files use the clone's existing `SwitchGLU`, `weightedExpertSum`, `TensorSelection`, `TensorDescriptor`, `VerifiedCheckpoint`, native error box, resource readers and checked byte arithmetic. No dependency, compiler flag, MLX option or metallib change is proposed.

## What executes

`ExpertAxisBank` constructs full-width local SwitchGLU banks from selected axis-zero weight/scale/offset planes. Quantization remains affine W4/G64 with split gate/up. Every leaf must have its exact packed shape/dtype and independently owned compact allocation. Its unmaterialized constructor/quantization parameters are all replaced before model parameter eval. The checkpoint reader uses the already-qualified full-artifact verifier and aligned selected reader; it does not load a full bank just to slice a local bank. The separate unsplit reference bank exists only in this numerical harness.

`ExpertAxisPreparedDispatch` takes an already authoritative CPU assignment packet, produces device row/local-ID/permutation tensors, gathers only locally assigned inputs, invokes the unchanged public `SwitchGLU.callAsFunction`, and reassembles unweighted `[tokens,topK,hidden]` outputs. Empty ranks run no expert projection. It then calls the exact existing **`weightedExpertSum`**, preserving original slot order and weights. It does not replace this with `.sum(axis:)` at a different location or sum rank-local weighted partials. The forward methods themselves perform no CPU tensor read, eval, synchronization, normalization, file I/O or route renormalization.

The first check is local, with both banks in one process. Dynamic GPU routing-to-variable-length-packet production, device-only dispatch, collective exchange, full decoder integration and production capacity are still unqualified. Checkpoint mode performs an explicit fixture-only readback of the actual stock-operator router replay outside the expert forward. It loads the actual router and sparse pre/post-norm weights, preserving precise selected-logit softmax and learned per-expert scaling. It does not claim interception of Gemma's private router. Attention, dense/shared branch, residual, KV/state and full-model generation are outside this one-layer expert boundary check.

## Root build command (not executed)

From any directory, under the root's bounded owned compiler runner:

```
swift build --package-path /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster-worker --scratch-path /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster-worker/.build-native-worker -c release --jobs 2 --disable-automatic-resolution --skip-update --disable-build-manifest-caching --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2 --product GemmaExpertAxisCheck
```

The new product is `.build-native-worker/arm64-apple-macosx/release/GemmaExpertAxisCheck`. Reuse the exact native resource bundle from that build; bind actual binary/resource identities after build success. There is no guessed future binary hash.

## Qualification commands (not executed)

Run sequentially under the existing root-owned process-group/canonical-lease/resource supervisor, with maximum315 seconds outside the native300-second fence. Copy/deployment and the quiet GPU slot remain root-controlled. These commands are native GPU execution, not Foundation-only tests:

```
GemmaExpertAxisCheck --synthetic-small
GemmaExpertAxisCheck --synthetic-gemma
GemmaExpertAxisCheck --checkpoint /Users/developer/DarkbloomDev/models/Gemma4-26B --layer 0
```

The first mode uses real synthetic affine W4 tensors, H128/I704/E16, F32 and BF16 metadata/activations, and expects60 numerical cases. The second uses actual Gemma expert geometry H2816/I704/E128 and BF16, expecting30 cases. Both exercise contiguous unequal ownership (6/10 or48/80), noncontiguous unequal ownership, balanced routes, all-rank0, all-rank1, and token counts1/7/8/9/33 across sorted-assignment boundaries. Direct packed synthetic generation materializes only requested expert planes and avoids first allocating a full floating model.

Checkpoint mode is mandatory before claiming real-artifact EP arithmetic. It verifies the exact registered config/manifest/aggregate and1697 source descriptors, then reads each selected bank's nine expert leaves plus seven router/norm leaves for the requested layer. It expects10 cases (five row counts/two ownership maps) with actual router replay/weights. The input is a deterministic residual probe, not a token prompt or full decoder activation. Run representative sliding and global layers separately after layer0 passes; no all-layer claim follows from one layer.

Each ownership also runs five native contract refusals: duplicate bank ownership before reading, incompatible returned tensor, duplicate router ID, swapped rank banks and wrong weight dtype. The earlier sixteen Foundation checks remain separate and need no repeat. Every native eval/readback is followed by the same native error/deadline/resource check; a native fault takes precedence over a Swift refusal.

Acceptance requires exact bytes at every per-expert output and the weighted sparse boundary, plus sparse post-norm in checkpoint mode. Maximum absolute and relative RMS errors and hashes are retained as diagnostics. A numerical mismatch writes the bounded report and exits2; an execution failure exits1; timeout exits124. No tolerance widening is encoded. A difference caused by a changed gather kernel or assignment batch must be diagnosed rather than declared acceptable from token agreement. The primitive deliberately uses the generic unchanged weighted reduction; no E128-only optimized selector is widened for smaller banks.

## Resource and retirement scope

The diagnostic reservation accounts for the full reference plus both selected banks, actual allocator bounds, two largest selected host buffers, aligned-read scratch, explicit projection/reassembly/router arrays and fixed bounded host/index/report allowances. It retains the existing6-GiB actual-free floor,4-GiB operational graph/workspace headroom,2-GiB allocator headroom, pressure1, zero swap, AC, normal power mode and nominal/fair thermals through the existing readers. This is a conservative one-layer diagnostic reservation, not a measured serving floor or a whole-process peak proof. No 48/80 full-model fit is inferred.

The entry's SIGALRM remains active through stdout and exit. Root must continuously drain bounded stdout/stderr and fence/reap the child group; the report does not assert physical lease/process cleanup. Successful native return additionally checks all weak bank references released, synchronizes existing streams, clears this process's freed-buffer cache and observes zero cache. On error, synchronization/cache release runs before the original native error is rechecked. The new target never creates a collective or alternate owner, and it never registers a serving capability.

Use the resulting exact layer comparison as the gate for a subsequent same-owner two-rank transfer path. Its next missing components are admitted variable-length device dispatch/transport and a narrow actual expert-call integration, not another model or request lifecycle implementation.
