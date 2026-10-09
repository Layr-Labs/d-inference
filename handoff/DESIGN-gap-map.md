# Design gap map

Everything known to stand between this branch and a supported two-Mac model.
Findings come from three independent read-only reviews of the inherited code
(control and security modules; runtime; provider and coordinator integration)
and from what was run on the two Macs. "Verified" means the reviewer or a test
confirmed it; "read" means it follows from the source and has not been
exercised.

Status: **fixed** (commit), **in progress**, **open**, **blocked** (on what).

## A. Getting a collective at all

| # | Gap | Evidence | Status |
|---|---|---|---|
| A1 | No executable in the branch could initialize a collective. The macOS 14 targets compile the JACCL stub, and the rank worker had no source | `jaccl_conditional.cpp`; the research worker package was not carried over | **fixed** `cf0f34afd`: sibling 26.2 package, verified real-JACCL build, no pin change |
| A2 | One Thunderbolt port had no IPv4 address of its own (bridge member), so JACCL refused its device | First two-rank attempt; `ifconfig`, `ibv_devinfo -v` | **resolved for this pair**: fixed by `darkbloom cluster` with the owner's approval; not persistent across a restart or replug (A7 step 4) |
| A3 | Nothing in Darkbloom told the operator about A2 before launch | Run on both Macs | **fixed** `761f14d64`: `darkbloom cluster link` and `cluster doctor` name the fault; Mac B reports `portBridgedWithoutAddress` |
| A7 | Link setup was manual. Requirement: plug in the cable, Darkbloom detects the RDMA link, configures what the link needs and starts onboarding; approving a macOS prompt is the only acceptable manual step | Owner requirement | **mostly done** `761f14d64`, `b01fa68ad`: `darkbloom cluster` detects RDMA and the connection and adds the address behind one macOS prompt; used for real on Mac B. **Open**: a one-time-approved helper so a restart or replug needs no prompt; starting the flow by itself on plug-in (today the operator runs the command, which then waits and watches); pairing and model steps after the link |
| A8 | The resident load refused any Mac with swap in use, and a 250 ms gate re-checked it during a request. Mac B has about 3 GB swapped; most Macs in daily use do | Real stage load refused on Mac B | **fixed** `960b855f5`: refused only under warning pressure; free-page requirements unchanged. Wants a second opinion |
| A4 | The pinned JACCL sends stale bytes after a partial payload (fixed-size frames) | Simulated-verbs harness: 4 of 5 groups fail on the pin with a non-zero stale tail | **fixed in the mlx fork branch** `97fbd680` (the research commit carried onto the current pin, author kept). Needs the mlx-swift repin (D2) |
| A5 | The pinned JACCL has no progress bound: polling loops spin forever on a lost completion or dead peer, and completion status is never read | Reproduced on the two Macs: the survivor spun for more than 9 minutes | **fixed in the mlx fork branch** `aec94c2b` and **shown on the two Macs**: with a 4 s limit the survivor reports the error and exits about 4 s after its peer dies; good traffic is unaffected. Until that is pinned, `39c1bb003` adds a thread deadline as the last resort. The guard is a requirement for any run with a model loaded, not an option |
| A9 | JACCL advertises the IPv4-mapped GID to the peer but always sends from GID index 1; on both Macs the mapped GID is at index 2 | Source read, `ibv_devinfo -v` | **tolerated on this pair**: stock JACCL passes all transport checks. The fork change `83291eb6` also passes; keep it out of the pin unless a pair needs it |
| A6 | Owner-authenticated JACCL bootstrap is unstaged. JACCL opens its own unauthenticated TCP coordinator socket on the link | `Collective.swift` staging note; mlx-c `489e965` (+192 lines on the staged pin) carries the bridge | **open**: needs the mlx-c pin decision; worker refuses the flags until then |

## B. One request across two ranks

