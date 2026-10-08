# Resident whole-layer stages with fresh requests

2026-09-14. Source-only plan; no implementation, build, GPU, model load or
candidate replay. Initial scope: a bounded serialized cohort on the already
admitted dense-Qwen stage plan, not a general concurrent serving API.

The current source does **not** establish that GDN fusion causes a second fresh
StageSession to fail. Keep its existing layout guard. The missing explicit
contract is resident model ownership and permitted post-fusion storage, followed
by complete retirement of every request before another one starts.

## Current facts and limits

| Source | Actual behavior |
| --- | --- |
| `QwenLayerStageSession.swift:48–85` | Checks actual model layout at line60, frozen trainable set, source/Plan/configuration and native dtype/protocols; creates a new geometry and owned state. |
| `ModelPartition.swift:47–50` | Layout hash contains sorted parameter path, dtype and shape only; no bytes, strides, buffer offset or allocation identity. |
| `Qwen35.swift:244–248,409–490` | Fused projection is unregistered. Existing qkv/z/b/a weight/scales/biases are concatenated/evaluated, and original registered names become same-shape/dtype views. |
| `Qwen35.swift:324–374` | Module/parameter replacement invalidates the fusion cache; cached source signatures compare MLXArray wrapper identity with `===`. This is not a tensor-content checksum. |
| `QwenLayerStageProfiledComputeAdmission.swift:12–86` → `ProfiledComputeOwner.swift:5–19` | First validates retained source/storage/request fields, then constructs StageSession and requires zero committed tokens. No second compact-buffer uniqueness assertion occurs here. |
| `VerifiedQwenLayerStageLoading.swift:45–76` | Original materialization checks unique compact allocation, zero offset and bounded allocated bytes before each parameter update. That historical load proof cannot be reasserted unchanged for later fused views. |
| `QwenLayerStageLifecycleCheck.swift:14–65`, `ProfiledSelfCheck.swift:27–40` | Existing synthetic paths deliberately create fresh requests on the same model objects after a committed-state fault and after prior requests. This is source support for reuse, not a new real9B timing result. |

`Module.freeze` disables gradients (`Module.swift:882–914`); it does not forbid
`update`, module replacement or in-place MLXArray mutation. The public
`evaluatedBufferInfo` is metadata-only and exposes no common allocation ID
(`AllocationFootprint.swift:23–46`). Metadata equality alone cannot establish
that arbitrary externally supplied arrays are the authorized fused views.

The immediate one-shot barrier is orchestration: `QwenLongPrefillRankCheck:17–49`
loads a stage, runs one request, then requires model weak release/cache clearing.
`runQwenLongPrefillRankRequest` already takes a Loaded stage and returns CPU
records; it is the reusable request body. Current mode admissions separately
require one repeat/zero warmups. Do not weaken their existing semantics.

## One proposed load/fusion sealing boundary

Add one private resident-stage owner factory that performs the existing verified
load once, keeps the complete Loaded stage private, and exposes only scoped
request execution. Do not accept a caller-created receipt as ownership authority
or return the model/Module/MLXArray parameters. Preserve the original sourceLoad
and storage commitment as load-time evidence; do not rewrite their fingerprints
to describe fused storage.

Use the first ordinary, explicitly excluded priming request to exercise the
unchanged native forward and all layers. Fully retire that request through the
same barriers listed below. Then seal once, outside measured request intervals:

- Recheck original path/dtype/shape layout, complete registered names, frozen
  trainable set, source/Plan/configuration/arithmetic identity and role.
- Add a narrow Qwen-specific **read-only provider seal hook** where the private
  fused parent and source signature are accessible. It must verify every expected
  recurrent bank’s actual frozen quantized projections, cached wrapper signature,
  fused parent shapes/dtypes and exact recorded source-view row intervals. For
  registered9B cut12, expected recurrent-bank counts are9 and15. Count each
  weight/scale/bias parent once; children are authorized views, not independent
  compact allocations. Do not infer shared ownership from BufferInfo equality.
- Record an opaque resident ID/generation and CPU seal receipt that links the
  original load identity to this specific model’s permitted transformation.
  The provider hook observes the existing fusion; it must not concatenate,
  replace modules, change kernels, evaluate weights or introduce a new math path.
  Existing completed-request synchronization precedes inspection. A missing or
  unexpected bank/layout/signature refuses sealing; no fallback admission.

