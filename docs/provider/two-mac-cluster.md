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
  Recovery, open Terminal, run `rdma_ctl enable`, restart. `darkbloom cluster`
  says whether it is needed.
- Nothing to download by hand. The cluster keeps its models in its own store
  beside the product's model cache (`darkbloom-cluster-models`, same volume).
  Models single-Mac Darkbloom already installed are cloned in (APFS clones, no
  new disk blocks). A model only one Mac has is copied to the other Mac over the
  cable; a catalog model neither Mac has is downloaded once on the leader, then
  copied ([Models](#models) below).

## The steps, once

Run `darkbloom cluster` on each Mac, pick a model, done. Start on either Mac: it
drives the onboarding screens, chooses the model, sends the other Mac its setup
over the cable and starts it; you never go back to the other Mac. Which Mac
handles commands afterwards is worked out by the cluster itself (see
[If a Mac goes away](#if-a-mac-goes-away)).

The planner picks tensor parallel or pipeline for your Macs by itself. Phase
split is off.

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | the first Mac | Run `darkbloom cluster`. It checks the Thunderbolt cable ("Cable found.", "Cable ready."). Nobody waits on the cable yet, so it says **"On your other Mac, run `darkbloom cluster`."** and waits (q cancels). With two cables it asks which one to use. | one macOS administrator approval, only the first time ("Darkbloom needs network access for the cluster cable") |
| 2 | the other Mac | Run `darkbloom cluster`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code. | its own approval if needed; `y` on each Mac when the codes match |
| 3 | — | The other Mac says **"Paired with <leader>. Continue on <leader>."** Its cluster service now runs; nothing else is ever asked there. macOS may ask once to allow Darkbloom on the local network: allow it. | the Local Network prompt, once |
| 4 | the leader | It shows both Macs' hardware and every model the pair can serve (held by both Macs, by one of them, or in Darkbloom's catalog), one line each: size, how it is split, each Mac's share and the expected speed. Models that fit in the Macs' free memory now come first. Choose the model (enter takes the first). A model the other Mac lacks says how it gets there ("copy ... over the Thunderbolt cable (6.1 GB)"). | enter to copy (a copy predicted under 30 s at the speed measured on these Macs starts by itself, `n` within 3 s stops it) |
| 5 | — | Choosing is starting: "Starting <model> on both Macs in 3 s; press n to stop here." The leader saves the setup, sends it to the other Mac over the cable, starts both Macs, waits until both are loaded and answers one test request. | nothing |

When it serves, the screen says how in one line, for example:

```
Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers.
API at http://localhost:8000 on Apple M3 Ultra, 256 GB.
```

Counting every key: `y` on the other Mac, and `y` and enter on the leader
(three keys), plus at most one macOS approval per Mac.

Running `darkbloom cluster` again on either Mac shows the same menu: the
cluster's state (the deployment line first), a test request (`t`), another
model (`m`), stopping (`s`) and a check that both Macs released their memory
(`v`). When it is stopped, `m` chooses a model and serves again. On a Mac that
does not handle commands, each choice is sent over the cable to the Mac that
does, and its answer is shown as it is.

If both Macs start waiting at the same moment, the pairing's own rule picks one
to keep waiting (it leads) and the other says so and joins it.

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

## Which models a pair serves, and in which mode

A pair serves a model only under the grant this build derives from its
cross-cable qualification records (each a run of both Macs compared with
single-Mac references under the near-tie rule). A grant is bound to the mode
family its records ran: the pipeline (with its compact-decode variant), the
pipeline with speculative rounds, tensor parallel, and the hand-off modes
(phase split and the prefill/decode hybrids, kept but off by default) are four
families, and a passing record of one opens no other. Within a family, a chip
reaches a role (the decoding rank, or a rank before it) only when a passing run
of that family ran it in that role; a record from a Mac generation no longer
on hand still grants that chip, and only it. A record that diverged withholds
its own family at every cut (that family is then planned only at shapes a
check passed in, and never started); an inconclusive record neither grants nor
withholds. The planner and every Mac's start apply the same rule, and the
onboarding offers a model only when every rank of its chosen placement would
pass that start check: a model its records withhold (a withheld family still
has a plan at a passed shape) is listed as not served, with the reason.

## If a Mac goes away

The cluster keeps itself running. When one Mac goes away (turned off, asleep,
cable out), the other keeps its part ready for 10 minutes; if the Mac comes back
in that time, the cluster re-forms with nothing to do. After that, a Mac that
can hold the model alone serves it alone until the other Mac is back, and
`darkbloom cluster` on it says so. Commands typed on either Mac keep working:
they are handled by whichever Mac runs the cluster now.

## MiMo V2.6 Flash on the pair

MiMo V2.6 Flash is granted on an M5 Ultra + M3 Ultra pair by its qualification
records (pipeline at the planner's cut, in the order its records passed; the
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
started or stopped as soon as it answers again. The screen says which Mac
serves the API. A signed release installs the cluster service as a login agent
([always on](cluster-always-on.md)); an ad-hoc development build keeps the
service in the session that ran `darkbloom cluster` and says why.

After a restart or power cut a Mac serves again once it is logged in. With
automatic login on (System Settings → Users & Groups; needs FileVault off) that
happens by itself; `darkbloom cluster` says which applies to each Mac. After a
Darkbloom update, the cluster sets itself up again by itself ("Updating the
cluster setup after a Darkbloom update.").

## When something is in the way

- **No macOS prompt can be shown** (for example with no one logged in to the desktop):
  the check writes the exact commands the prompt would run to an owner-only
  script and prints one line to run once as an administrator:
  `sudo sh ~/.darkbloom/cluster-device/link-fix.sh`; then run
  `darkbloom cluster` again. A port an administrator already isolated this way
  is recognised and recorded (no change, no prompt).
- **Internet Sharing shares to the cluster port itself**: the check says so and
  stops before any prompt. Turn the cluster port off under System Settings →
  General → Sharing → Internet Sharing → “To devices using”, then run
  `darkbloom cluster` again.
- **The leader cannot reach the other Mac**: make sure the other Mac is on and
  logged in; it rejoins by itself. If you denied the Local Network prompt there,
  allow Darkbloom in System Settings → Privacy & Security → Local Network, then
  run `darkbloom cluster` again.
- **A model is not offered**: the reason is shown beside it, for example "Not
  yet qualified on this pair of Macs" (a pair serves a model only where its
  cross-cable check passed).
- **A model does not fit now**: it is listed after the ones that fit, with what
  frees the memory ("Quit apps on <Mac> first"); the fit is checked again right
  before the start.
- **The start does not finish**: the screen shows each Mac's last error and
  offers `d` to save a diagnostics file in your home folder (no keys, addresses or
  names in it; nothing is written if any would remain).

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

- The login agent and macOS's one Local Network approval need the signed
  Darkbloom.app ([always on](cluster-always-on.md)).
- Public serving through Darkbloom is not offered by the onboarding yet.
- A member cannot yet download a catalog model itself (the leader downloads and
  copies), and a model change typed on a Mac that does not lead cannot copy a
  model (run it on the leader).

## Developer notes

Nothing here is needed to use the cluster.

- `--model-dir <folder>` names another model folder for a development setup.
- A development build keeps its pairing key in a key file
  (`DARKBLOOM_DEBUG_SE_KEY_FILE`); a release signed with Darkbloom's identity
  keeps it in the keychain.
- A release ships the cluster worker inside Darkbloom.app (`Contents/Helpers`);
  `--worker` names another one.
- `darkbloom cluster link --remove` restores a cable port's earlier network
  settings; `darkbloom cluster link` checks the port and names its details.
- Phase split (one Mac decodes alone after a prompt split) is kept behind an
  explicit developer setting and is never chosen automatically.
- A development build reads `DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS`
  (0-3600) to shorten the 10-minute absence grace for tests.