| # | Gap | Evidence | Status |
|---|---|---|---|
| B1 | Any one-sided failure strands the peer in a receive forever: per-Mac deadlines, `cancel()`, the 250 ms resource gate, a validation failure before an ACK, a thrown token callback. No cancel is ever transmitted | Runtime review, verified by reading `QwenLayerStageGenerationDriver`, `CollectivePointToPoint`, `mesh_impl.h` | **open**; A5 bounds the hang, the owner must still end both ranks. Needs a bilateral deadline in the agreement |
| B2 | Sends may assume buffering JACCL does not provide (receive buffers are posted only inside `recv`; control messages are two back-to-back sends) | Runtime review, read; hardware behaviour unknown | **open**: probe on the real link first |
| B3 | `reserve` is a prepare with no abort: a refusal after reserve fails the resident model, there is no unreserve, reserved IDs consume the 16-request budget | Runtime review, verified by reading | **open** |
| B4 | The 300-second lifetime covers load plus every request; the two Macs expire at different instants | Runtime review, verified by reading | **open** |
| B5 | JACCL picks its frame class with `__builtin_available(macOS 26.3)`: larger frames from 26.3, 4 KiB frames below. The load agreement binds neither that nor the chip. JACCL's bfloat16 reductions also take a different code path on CPUs with native BF16 | Source read (`rdma.h`, `types.h`) | **open**, not hit by this pair or path: both Macs are past 26.3, and the layer pipeline moves raw bytes with send and receive, never a reduction. Bind the frame class in the load agreement; settle the BF16 reduction question before any tensor-parallel plan across different chips |
| B6 | The data plane is plaintext and unauthenticated; `CollectiveAuthenticatedRecords` has no caller; the installed owner hard-codes the plain mesh profile | Runtime and security reviews, verified by reading | **open**: design decision, see D1 |
| B7 | The generation driver, transport and control state machine have never executed and have no test seam (`Collective` is a final class over a real group) | Runtime review | **open**: extract a four-member transport protocol and run both ranks in-process |
| B8 | A late cancel marks a bilaterally retired request failed on one rank only | Runtime review, read | **open** |
| B9 | The admission refusal tests were vacuous: the "valid" identity used the wrong model ID, so every case failed the same guard | Runtime review; mutation check | **fixed** `9691c059e`: positive admission on both ranks from the registered metadata, one property per refusal |
| B10 | Only the registered Qwen3.5 9B artifact is accepted | Source | **done for this pair**: fetched from the model CDN, verified, on both Macs. Each Mac loads and releases both ranks' stages (`745a8f484`) |
| B11 | Every rank must hold the full artifact on its own disk: each one hashes all manifest files and then loads only its own layer range. A follower cannot receive its stage from the leader | Runtime review (`VerifiedCheckpoint`, `loadQwenResidentStage`) | **open**: requested 2026-10-08. Design: the leader sends only the follower's stage tensors over the link; the follower checks each against the pinned tensor inventory instead of trusting the sender; transfers are chunked (receives are capped at 16 MiB today); a follower with no local copy must be re-sent the weights after a restart |

## C. Serving through Darkbloom

| # | Gap | Evidence | Status |
|---|---|---|---|
| C1 | The coordinator never sent `cluster_member_accepted`; the provider's negotiation timer then tore the leader down about 10 s after connecting | Real in-process provider session, exact wire bytes | **fixed** `651b08e93`: sent as the last step of registration, only for an accepted member |
| C2 | `DistributedHTTPResponse.recordTerminal` had no caller, so every streamed completion aborted without a finish frame, usage or `[DONE]` | Ported engine and server suites; with the hunk reverted 4 of 10 tests fail | **fixed** `bca3d4c22` (terminal recording), `d8128c80f` (first-token budget, also for non-stream), `d3c68d239` (a refused stream admission answers before headers instead of 200-then-abort) |
| C3 | Capability reconciliation dropped the registry lock before reading registry-guarded state: a data race on the ordinary single-host path | Reproduced with the race detector | **fixed** `17da399ad` |
| C4 | A dead follower is waited on forever: remote cleanup completes only on the owner's terminal frame, and reserve and teardown await it unbounded | Integration review, verified by reading | **open** |
| C5 | The device lease journal is sticky and has no recovery tool: a failed launch, a 500 ms stall at hello, or a lost release handshake blocks every later start until the file is edited by hand | Integration and security reviews, verified by reading | **open**: journal immediately before launch, plus an explicit `cluster recover` |
| C6 | The follower's ordinary provider is not excluded: `worker-owner` never checks the provider PID lock, so a second model can load on top of a serving provider | Integration review, verified by reading | **open** |
| C7 | Lifetime-expiry teardown cannot complete with a slow worker: the owner stops reading at its deadline, SIGKILL follows 2 s after fence, the controller stops listening at lifetime + 2 s | Security review, verified by reading | **open**; SIGKILL after 2 s also conflicts with the no-orphan rule |
| C8 | The controller SIGTERMs a local owner on any reader error, orphaning its worker (no handler, no process group) | Security review, verified by reading | **open** |
| C9 | `provider.toml` was written with no mode: a file first created by an ordinary save was 0644 and the cluster readers refused it | Check script fails on the previous writer | **fixed** `420415ded`: owner-only atomic replace |
| C10 | Coordinator-originated inference never reaches the distributed engine: member mode answers 503, the pair catalog is nil outside tests, `BeginNativePair` has no production caller | Integration review, verified by reading | **open**: local serving first; coordinator traffic is a later gate |
| C11 | Quarantined pairs were never released; the machine identity stayed gated until the coordinator restarted | Registry tests on a fake clock | **fixed** `b048897ca`: released once every member has delivered its receipt or left, 40 s after the fixed expiry; a connected member that owes its receipt is never released by time alone |
| C12 | `Attach` requires TLS on the connection although Caddy terminates it; the load-command guard has no caller; no clock-skew allowance on the 30 s prepare check; `projectFirstToken` returns unbounded | Integration review (latent) | **open** |
| C13 | No start, stop, join, leave, drain or recover verb; the follower has no live status surface; a quarantined leader is unobservable over HTTP | Integration review | **open**: terminal UI gate |
| C14 | Still open after the restore: member heartbeats report `draining`; `CoordinatorClient.shutdownAndWait` is absent, so member teardown does not join the transport loop; several early error sites still answer a distributed stream with 200 then an abort (shutting down, duplicate ID, service allowance); the native-pair control is installed before any connection and can only throw (no production caller sets it); coordinator autopilot has no execution-role check and relies on the member reporting not enabled | Swift restore report | **open** |