This focused hook is proposed work in the pinned model dependency, not an API
that is currently callable from ClusterInference: Qwen35GatedDeltaNet and its
fusion fields/helpers are internal/private. Coordinate the source pin/build
change explicitly. It avoids pretending a shape hash is a physical-storage
certificate. No content readback or rehash of all weight bytes is required.

Owner exclusivity remains essential even with that seal. Retain registered-array
wrapper identities and the provider’s fusion generation/signature so a replaced
module invalidates the resident owner cheaply at the next request boundary.
Keep the existing Session metadata guard. An unchanged wrapper ID does not detect
in-place mutation: disallow all external parameter access/mutation while resident,
and treat any internal model mutation outside the admitted fusion as a bug that
poisons the owner. This is an ownership/source contract, not protection against
arbitrary memory corruption or malicious code inside the process.

## Fresh request and retirement contract

State machine: load → priming request → seal → one active lease → cleanly retired
→ sealed, with any failure → poisoned → cohort shutdown. The owner holds at most
one request; reject overlapping/reentrant calls and stale leases before state or
transport creation. Each request has a fresh UUID/epoch, admitted recorded history,
new context/schedule, KV backend/rows, recurrent state and v4 transport/tickets.
Keep the source/Plan identity fixed and reconstruct each existing agreement from
the current request. No previous frontier, cache rows or consumed ticket is reset
and reused.

Before accepting the next request, require:

1. Every expected frame committed and every consumed ACK drained; no Prepared
   boundary or pending CPU consumption ticket remains. Existing sender/receiver
   weak-original-handle checks remain in force.
2. Final native selection/token transfer and post-stop release complete. Capture
   required final diagnostics once, then close the context and clear final logits.
3. `CBv2OwnedRequestState.retire:147–166` has synchronized both streams, cleared
   pending evaluation, released KV rows and recurrent state, and proved backend
   used/reserved bytes zero and all cache rows empty. Context/session references
   leave a bounded autorelease scope before the owner returns to sealed.
4. Both rank processes reach the next fresh readiness exchange only after their
   local prior retirement. That exchange provides a peer barrier before the next
   start/clock; do not treat rank0’s completed post-stop send as proof that rank1
   has already closed its request. Reuse of the underlying group is serial only.

Any deadline, peer/protocol error, failed close or storage-signature change ends
this resident cohort. Do not continue on the same group after failure. Preserve
existing parent cancellation/process-group fences and primary/cleanup diagnostics.
This stricter initial cohort policy does not erase older local-only recovery tests.

Per-request success must report request retirement with weights still resident,
not the current one-shot outer `modelReleased=true`. A new bounded cohort envelope
owns final weak model release and cache clearing once, after all requests and all
CPU results have detached. Keep old one-shot records unchanged. Do not clear the
allocator cache between warm requests by accident; record its retained size and
resource observations. Existing boundary/final evidence readbacks may remain for
the first correctness milestone; add no per-request full-weight hash, model-file
scan or new GPU readback for residency validation.

## Small qualifying step

First use the unchanged lower-level request body twice on one verified tiny stage
pair to verify the actual layout guard before changing it; extend the existing
same-resident lifecycle fixture instead of writing another forward loop. Then
qualify the new seal and at least two fresh requests (including distinct synthetic
histories, e.g. A/B/A) with exact baseline state/logit comparison and zero-frontier
checks. Exercise wrong seal/role/Plan, same-shape module replacement, reentry,
failure after stage0 commit, pending ACK, retained final logits and late close
failure. Pure/fake ownership fixtures precede root’s native tests.

For real registered9B, freeze a bounded warmup plus measured-request cohort using
the same plan/input/reference and arithmetic policy. Verify final state/token/
logit metadata against the separately qualified same-cut full reference and record
resident memory after priming and retirement. The existing first-token timer still
includes fresh context construction and full request execution; sealing/loading
and designated warmups are separately recorded. A comparable solo resident control
must follow the same policy before any throughput conclusion. Unmeasured workspaces,
allocator residency, process-global MLX serialization and device-specific behavior
remain limits. No resident real9B execution or performance result is asserted here.
