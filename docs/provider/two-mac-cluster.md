# Two Macs as one provider (guided setup)

> Last updated: 2026-10-14

Two Apple Silicon Macs joined by one Thunderbolt 5 cable serve a model together:
each Mac holds part of its layers, and the pair serves as one provider. Setting
the pair up is done once, from `darkbloom cluster` on each Mac. No SSH, no
Remote Login, no IP address and no network setting is typed anywhere.

## What you need

- Two Macs with Thunderbolt 5 and macOS 26.2 or later, each with Darkbloom
  installed (the same version), and one Thunderbolt 5 cable between them.
- RDMA over Thunderbolt enabled on each Mac. This is Apple's own switch and only
  an administrator can turn it on, once, in macOS Recovery: start the Mac in
  Recovery, open Terminal, run `rdma_ctl enable`, restart. Step 1 of the guided
  setup says whether it is needed.
- Nothing to download by hand. The cluster keeps its models in its own store
  beside the product's model cache (`darkbloom-cluster-models`, same volume).
  Models single-Mac Darkbloom already installed are cloned in (APFS clones, no
  new disk blocks). A model only one Mac has is copied to the other Mac over the
  cable; a catalog model neither Mac has is downloaded once on the leader, then
  copied ([Models](#models) below). `--model-dir` still names another folder for
  a development setup; it is never needed.

## The steps, once

Start on either Mac. The Mac you start on drives the onboarding screens: it
chooses the model and options, sends every member its setup over the cable and
starts it; you never go back to the other Mac. Which Mac *controls* the cluster
afterwards is derived, not fixed (see [Control leader and failover](#control-leader-and-failover)).

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | the first Mac | Run `darkbloom cluster`. It checks RDMA, the cable and the cable port's isolation, and verifies the RDMA GID. Nobody waits on the cable yet, so it says **"On your other Mac, run `darkbloom cluster`."** and waits (q cancels). | one macOS administrator approval, only if the port is not isolated yet ("Darkbloom needs network access for the cluster cable") |
| 2 | the other Mac | Run `darkbloom cluster`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code. | its own approval if needed; `y` on each Mac when the codes match |
| 3 | — | The other Mac says **"Paired with <leader>. Continue on <leader>."** Its cluster service now runs; nothing else is ever asked there. | nothing |
| 4 | the leader | It shows both Macs' hardware and every model the pair can serve (held by both Macs, by one of them, or in Darkbloom's catalog), each with the planner's placement (which Mac holds which layers and which one decodes: the planner's choice, from both Macs' measured hardware and the model's pair-serving grant, not from who leads). Choose the model (enter takes the first). A model the other Mac lacks says how it gets there ("copy ... over the Thunderbolt cable (6.1 GB)"). | enter to copy (a copy predicted under 30 s at the speed measured on these Macs starts by itself, `n` within 3 s stops it); `y` to start serving |
| 5 | — | The leader saves the plan, syncs the member's setup to it over the cable (applied there at once), starts the member's part remotely, waits until both parts are loaded, and answers one test request. | nothing |

Counting every key: `y` on the other Mac, and `y`, enter, `y` on the leader
(four keys), plus at most one macOS approval per Mac.

Running `darkbloom cluster` again on either Mac shows the same menu: the
cluster's state with the control leader, a test request (`t`), another model
(`m`), stopping or starting (`s`) and a verify-teardown summary of every Mac
(`v`). On a Mac that does not lead, each choice is sent over the cable to the
control leader and its answer is shown as it is.

If both Macs start waiting at the same moment, the pairing's own rule picks one
to keep waiting (it leads) and the other says so and joins it.

The older six-step wizard is still there as `darkbloom cluster --wizard`.

## Models

- **Clone in.** Every model the single-Mac product installed and verified
  (`darkbloom models download`, its manifest receipt) is cloned into the cluster
  store with APFS clones, so it costs no disk space and keeps the catalog's
  exact manifest bytes (the cluster worker pins them).
- **Copy over the cable.** A model one Mac lacks is sent by the Mac that has it
  over the link control channel: keyed by the pairing (S17), encrypted and
  authenticated records, 4 MiB chunks acknowledged only after the receiver wrote
  and hashed them. The receiving Mac's cluster service accepts only a manifest
  whose aggregate digest this build's qualification records pin (a pair serves
  nothing they do not grant), refuses hard links, an occupied destination and too
  little free disk, writes uncached, hashes every file as it arrives, has its own
  installed worker check the staged configuration and manifest, and only then
  renames the folder into place. An interrupted copy resumes from the staged
  bytes; the leader's screen shows the rate and time left.
- **Download.** A catalog model neither Mac has is downloaded on the leader
  through the product's downloader (catalog manifest, per-file and aggregate
  SHA-256, written uncached), cloned into the cluster store and then copied.

