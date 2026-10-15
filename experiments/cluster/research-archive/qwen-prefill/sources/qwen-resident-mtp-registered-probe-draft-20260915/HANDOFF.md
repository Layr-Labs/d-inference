# Registered 9B single-proposal probe

This private source overlay routes one short request through the existing two-rank resident owner, serial generation driver, bootstrap, worker protocol and durable evidence sink. It captures actual committed final-rank pre-norm prompt history, computes one **unaccepted** MTP proposal, and then decodes the agreed target seed normally to select target token two. It does not consume the draft as a target input or implement accepted-prefix reconciliation.

Status: source checks passed; the new overlay has not been typechecked or executed. The prior selected loader and tiny proposal fixture have separate native/physical evidence. Those results do not qualify this registered probe. All changes are private; serving capability and MAIN are untouched.

## Exact base and overlay

`base.json` binds the corrected proposal handoff `ac7f81879364700777d512795e826d8c2c4f15b03ba9fd579c99f967df4b1aa3`. Apply this overlay to snapshot 4 of `qwen-resident-mtp-proposal-native-build-20260915/workspace`, SHA `8970c7869749883d5f58b2db9b83239e0835c2b2628ffe4cb9c45e55fae5d942`, after checking every snapshot member. That workspace contains the corrected proposal source, selected loader, real JACCL shim and matched MLX dependencies. The tiny configuration-envelope correction changes only the fabricated fixture.

`integration.json` lists eight runtime/worker files. The shared driver and prior proposal owner restore byte-exactly under `source_check.py`. `QwenLayerStageSession.swift` and `CBv2OwnedRequestState.swift` are unchanged here; pipeline's target-transaction work remains a separate overlay. The evidence sink is copied byte-exactly from the existing private benchmark worker, as bound by `worker-lineage.json`.

## Load, request and publication

- The wrapper requires the existing owned bootstrap attachment and a private `DARKBLOOM_BENCHMARK_EVIDENCE_DIR`. It calls `loadForMTPProposalProbe`, `reserveMTPProposalProbe`, and `startMTPProposalProbe`. WorkerMain, configuration, coordinator, pipes, Protocol and SSH owner remain unchanged.
- Loading requires `registered_qwen35_9b`, cut 4, serial prefill and the existing dedicated cache-0 policy. Both peers bind this private mode before target loading. Only rank 1 loads the already verified 31 head tensors and three input-embedding replicas. Target receipts and target norm/head ownership are unchanged.
- Ready follows both loads and the actual allocator/OS admission. Its named local capacity includes the full existing profile envelope; the private reservation gate only accepts **P1…32, C≤16, O2, empty stops**. Rank 1 includes the actual assistant/capture allowance; rank 0 retains its ordinary target allowance. No tensor state is allocated at reserve. Only one request may start per loaded owner.
- Prompt history enters the assistant only after the existing bilateral frame ACKs. The first target token and continue decision must also be acknowledged before the proposal. The next target forward consumes that agreed seed, regardless of the proposed token.
- Assistant state is discarded and released before clean target retirement and its existing bilateral ACK exchange. Result encoding and the unchanged durable sidecar write precede worker finished/retired events. The wrapper verifies that readiness is withdrawn after this one request. If either cleanup fails, both cleanup obligations are attempted; the original failure and cleanup failures remain reported.
- Ordinary serving/recording reservations are refused on this private owner. A stopped first token, incomplete history, missing ACK, deadline failure, encoding/write error, or second request does not produce a successful probe. Failure requires the existing owner cancellation/fence; a thrown call alone is not retirement proof.

## Root-run input and evidence gate

`request.json` fixes the first 32 IDs of the retained 8K prompt, chunk 16, two outputs, empty stops and a fresh request UUID. `input-provenance.json` binds the original prompt and the exact prefix. The request profile remains `registered_qwen35_9b_greedy_generation_v1`. Use a new membership epoch, both actual installed probe binary hashes, the existing verified model/configuration identities and JACCL device/coordinator settings. Generate native deadlines using the existing same-Mac Swift uptime source. Keep the existing ≤300-second owner lifetime, independent process bound, ≥6 GiB actual-free/AC/zero-swap gates and authenticated cleanup/journal checks.

Use the existing one-request SSH/Pair qualification path, with this probe worker replacing the private benchmark worker and this request replacing the long O128 request. The coordinator must continue after token one; there is no new supervisor or transport. Each rank emits one sidecar through the unchanged sink. A successful result requires:

- both sidecars bind the request, epoch, common probe-readiness fingerprint, ordinary agreement and exact native builds; their two selected target IDs and final chain match each other;
- P32/C16 gives two prefill frames plus one ordinary decode, three completed frames, committed frontier 33 and length finish;
- rank 0 has no assistant proposal/history fields; rank 1 reports one depth-1 unaccepted proposal, seed equal to target token one, actual assistant counts 31 before and 32 after proposal, and released assistant state;
- `proposalWasConsumedAsTargetInput` and `speculativeAcceptanceImplemented` remain false. Proposal equality with target token two is informational; a mismatch is not failure;
- both request retirements, model shutdown, authenticated owner lease release, child reaping/group fence and empty journals are retained independently. Source-built flags or a sidecar alone do not prove physical cleanup.

This first registered probe does not independently compare target logits/state with a full-model reference, measure external TTFT, or establish MTP acceptance/speedup. The ordinary result's `mtpEnabled: false` means the target output stream did not use speculative acceptance; the private sidecar explicitly records the one assistant forward.

## Next checks and build

Run `source_check.py` before and after overlay application. `Tests/ProbeControlCheck.swift` uses actual pure generation/proposal controls with fabricated ACKs to cover continued seed decode, mismatch, incomplete ACKs, client stop, extra frames and failed fencing. `ProbeCleanupCheck.swift` contains the exact private cleanup method with throwing test callbacks, covering independent cleanup and primary-error retention. Its 18-source Foundation command is in `foundation-command.json`, with the bounded runner `run_foundation.py NEW_OUTPUT_DIRECTORY`; compilation/execution is pending the root compiler slot.

In an isolated copy of the pinned workspace, apply `proposed/` and build product `darkbloom-cluster-worker` from `libs/darkbloom-cluster-worker` with the existing native build entry, jobs 2, Swift/C++ macOS 26.2 targets, exact dependencies and matched metallib. Verify final Mach-O minos 26.2 and real JACCL symbols. Do not build from the macOS-14 shared package or change its baseline. Preserve prior failures/binaries and retain a new complete source snapshot and build receipt. Root owns compiler scheduling, deployment and actual registered-model execution.
