# Two Macs as one provider (guided setup)

> Last updated: 2026-10-12 (leader-first onboarding)

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
- The model folders on both Macs, in one folder per Mac (`--model-dir` below).

## The steps, once

Start on the Mac you want to control the cluster from: it becomes the
**leader**. The leader chooses the model and options, sends every member its
setup over the cable and starts it; you never go back to the other Mac.

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | the first Mac | Run `darkbloom cluster --model-dir <the folder that holds your model folders>` (later runs need only `darkbloom cluster`). It checks RDMA, the cable and the cable port's isolation, and verifies the RDMA GID. Nobody waits on the cable yet, so it says **"On your other Mac, run `darkbloom cluster`."** and waits (q cancels). | one macOS administrator approval, only if the port is not isolated yet ("Darkbloom needs network access for the cluster cable") |
| 2 | the other Mac | Run `darkbloom cluster --model-dir <its model folder>`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code. | its own approval if needed; `y` on each Mac when the codes match |
| 3 | — | The other Mac says **"Paired with <leader>. Continue on <leader>."** Its cluster service now runs; nothing else is ever asked there. | nothing |
| 4 | the leader | It shows both Macs' hardware and every model both Macs hold, each with the planner's placement (which Mac holds which layers and which one decodes: the planner's choice, from both Macs' measured hardware and the model's pair-serving grant, not from who leads). Choose the model (enter takes the first). | `y` to start serving |
| 5 | — | The leader saves the plan, syncs the member's setup to it over the cable (applied there at once), starts the member's part remotely, waits until both parts are loaded, and answers one test request. | nothing |

Counting every key: `y` on the other Mac, and `y`, enter, `y` on the leader
(four keys), plus at most one macOS approval per Mac.

Running `darkbloom cluster` again on either Mac shows where it stands: a member
says which Mac leads it and that nothing is needed there; the leader shows the
cluster's state and offers a test request (`t`), another model (`m`) or stopping
(`s`).

If both Macs start waiting at the same moment, the pairing's own rule picks one
to keep waiting (it leads) and the other says so and joins it.

The older six-step wizard is still there as `darkbloom cluster --wizard`.

### After a restart

Each Mac's cluster service runs that Mac's part while the leader has the
cluster serving: when a part ends (a member restarted, a session lost a member)
it starts it again, and the leader's session re-forms once the member is back,
with no question. The leader's service also checks the member every 15 seconds:
a member that missed a start or a stop (asleep, restarting, cable out) is
started or stopped as soon as it answers again. The serving API listens on
127.0.0.1 of the Mac that runs rank 0, which the planner chooses; the leader's
screen names that Mac. In this build the service itself is started by
`darkbloom cluster` (on either Mac, no key needed); starting it at login with
the always-on LaunchAgent (S18) is not in this build yet.

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
- Starting each Mac's cluster service at login (the S18 LaunchAgent) instead of
  running `darkbloom cluster` once after a restart, and macOS's Local Network
  permission for a service started outside Terminal, come with the signed build.
- Public serving through Darkbloom is not offered by the onboarding yet.
- The installer does not yet place cluster model folders; `--model-dir` says
  where they are. A release ships the cluster worker inside Darkbloom.app
  (`Contents/Helpers`); `--worker` names another one (a development build).
