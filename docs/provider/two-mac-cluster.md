# Two Macs as one provider (guided setup)

> Last updated: 2026-10-20

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

The screen follows five stages: **Connect**, **Pair**, **Choose**, **Start** and
**Test**. The model list names the choice that Enter selects and explains why
any unavailable model cannot be selected. Headings use color on supported
terminals; `NO_COLOR` and redirected output remain plain text.

Setup reports completion only after the test response succeeds. If that request
fails, the saved setup remains available: run `darkbloom cluster`, check its
status, and press `t` to retry the response.

The planner picks tensor parallel or pipeline for your Macs by itself. Phase
split is off. A model whose artifact ships a speculative (MTP) head can also
decode as speculative rounds across the pipeline, and does by default where its
own cross-cable qualification records passed and measured the rounds faster
than the plain pipeline of the same placement (this build: Qwen3.8 27B, Qwen3.5
9B and MiMo V2.6 Flash). The onboarding then says "pipeline with speculative
decoding". A draft is kept only when it is the model's own choice at that
position, as the verify window computes it; the window's arithmetic differs in
its last bits from one-token decode, so, as with the pipeline itself, output
matches a single Mac's up to near ties. Your pair's own measured speed-up
replaces the records' figure in the choice once the pair has served the same
placement both with and without the rounds.

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | the first Mac | Run `darkbloom cluster`. It checks the Thunderbolt cable ("Cable found.", "Cable ready."). Nobody waits on the cable yet, so it says **"On your other Mac, run `darkbloom cluster`."** and waits (q cancels). With two cables it asks which one to use. | one macOS administrator approval when the selected port needs configuration ("Darkbloom needs network access for the cluster cable") |
| 2 | the other Mac | Run `darkbloom cluster`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code. | its own approval if needed; `y` on each Mac when the codes match |
| 3 | — | The other Mac says **"Paired with <leader>. Continue on <leader>."** Its cluster service now runs; nothing else is ever asked there. macOS may ask once to allow Darkbloom on the local network: allow it. | the Local Network prompt, once |
| 4 | the leader | It shows both Macs' hardware and every model the pair can serve (held by both Macs, by one of them, or in Darkbloom's catalog), one line each: size, how it is split, each Mac's share and the expected speed. Models that fit in the Macs' free memory now come first. Choose the model (enter takes the first). A model the other Mac lacks says how it gets there ("copy ... over the Thunderbolt cable (6.1 GB)"). | enter to copy (a copy predicted under 30 s at the speed measured on these Macs starts by itself, `n` within 3 s stops it) |
| 5 | — | Choosing is starting: "Starting <model> on both Macs in 3 s; press n to stop here." The leader saves the setup, sends it to the other Mac over the cable, starts both Macs, waits until both are loaded and answers one test request. | nothing |

When it serves, the screen says how in one line, for example:

```
Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers.
API at http://localhost:8000 on Apple M3 Ultra, 256 GB.
```

When the coordinator in your provider configuration cannot take a cluster
member yet (it is unreachable, or it has no cluster support), the pair still
serves, on the leader's local API only, with the same local token as
`darkbloom start --local`, and a third line says so:

```
Serving locally on this Mac's API; public serving needs a coordinator with cluster support.
```