## Control leader and failover

- **Derived leader.** Once a plan is adopted its rank 0 leads (requests enter
  there and the coordinator's registration treats the plan's first member as the
  head). Before a plan, the Mac that drove the onboarding leads. The choice uses
  only detected facts (which Mac holds the model alone, memory, GPU cores, then a
  stable member identity), never a host role.
- **Lease.** The leader renews a control lease with each member every 5 s
  (30 s time to live) on a listener of its own, keyed by the pairing like the
  rest of the link control channel. Claims carry a term; a Mac with a superseded
  claim is refused, steps down and never acts on the cluster.
- **Failover.** When the leader's lease expires the surviving Mac takes control
  at the next term. It keeps its part ready for **10 minutes** (the absence
  grace; `darkbloom cluster` says how long is left); if the other Mac returns in
  that time the pair re-forms with nobody serving alone. After the grace, a Mac
  the planner said holds the model alone serves it alone on this Mac
  ("degraded: serving on this Mac alone"); otherwise it says it cannot serve.
  When the other Mac returns, the pair re-forms and control goes back to rank 0.
  A start or stop typed while control was elsewhere travels with the lease.
- A development build reads `DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS`
  (0-3600) to shorten the grace for tests; a release build ignores it.

## MiMo V2.6 Flash on the pair

MiMo V2.6 Flash is granted on an M5 Ultra + M3 Ultra pair by its qualification
records (pipeline at the planner's cut, M5 Ultra rank 0, M3 Ultra decoding; the
mirrored order is refused). Each start hashes the 172 GB of weights with the file
cache off, so the hash does not fill the Mac's memory before the memory gate
decides; the gate itself is unchanged. MiMo has no MTP, paged KV or prefix cache
on the pair yet, and the pair decodes slower than the M5 Ultra alone.

### After a restart

Each Mac's cluster service runs that Mac's part while the leader has the
cluster serving: when a part ends (a member restarted, a session lost a member)
it starts it again, and the leader's session re-forms once the member is back,
with no question. The leader's service also checks the member every 15 seconds:
a member that missed a start or a stop (asleep, restarting, cable out) is
started or stopped as soon as it answers again. The serving API listens on
127.0.0.1 of the Mac that runs rank 0, which the planner chooses; the leader's
screen names that Mac. A signed release installs the cluster service as a
login agent ([always on](cluster-always-on.md)); an ad-hoc development build
keeps the service in the session that ran `darkbloom cluster` and says why.

## When something is in the way

- **No macOS prompt can be shown** (for example over SSH without a desktop):
  the check writes the exact commands the prompt would run to an owner-only
  script and prints one line to run once as an administrator:
  `sudo sh ~/.darkbloom/cluster-device/link-fix.sh`; then run
  `darkbloom cluster` again. A port an administrator already isolated this way
  is recognised and recorded (no change, no prompt), so
  `darkbloom cluster link --remove` can restore it later.
- **Internet Sharing shares to the cluster port itself**: the check says so and
  stops before any prompt. Turn the cluster port off under System Settings →
  General → Sharing → Internet Sharing → “To devices using”, then run
  `darkbloom cluster` again.
- **The leader cannot reach the other Mac**: run `darkbloom cluster` on the
  other Mac (no key needed); that starts its cluster service again.
- **A model is not offered for this pair of chips**: a pair serves a model only
  on chip classes whose cross-cable check passed; the reason is shown beside it.

## Undo

`darkbloom cluster link --remove` on each Mac restores the cable port's earlier
network settings (one approval). `darkbloom cluster pair --forget <pin>` removes
a pairing. Run on the leader, it first tells the other Mac over the cable, which
removes the pair's prompt-cache records (its own single-Mac cache stays) and
stops its part; each Mac also removes its own pair records when it unpairs.

## Cache settings

The leader's cache choices (`darkbloom cache set`, the prefix cache switch, the
daily write limit, the TTL and an explicit disk budget) reach the other Mac
through its cluster service, which applies them to the ranks it starts. Each Mac
keeps its own cache folder and, without an explicit budget, sizes the pair's
cache from its own free space.

## Not yet in this build

- A release build signed with Darkbloom's identity is needed for the pairing
  keys to live in the keychain across restarts; a development build uses a key
  file (`DARKBLOOM_DEBUG_SE_KEY_FILE`).
- The login agent and macOS's one Local Network approval need the signed
  Darkbloom.app ([always on](cluster-always-on.md)).
- Public serving through Darkbloom is not offered by the onboarding yet.
- A member cannot yet download a catalog model itself (the leader downloads and
  copies), and a model change typed on a Mac that does not lead cannot copy a
  model (run it on the leader).
- A release ships the cluster worker inside Darkbloom.app (`Contents/Helpers`);
  `--worker` names another one (a development build).
