# Two Macs as one provider (guided setup)

> Last updated: 2026-10-12

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

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | each Mac | Run `darkbloom cluster --model-dir <the folder that holds your model folders>`. Later runs need only `darkbloom cluster`. | nothing |
| 2 | each Mac | Step 2 (the cable): press `f`. Darkbloom gives the cable port its own network service with an address of its own, outside every bridge, no router and no DNS; macOS keeps it across restarts. | one macOS administrator approval per Mac |
| 3 | both Macs | Step 3 (pair): press `l` on both Macs. They find each other on the cable, and both screens show the same six digits. | `y` on each Mac when the digits match |
| 4 | the Mac that leads | Step 4 (model and plan): press `enter` (it asks the other Mac over the cable), choose the model with the arrow keys, press `enter`. The plan (which Mac holds which layers, the mode, the speed it expects) comes from both Macs' memory and the model. | `y` to save the plan and send the other Mac its setup |
| 5 | the other Mac | Step 4: press `a`. | `y` to save the setup it received |
| 6 | both Macs | Step 6 (serve): press `s` on the Mac that follows, then on the Mac that leads. | `y` on each |

That is six steps. Counting every question: two macOS approvals (one per Mac)
and six `y` answers (two for the pairing, one to save the plan, one to accept
it on the other Mac, two to start). A Mac that already shows a step as done
skips it.

After a restart of either Mac nothing is set up again: run `darkbloom cluster`
on both Macs and press `s`, then `y`, in step 6 (follower first). The pairing,
the link and both setups are kept.

## When something is in the way

- **No macOS prompt can be shown** (for example over SSH without a desktop):
  step 2 writes the exact commands the prompt would run to an owner-only script
  and prints one line to run once as an administrator:
  `sudo sh ~/.darkbloom/cluster-device/link-fix.sh`.
- **Internet Sharing shares to the cluster port itself**: step 2 says so and
  stops before any prompt. Turn the cluster port off under System Settings →
  General → Sharing → Internet Sharing → “To devices using”, then press `f`
  again.
- **The other Mac does not answer in step 4**: open `darkbloom cluster` on the
  other Mac too; its open wizard answers over the cable.
- **A model is not offered for this pair of chips**: a pair serves a model only
  on chip classes whose cross-cable check passed; the reason is shown in step 4
  and when serving starts.

## Undo

`darkbloom cluster link --remove` on each Mac restores the cable port's earlier
network settings (one approval). `darkbloom cluster pair --forget <pin>` removes
a pairing.

## Not yet in this build

- A release build signed with Darkbloom's identity is needed for the pairing
  keys to live in the keychain across restarts; a development build uses a key
  file (`DARKBLOOM_DEBUG_SE_KEY_FILE`).
- Starting the members at login (LaunchAgent) instead of step 6, and macOS's
  Local Network permission for a member started outside Terminal, come with the
  signed build.
- The installer does not yet place cluster model folders or the cluster worker;
  `--model-dir` and `--worker` say where they are.