## D. Decisions needed

| # | Decision | Options |
|---|---|---|
| D1 | Trust model for the pair | The peer is key-agreed, not authenticated: the native accepts whatever peer key arrives in the coordinator-relayed binding. Either the member verifies the peer hello's attested signature before sending the binding, or the coordinator is documented as trusted and the doc line "the coordinator does not possess its key" is corrected |
| D2 | Dependency pins for A4, A5, A6 | Three small fork changes (mlx send-frame clearing, mlx progress guard, mlx-c bootstrap bridge) and the mlx-swift pin that selects them. Each changes provider bytes |
| D3 | Session envelope | 16 requests and 300 seconds per session suit a qualification run, not hosting. Rotation exists for quota exhaustion; lifetime expiry stops the server |

## F. How the branch came to be incomplete

| # | Finding | Evidence | Status |
|---|---|---|---|
| F1 | The extraction from the research runtime (PR 1226) carried the new files but skipped edits to existing files and most of the provider tests (27 cluster test files there, 7 here). C2, the unguarded model commands and several member-mode leaks follow from this | `git diff --name-status` of the research PR against its base, compared with this branch against its base | **restored**: Go side `4b48612ef`, `45d21f76d`; Swift side `1280540b6`…`6c67c3987` (twelve commits, 21 research test files ported; each fix has a red run with its hunk reverted). Deliberately not restored: the solo provider taking the cluster device gate (it would let a sticky journal block ordinary serving, see C5 and C6), and ending a pair grant on every challenge-evidence clear |
| F2 | The three research archives (PRs 1227, 1228, 1229; 671 drafts) hold tested or physically exercised drafts for several open items | Read-only survey of each archive | See "Available to lift" below |

### Available to lift from the research archives

| For | Draft (under `experiments/cluster/research-archive/…/sources/`) | State there |
|---|---|---|
| A2, A7 | `control-delivery/…/rdma_alias_smoke_20260915.py`; `gemma-decode/…/decode-faster-than-solo-20260920/harness-cpu/alias.py` | The same alias fix, with its verification (IPv4-mapped GID present, port active, bridge members and routes unchanged) and removal. Used on real hardware, driven by sudo with a stored password, which is what A7 replaces |
| B2 | `gemma-decode/…/gemma4-decode-optimization-20260920/control-frame-draft` | One zero-padded 16 KiB control frame instead of length-then-body; physical |
| B3 | `control-delivery/…/cluster-worker-partial-admission-overlay-20260915` | Per-rank admission state, cancel only admitted ranks; CPU-validated |
| B1 | `control-delivery/…/owner-cancellation-recovery-draft-20260915` | Owner-level cancel and fence, then a fresh epoch returns the expected tokens; physical |
| C5 | `control-delivery/…/cluster-owner-release-eof-drain-correction-20260917`, `…/cluster-owner-retirement-shutdown-draft-20260915` | Two causes of a sticky journal; one reproduced on CPU from a physical failure. No recovery tool exists anywhere |
| C6 | `control-delivery/…/shared-device-exclusion-draft` | The ordinary provider takes the owners' gate; CPU-validated |
| A6 | `control-delivery/…/jaccl-owner-bootstrap-draft`, `…/jaccl-owner-channel-draft`, `…/cluster-owner-bootstrap-relay-overlay-20260915` | CPU-validated, never run over RDMA; does not remove the GID requirement |
| B6 | `control-delivery/…/collective-protected-scopes-draft-20260915`, `…/cluster-lab-encrypted-rdma-20260920` | Wiring is source only; cost measured on the real link without a model (5 MiB record: 4.50 ms encrypted, 2.02 ms raw) |
| B11 | `gemma-decode/…/gemma4-artifact-transfer-rsync-options-ready-20260917` | rsync over SSH with hash, identity and exclusive-rename promotion. Nothing in any archive sends weights over the link |
| More models | `gemma-decode/…/gemma4-native-layer-stage-draft-20260915` | Gemma 4 26B as a layer pipeline, exact against one Mac; a benchmark executable, needs an SDK change |

