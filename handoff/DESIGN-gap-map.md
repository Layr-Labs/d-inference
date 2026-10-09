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
| A2 | One Thunderbolt port has no IPv4 address of its own (bridge member), so JACCL refuses its device | First two-rank attempt; `ifconfig`, `ibv_devinfo -v` | **blocked** on a network setting on that Mac |
| A3 | Nothing in Darkbloom tells the operator about A2 before launch | `cluster doctor` inspects saved metadata only | **in progress**: read-only `cluster link` probe |
| A7 | Link setup is manual. Requirement set 2026-10-08: plug in the cable, Darkbloom detects the RDMA link, configures what the link needs and starts onboarding; approving a macOS prompt is the only acceptable manual step | Owner requirement; A2 is the concrete case | **open**. Order: (1) the read-only probe names the exact problem (A3); (2) `cluster link` gains an approval-gated fix that applies the one address change through the system authorization prompt and re-probes; (3) detection on plug-in (link and port state changes) feeds the onboarding screen; (4) a one-time-approved helper so later plug-ins need no prompt. The address is not persistent, so the fix must reapply after reboot or replug |
| A8 | The resident load refused any Mac with swap in use, and a 250 ms gate re-checked it during a request. Mac B has about 3 GB swapped; most Macs in daily use do | Real stage load refused on Mac B | **fixed** `960b855f5`: refused only under warning pressure; free-page requirements unchanged. Wants a second opinion |
| A4 | The pinned JACCL sends stale bytes after a partial payload (fixed-size frames). The research fix (`stage_send_frame`, mlx `4e89c2e3`) is not in Darkbloom's mlx pin | Research commit; `NativeSendChecks` needs `send_frame.h`, absent at the pin | **in progress**: mlx fork branch |
| A5 | The pinned JACCL has no progress bound: polling loops spin forever on a lost completion or dead peer, completion status is not checked, the completion queue has no headroom | Source read; ThunderMLX incident (GPU-wired memory orphaned after a rank blocked in `recv` was killed) | **in progress**: mlx fork branch |
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
| C1 | The coordinator never sends `cluster_member_accepted`; the provider's negotiation timer then tears the leader down about 10 s after connecting | Integration review, verified by reading | **in progress**: coordinator worktree |
| C2 | `DistributedHTTPResponse.recordTerminal` has no caller, so every streamed completion aborts without a finish frame, usage or `[DONE]` | Integration review, verified by reading | **open** |
| C3 | Capability reconciliation dropped the registry lock before reading registry-guarded state: a data race on the ordinary single-host path | Reproduced with the race detector | **fixed** `17da399ad` |
| C4 | A dead follower is waited on forever: remote cleanup completes only on the owner's terminal frame, and reserve and teardown await it unbounded | Integration review, verified by reading | **open** |
| C5 | The device lease journal is sticky and has no recovery tool: a failed launch, a 500 ms stall at hello, or a lost release handshake blocks every later start until the file is edited by hand | Integration and security reviews, verified by reading | **open**: journal immediately before launch, plus an explicit `cluster recover` |
| C6 | The follower's ordinary provider is not excluded: `worker-owner` never checks the provider PID lock, so a second model can load on top of a serving provider | Integration review, verified by reading | **open** |
| C7 | Lifetime-expiry teardown cannot complete with a slow worker: the owner stops reading at its deadline, SIGKILL follows 2 s after fence, the controller stops listening at lifetime + 2 s | Security review, verified by reading | **open**; SIGKILL after 2 s also conflicts with the no-orphan rule |
| C8 | The controller SIGTERMs a local owner on any reader error, orphaning its worker (no handler, no process group) | Security review, verified by reading | **open** |
| C9 | `provider.toml` mode trap: cluster readers require 0600, the ordinary config save rewrites 0644 | Integration review, verified by reading | **in progress** |
| C10 | Coordinator-originated inference never reaches the distributed engine: member mode answers 503, the pair catalog is nil outside tests, `BeginNativePair` has no production caller | Integration review, verified by reading | **open**: local serving first; coordinator traffic is a later gate |
| C11 | Quarantined pairs are never released; the machine identity stays gated until the coordinator restarts | Integration review, verified by reading (latent) | **in progress** |
| C12 | `Attach` requires TLS on the connection although Caddy terminates it; the load-command guard has no caller; no clock-skew allowance on the 30 s prepare check; `projectFirstToken` returns unbounded | Integration review (latent) | **open** |
| C13 | No start, stop, join, leave, drain or recover verb; the follower has no live status surface; a quarantined leader is unobservable over HTTP | Integration review | **open**: terminal UI gate |

## D. Decisions needed

| # | Decision | Options |
|---|---|---|
| D1 | Trust model for the pair | The peer is key-agreed, not authenticated: the native accepts whatever peer key arrives in the coordinator-relayed binding. Either the member verifies the peer hello's attested signature before sending the binding, or the coordinator is documented as trusted and the doc line "the coordinator does not possess its key" is corrected |
| D2 | Dependency pins for A4, A5, A6 | Three small fork changes (mlx send-frame clearing, mlx progress guard, mlx-c bootstrap bridge) and the mlx-swift pin that selects them. Each changes provider bytes |
| D3 | Session envelope | 16 requests and 300 seconds per session suit a qualification run, not hosting. Rotation exists for quota exhaustion; lifetime expiry stops the server |

## E. Documents that are out of date

- `libs/darkbloom-cluster/README.md` says Transport, Generation and the Qwen
  resident runtime are unstaged and that nothing in the provider references the
  package; both are false at this revision.
- `docs/reference/cluster-control-protocol.md` and the cluster section of
  `docs/reference/configuration.md` describe end-to-end negotiation and "no CLI
  path"; neither matches the code.