Nothing to do: the next start registers with the coordinator once it supports
clusters. A coordinator that refuses this pair is not treated this way; the
start fails and says why. To serve without any coordinator, use
[`darkbloom cluster local`](#serving-locally-only).

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

## Serving locally only

`darkbloom cluster local` serves the pair for you alone: the same steps, model
choice, planner, copies, speculative decoding, caches, failover and stop as
`darkbloom cluster`, but no Mac of the cluster contacts a coordinator. Nothing
registers, sends heartbeats, takes public traffic or bills, and serving needs
no network beyond the cable.

1. On the leader, run:

   ```bash
   darkbloom cluster local
   ```

   Not paired yet, it pairs first as in [the steps](#the-steps-once). Name a
   model to skip the list: `darkbloom cluster local Qwen3.5-9B` (its id or the
   name the list shows). On a cluster that already serves, it switches the
   cluster to local only and waits until it serves again.
2. Read the API's place from the ready screen:

   ```
   API at http://localhost:8000 on this Mac, and at port 8000 of its LAN or tailnet address.
   Serving locally only on this Mac's API: no coordinator, no public traffic.
   ```

3. Get the key: `darkbloom local` on the Mac the screen names prints the base
   URL, the network URL and the API key. Every request needs the key.

The API listens on every network of the leading Mac (LAN or tailnet) by
default. To keep it on that Mac alone, run
`darkbloom cluster local --bind 127.0.0.1`; `--bind` takes `localhost` or a
numeric IPv4 or IPv6 address. The API has no TLS, so the key and the text
cross the network in the clear: on a network you do not trust, keep it on the
Mac or reach it over a tailnet (encrypted). With the macOS firewall on, macOS
may ask once to let Darkbloom accept incoming connections.

The choice is kept: after a restart or reboot both Macs serve locally only
again, until you switch back. In `darkbloom cluster`, `p` serves through
Darkbloom again and `l` serves locally only; on a serving cluster the leading
Mac's part restarts that way and the screen waits for it. The model list still
reads Darkbloom's catalog when the network is up (to download a model neither
Mac has); with no network, it lists the models already on the Macs. Only
catalog models are served. Qualification records never gate local-only
serving.

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

For your own use, a pair serves any model Darkbloom has a cluster stage adapter
for. `darkbloom cluster` detects both Macs, you pick a model, and the planner
checks memory and picks tensor parallel or pipeline. A model is refused only
for one of two reasons, each said in one line:

- the two Macs together cannot hold it in any sharded layout (pipeline or
  tensor parallel);
- this build has no cluster stage adapter for it.

Check the printed mode and reason before starting. TP eligibility comes from
the model's tensor layout, the runtime's advertised modes and supported rank
counts; this check reads metadata and does not load the weights. TP does not
require a pipeline layer cut. An unsupported model or rank count falls back
to pipeline when eligible and fitting, without requesting a link measurement. For a compatible TP
runtime, automatic selection still requires measured encrypted-link costs,
memory fit and a predicted advantage over pipeline. A new pair without those
link measurements uses an eligible fitting pipeline; a supported worker's first load records
the measurements for later planning. GLM currently has a pipeline adapter only.
See the [placement planner](../../libs/darkbloom-cluster/Sources/DarkbloomClusterPlacement/ClusterPlacementPlanner.swift)
and [mode explanation](../../libs/darkbloom-cluster/Sources/DarkbloomClusterPlacement/ClusterRequestMix.swift).

Chips never decide. Each Mac's memory gate still decides every load; its margins
scale with the Mac's memory below 96 GB, so a smaller Mac takes the share it can
hold (one layer is a share).

Qualification records (cross-cable runs compared with single-Mac references
under the near-tie rule) do two things only:

- They steer the planner. A shape that diverged on a chip combination (each
  rank's chip in rank order, the cut, the mode family) is not planned or
  started there. Every other shape is, whether or not a check passed in it.
  A Mac checks its own rank with its own chip, so it refuses a rank-shape its
  chip diverged at with any partner; the planner applies the same rule and
  picks another cut. The planner refuses only when every placement the Macs can
  hold diverged there.
- They decide public traffic. A passing record qualifies its model, artifact
  and mode family for public traffic on any Apple silicon. The families are the
  pipeline (with compact decode), the pipeline with speculative rounds, tensor
  parallel, and the hand-off modes (kept, but off by default); a record of one
  qualifies no other. A pass contradicted by a divergence of the same shape
  counts for nothing. The coordinator's parity qualification still decides each
  public placement.

A model or mode with no passing record is served for you, and the plan and the
onboarding say in one line: "not yet qualified for public traffic".

Time budgets (startup, first token, stop) are derived from the setup and the
installed artifact, not from a per-model table:

- The first-token allowance reaches the setup's request deadline at the
  longest prompt. The planner derived that deadline from the chosen placement's
  predicted speed on your Macs: three times the prediction, plus 30 s.
- The startup allowance comes from the artifact's size, at load rates below the
  slowest any Mac has recorded.

### Response length

Cluster workers accept up to 32,768 output tokens and 32,768 prompt tokens,
within a 65,536-token combined ceiling. Each model's declared context and both
ranks' live memory admission may reduce that budget. Omitting `max_tokens` on the local endpoint uses the full
allowance, clamped to the model and remaining context; an explicit
`max_tokens: 32768` requests the same allowance. A model can finish earlier
at its stop token. Requests above the output ceiling receive HTTP 400 `output_too_long`;
requests that exceed the admitted combined context are refused before generation.
After updating, let the normal cluster setup refresh both worker capabilities
and the derived request deadline before serving. For adapters such as GLM that
reserve their whole request scope at load time, automatic placement prices that
full memory budget even when recent chat requests are short. Request history
still guides the speed estimate and choice of split.

### GLM candidate setup

For the current registered GLM artifact, a new automatically derived setup uses
its 2048-token candidate chunk limit when both the model layout and installed
worker admit it. The plan reports when no matching long-prompt measurement is
available. A short historical pass remains evidence of its original request;
it does not qualify the larger chunk or establish its speed. The candidate's
[transport and workspace qualification](../architecture/inference.md#glm-cluster-prefill-bounds)
remains required, with image and MTP qualification separate.

After a Darkbloom update changes the worker identity, the existing update path
replans and adopts the setup on both Macs. Derived limits follow the installed
layout and capability; saved explicit diagnostic limits remain in effect.
Verify the adopted plan and both members' readiness before serving. No new
manual configuration edit is required. See the
[configuration readers](../reference/configuration.md#automatic-cluster-chunk-policy).

## If a Mac goes away

The cluster keeps itself running. When one Mac goes away (turned off, asleep,
cable out), the other keeps its part ready for 10 minutes; if the Mac comes back
in that time, the cluster re-forms with nothing to do. After that, a Mac that
can hold the model alone serves it alone until the other Mac is back, and
`darkbloom cluster` on it says so. Commands typed on either Mac keep working:
they are handled by whichever Mac runs the cluster now.

## How the split is chosen

The split is worked out from each Mac's hardware and measured speed only: what
is cached or running when you plan never moves it. A Mac is given a share only
when its whole need fits its GPU working set and what its memory can give a
model with every app closed (macOS keeps part of the memory as file cache that
no model can use). If a Mac's apps hold memory the chosen share needs, the
screen says "Quit apps on … first" instead of picking a slower split.

When several splits predict the same time (two identical Macs, or Macs with
equal measured speed), the one that leaves each Mac the largest share of its
own memory is chosen: identical Macs split the layers evenly, and a Mac with
more memory takes more. A faster split is never given up for an even one.

## Prompt prefixes on the pair

Both Macs keep the prompt prefixes of every model family, in memory and in the
encrypted SSD tier: a repeated long prompt starts with its prefix restored, and
after both Macs restart the SSD tier gives it back. Gemma 4 keeps each
sliding-window layer's window at every kept frontier; GLM-5.3-Flash keeps its
attention history once per prompt and its linear-attention state per frontier.

## MiMo V2.6 Flash on the pair

MiMo V2.6 Flash is granted by its qualification records (pipeline, run on an
M5 Ultra + M3 Ultra pair), on any pair the planner can place it on, at the
planner's cut and in either order. Each start hashes the 172 GB of weights with the file
cache off, so the hash does not fill the Mac's memory before the memory gate
decides; the gate itself is unchanged. Both Macs keep MiMo's prompt prefixes,
in memory and in the encrypted SSD tier, like the Qwen models. MiMo has no paged
KV on the pair yet, and the pair decodes slower than the M5 Ultra alone. Its
phase split (one Mac decodes alone) is kept off like every hand-off mode.

### After a restart

Each Mac's cluster service runs that Mac's part while the leader has the
cluster serving: when a part ends (a member restarted, a session lost a member)
it starts it again, and the leader's session re-forms once the member is back,
with no question. The leader's service also checks the member every 15 seconds:
a member that missed a start or a stop (asleep, restarting, cable out) is
started or stopped as soon as it answers again. The screen says which Mac
serves the API. A signed release installs the cluster service as a login agent
([always on](cluster-always-on.md)); an ad-hoc development build keeps the
service in the session that ran `darkbloom cluster`, says to run it again after
a restart, and writes why to `~/.darkbloom/cluster-setup/service.log`.

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
- **The cable moved to another Thunderbolt port**: an already configured port
  is reused without another configuration prompt. For a port not yet configured,
  run `darkbloom cluster` and press `f` when offered; macOS asks for administrator
  approval to configure that port. Recovery RDMA enablement and Local Network
  privacy permission remain separate steps.
- **A part keeps ending the same way**: after three identical ends the screen
  says it and offers `d`; both Macs keep trying by themselves.
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

For background serving, install the same signed `Darkbloom.app` on each Mac and
approve Local Network access on each when macOS asks. The setup installs a login
agent associated with that app. After leaving both setup terminals, reopen
`darkbloom cluster` on either Mac and test a response. An ad-hoc development
service can lose outbound access when its originating session closes; use the
signed app instead of extending lease timeouts. See [background service
permissions](cluster-always-on.md#permissions-asked-once).