### What the research measured (two M4 Pro Macs, 24 GB and 48 GB, plaintext RDMA)

Expectation-setting only; none of it was run here.

| Model and shape | Pair | One Mac |
|---|---|---|
| Qwen3.5 9B, 8,192-token prompt, cut 16: prefill | 814 tok/s | 440 tok/s |
| same: decode | 24.7 tok/s | 37.7 tok/s |
| Gemma 4 26B, 4,096-token prompt, cut 7: prefill | 455 tok/s | 371 tok/s |
| same: decode | 32.0 tok/s | 47.1 tok/s |

A layer pipeline across two Macs prefills faster and decodes slower than one
Mac that can hold the model. Its value is models that do not fit on one Mac,
and long prompts.

## G. Performance, keepwarm and tensor parallel

Requirement (2026-10-08): very good performance, keepwarm ported from the
owner's ThunderMLX and oMLX work, and both pipeline and tensor parallel
supported. What those sources and the research archives actually measured
sets the expectations below; nothing here has been measured on this pair yet.

| # | Item | What the sources show | Plan and status |
|---|---|---|---|
| G1 | Pipeline speed | A two-Mac layer pipeline prefills faster and decodes slower than one Mac that holds the model (two M4 Pros, Qwen3.5 9B: prefill 814 vs 440 tok/s, decode 24.7 vs 37.7). Swift decode makes 11 transfers per token plus a pipe round trip to the owner | **open**: measure this pair first. Then: one control frame per step instead of length-then-body (research draft, physical), lookahead as the default prefill schedule (+16% measured in research), larger chunks than 512 (needs the 16 MiB receive cap raised and a same-chunk reference) |
| G2 | Keepwarm | Owner's measurements: single-Mac first token 1.8 s → about 1.45 s median (noisy) with a 120 GB model; a cold link ping about 0.7 s → 1–8 ms at a one-second cadence. Nothing isolates a per-token or link-idle effect for a pair. His own decision record keeps it off by default | **open**. Rule from his work: keepwarm must share the generation executor; a second thread issuing collectives corrupted or deadlocked the next request. Tier 1: a Metal-only pulse on the worker's single executor between commands (never touches the collective), default off, yields to a reserve. Tier 2, only if measurement shows a link-idle penalty: an owner-sequenced ping to both ranks with no reservation outstanding. Ship only if an OFF→ON→OFF run at 0/1/2/5/15/60 s gaps shows the OFF curve rising with the gap |
| G3 | Tensor parallel | Owner's Python TP2 (MLX-LM `shard()`): attention by head and MLP by column, two all-reduces per layer, embeddings, norms and head replicated, full checkpoint local on both Macs. Measured on this same pair: DS4 29–31 tok/s decode, Qwen3-30B 56.8 tok/s decode and 1,534 tok/s prefill; **no single-Mac figure is recorded for any of them**. Not bit-identical to one host (partials are rounded, then summed). The Swift runtime has no sharded layers | **open**. Arithmetic for Qwen3.5 9B on this link: 64 collectives per token at 50–150 µs each is 3–10 ms per token, against perhaps 15 ms on one Mac, so decode lands between 0.7× and 1.3× of one Mac; prefill 1.5–1.8× is plausible. Slices: (0) bf16 `[1,1,4096]` all-sum equality and latency on the link, plus the GPU→reduce→GPU cost, before any model code; (1) MLP-only TP against one-host logits; (2) full TP2 with per-layer residual hashes equal across ranks; (3) speed against each Mac alone. Risks: different chips (the M3 Ultra has native BF16; the M5 is unchecked), equal shards run at the slower chip, any one-sided exit strands the peer in a reduction |
| G4 | Decode faster than one Mac | In every source, decode gains came from speculation (MTP: DS4 29–31 → 78–80 tok/s) and batching, not from the second Mac. A phase split (pair for prefill, one Mac for decode, KV handed over at about 7 GB/s) measured 991 tok/s prefill and 29.6 tok/s decode on a 27B | **open**: for a model that fits on one Mac, phase split is the candidate that keeps pair prefill without the pipeline's decode penalty. It needs state transfer between ranks |

## E. Documents that are out of date

- `libs/darkbloom-cluster/README.md` says Transport, Generation and the Qwen
  resident runtime are unstaged and that nothing in the provider references the
  package; both are false at this revision.
- `docs/reference/cluster-control-protocol.md` and the cluster section of
  `docs/reference/configuration.md` describe end-to-end negotiation and "no CLI
  path"; neither matches the code.
