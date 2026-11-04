# Two Macs as one provider (guided setup)

> Last updated: 2026-11-04

Two Apple Silicon Macs joined by one Thunderbolt 5 cable serve a model together:
each Mac holds part of its layers, and the pair serves as one provider. Setting
the pair up is done once, from `darkbloom cluster` on each Mac. No SSH, no
Remote Login, no IP address and no network setting is typed anywhere.

## What you need

- Two Macs with Thunderbolt 5 and macOS 26.2 or later, each with Darkbloom
  installed (the same version), and one Thunderbolt 5 cable between them.
- RDMA over Thunderbolt enabled on each Mac. This is Apple's own switch and only
  an administrator can turn it on, once. On macOS 27 or later it is in System
  Settings, Privacy & Security: turn on RDMA over Thunderbolt, then restart when
  macOS asks. On macOS 26 it is turned on only in macOS Recovery: start the Mac
  in Recovery, open Terminal, run `rdma_ctl enable`, restart. `darkbloom cluster`
  says whether it is needed, with the steps for the Mac's macOS.
- Nothing to download by hand. The cluster keeps its models in its own store
  beside the product's model cache (`darkbloom-cluster-models`, same volume).
  Models single-Mac Darkbloom already installed are cloned in (APFS clones, no
  new disk blocks). A model only one Mac has is copied to the other Mac over the
  cable; a catalog model neither Mac has is downloaded once on the leader, then
  copied ([Models](#models) below).

## The steps, once

Run `darkbloom cluster` on each Mac, pick a model, done. The Mac you start on
leads the cluster and keeps leading: it chooses the model, sends the other Mac
its setup over the cable and starts it, and it holds rank 0, where requests
enter and which the coordinator registers (and pays) for the pair. Every plan
puts rank 0 on it, whichever Mac makes the plan, including the plans the
cluster service makes by itself after an update or after a Mac's memory
refused its share (`LiveContext.plan`, `ClusterControlDerivation.planLeader`).
Before a plan exists the cluster's
leader is derived as that Mac (`ClusterControlDerivation.derive`, `preferred`).
The other Mac follows; you never go back to it (see
[If a Mac goes away](#if-a-mac-goes-away)).

The screen follows four steps: **Connect**, **Pair**, **Model** and
**Start**, one line for each thing that happened. Every choice is a list you
move through with ↑ and ↓ and take with enter, as `darkbloom start` picks
models: the answer to the pairing code, the model, how a missing model gets
onto the Macs and, later, what to do with a running cluster. Where the screen
has no color (`NO_COLOR`, `TERM=dumb`, a pipe), the same list is numbered and
one key answers it: a number, enter for the first line, or a letter only one
line starts with (`y` for "Yes"). q or Esc cancels any list, so q never
picks a line such as "Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline". While the setup waits (for the other Mac,
for Allow), q or Esc stops it and an arrow key does nothing; no prompt asks for
a key to do something. The model list shows only models
approved for clusters (`ClusterPublicModels.declared`: GLM-5.3-Flash,
Qwen3.8 27B, MiMo-V2.6-Flash and Gemma 4 26B QAT) that these two Macs can serve; any other model is left out, and a
model named on the command line that is not approved is refused.

Each Mac asks for up to two macOS approvals, at stated moments while you are at
that Mac, and Connect's first line says so ("Allow macOS's password and Local
Network prompts."). Each prompt's line says what to click:

- **Connect:** the cable's port, once per Mac (your password). macOS lets a
  command run from a terminal or over SSH onto the local network by itself
  (Apple's TN3179), so this command's own probe, one datagram on the cable
  (`ClusterLocalNetworkAccess.probe`), asks nothing unless macOS blocks it
  anyway; macOS then names the terminal app (Terminal, iTerm, …), or
  `sshd-keygen-wrapper` over SSH, and the setup waits for Allow.
- **Right after pairing:** Local Network access for Darkbloom, which this Mac's
  cluster service (a launchd agent, which macOS does ask about) asks for as it
  starts (`ClusterLocalNetworkAccess.startServiceProbe`). Pairing ends on both
  Macs at once, so both ask at the same moment: "Click Allow on the Local
  Network prompt for Darkbloom. Allow it on the other Mac too." The setup
  waits until Allow ("✓ Allowed"), however long you
  take at the other Mac, or until q; after 15 s it also names the switch in
  System Settings → Privacy & Security → Local Network. A cluster service that
  reports no probe within 10 s (an older build) gets the line as an "if", and
  the setup goes on.

When macOS cannot show its password window (an SSH session with no desktop),
the setup runs the same commands with `sudo` in that terminal ("Type this Mac's
password to set up the cable port."): you type this Mac's password into sudo,
not into Darkbloom, and the setup goes on; if sudo fails, it says "Cable port
not set up. Run `darkbloom cluster` again." Over SSH, Darkbloom's Local
Network prompt still appears on the Mac's own screen, and its line says so
("on this Mac's screen (Screen Sharing if headless)").

The Mac that joins stays open once paired ("✓ Paired. The other Mac leads.") and
follows the start from the cluster's status the two Macs exchange over the cable
(`ClusterOnboardingDriver.followStart`):

1. It says "Waiting for the other Mac (<its hardware name>) to choose the model
   and start…" while the leader's person chooses (started with
   `darkbloom cluster local`, it first says "Run `darkbloom cluster local` on the
   other Mac: it leads.").
2. Once the leader starts, its live line follows the start (loading, offered to
   Darkbloom, then one row per Mac while Darkbloom pairs them). Serving through
   Darkbloom, the leader's start asks Darkbloom whether to offer the pair after
   its test; until it has, the leader's status says so ("checking with Darkbloom
   before it offers the pair") and this Mac keeps following. Offered, it says
   "Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to accept
   this pair…" and waits as the leader does, so both screens end the same way.
3. It ends with the same ✓ or ✗ block as the leader's screen. After ✓: "You can
   close this window." After ✗: the reason, then "Choose Retry on the other Mac
   (…): its screen shows the choices."

q leaves at any time: "The pair keeps going; run `darkbloom cluster` here to see
it." The follow is bounded like the leader's start (15 minutes for the start to
begin, then 15 minutes for its outcome), and its end always says why. A signed
Darkbloom.app's login agent keeps serving; without one, as for a development
build, the screen ends "Keep this window open." and the Mac serves only while
the window stays open. The Start step opens with "Loading
takes a few minutes for a large model; both Macs show progress here." On a color
terminal the live rows then give the wait and one row per Mac (for a pair
registered with the coordinator: registering, registered, loading its share),
each with the time since loading began; no bar or percent, since no load
fraction is reported. The leader ends with the outcome as its own block, between
two rules, then the pair's card, as `darkbloom start` ends, and the shell:

```
────────────────────────────────────────────────
✓ Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)
  API at http://localhost:8000 on this Mac
  Test response in 0.61 s
────────────────────────────────────────────────
  Model:   Qwen3.8-27B-4bit-mtp · pipeline (Apple M3 Ultra 32 layers / Apple M5 Max 32 layers)
  Macs:    This Mac leads · the other Mac (Apple M5 Max, 128 GB) follows
  Serves:  through Darkbloom
  Logs:    ~/.darkbloom/cluster-setup/service.log
  Starts by itself at login on both Macs.

  darkbloom stop     Stop both Macs
  darkbloom restart  Restart with the current model
  darkbloom status   Check status
```

A pair served on the local API only says `Local:   http://localhost:8000`
instead of `Serves:`. With a build whose cluster service lives only as long as
its window, the card says to keep both windows open instead of the login line.

Served on the local API only (asked for, or a coordinator without cluster
support), the block says `✓ Serving <model> on this Mac's local API only`. It
says Serving only once both Macs loaded the model and a request answered.
`darkbloom cluster` on the Mac that joined shows the same outcome block once the
cluster has one.

Serving through Darkbloom needs both Macs logged in (`darkbloom login`): the
coordinator pairs only logged-in Macs. Before the Start step starts anything,
the leader names each Mac without a login ("This Mac and the other Mac (…)
aren't logged in to Darkbloom, so the coordinator won't pair them.") and offers
**Log in on this Mac** (or **Check again** after `darkbloom login` on the other
Mac), **Serve locally only** or **Cancel**.

A start that does not come to serve shows `✗ Not serving: <reason>.` as the
block, with the next step under it ("The other Mac (…) isn't verified by Apple
yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until
then.", "… lacks free memory for its share", "A part keeps ending the same way:
…"; the time is that Mac's local App Attest key-generation safeguard,
"within minutes" when it is unknown), and stays open with **Retry**, **Change
model**, **Serve locally only** and **Diagnostics** (a redacted file in the home
folder). q leaves with "Not serving yet. Both Macs keep trying by themselves;
run `darkbloom cluster` to check." and exit status 1, never Done.

On a color terminal with a UTF-8 locale and at least 40 columns, setup opens
with the Darkbloom mark, which blooms in pixel by pixel. Each step's heading
carries a step meter (`●●○○`). Long work (checking the cable, reading both Macs,
planning, loading the model, waiting for the first tokens) shows a live line
with a turning petal; the next line of the transcript replaces it.
`DARKBLOOM_NO_ANIMATION=1` or `CI` keeps the mark and meter but stops the motion.
The mark needs room for its widest row (57 columns); a window from 40 columns
up keeps the meter and live lines without it, and a live line is cut to one row
so the next line erases all of it. A window under 40 columns or a non-UTF-8
locale (an SSH session in a split pane, say) keeps colored headings only. `NO_COLOR`, `TERM=dumb` and redirected output print
the plain transcript, byte for byte. Nothing clears the screen, so trust codes and
recovery steps stay in scrollback, and no credential is printed: the API key line
names `darkbloom local`, which shows it.

Setup reports completion only after the test response succeeds. If that request
fails, the saved setup remains available: run `darkbloom cluster` on the leader
and choose the model it serves (preselected, so Enter): it sends one test request
and shows the result.

After setup, `darkbloom cluster` works like `darkbloom start`; on a paired Mac,
`darkbloom start` opens the same screen, and `darkbloom stop`, `restart` and
`status` act on both Macs. It opens with both Macs and the cable ("This Mac
(Studio A) leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable
ready"; the other Mac by its hardware name, since no computer name crosses the
cable), then the pair's status: the outcome block (`✓ Serving …` or `✗ Not
serving: <reason>`), or "Stopped; last model …".

On the leader, the pair's model list follows, like `darkbloom start`'s picker:

- The model serving now is marked "serving now" (with the mode it serves in when
  the list shows another), or "last used" when the status above says the pair
  isn't serving, and is preselected. Enter on the model the pair serves sends one
  test request; in another mode it asks first ("Switch Gemma 4 26B from tensor
  parallel to pipeline? It stops serving on both Macs while it loads again …").
  A stopped pair's last model starts again in the mode it served in.
- Each model shows its size, where it is (copied or downloaded first), and its
  modes with the decode speed this pair served it at (`ClusterServedModes`: at
  least 3 served requests on these Macs with this build), or "not measured on
  these Macs yet". Models these Macs cannot serve are not listed.
- Under the models, **Switch to local only** (or **Switch to serving through
  Darkbloom**) serves the current model the other way; serving through Darkbloom
  checks both Macs' logins first, before the local API stops. **Start over
  (unpair and set up again)** asks once ([pairing again](#pairing-again)).
- q or Esc changes nothing; the screen shows the status again and the commands.

A model that runs more than one way here asks how both Macs split it: the model
serving now keeps its mode by default, any other offers the fastest measured mode
first (else the planner's), the other one keypress away:

- **Tensor parallel**: both Macs work on every layer, each holding a share of it
  (half each through Darkbloom; local serving balances the shares by speed).
- **Pipeline**: each Mac runs its share of the layers, uneven on mixed Macs
  (for example "this Mac 6 layers / the other Mac 46 layers").
- **Speculative pipeline** (MiMo): a pipeline that drafts several tokens and
  checks them together.

A mode is offered only if it keeps every feature of the model: Qwen 3.8 27B
offers tensor parallel only, because pipeline would drop its image, video and
logprob support. Change the mode on the leading Mac: a model chosen on the
following Mac is passed to the leading Mac without its mode, so it starts in
the planner's mode.

Choosing the model that serves, in its mode, sends one test request, the same as
a start's, and changes nothing else: "Already serving Qwen 3.8 27B; test response
in 0.61 s" in the ✓ block, then the card; a failed test shows the ✗ block with
**Retry**, **Change model**, **Serve locally only** and **Diagnostics**. A pair
served only through Darkbloom has no local API on this Mac to send a test from;
the screen says so ("Already serving Qwen 3.8 27B through Darkbloom; this Mac has
no local API to send a test from.") and shows the pair's status as both Macs
report it. Choosing another while one serves asks once ("Switch to
Gemma 4 26B? Qwen 3.8 27B stops serving on both Macs while Gemma 4 26B loads …",
**No** by default), then says "✓ Stopped Qwen 3.8 27B on both Macs" and shows
each Mac's load. The steps are headed **Model** and **Start**; the numbered "1/4
… 4/4" steps are the first setup's only. Every start ends with the outcome block
and the pair's card ([above](#the-steps-once)), then returns to the shell; a pair
that does not serve ends with the ✗ block and **Retry**, **Change model**,
**Serve locally only** and **Diagnostics** instead. To stop, run `darkbloom
stop`: both Macs stop and free their memory. The start's own test request is
the test.

**Set up the cable port** comes first when the cable moved to a port not set
up yet ([below](#when-something-is-in-the-way)).

Switching how a serving pair serves says what it does ("Switching to serving
through Darkbloom: the leading Mac's part starts again that way."), never the
result: the outcome block follows once the pair serves, or why it doesn't. A
part that stops serving says why in its log ("Distributed serving stops: …",
for example "the coordinator reported this member's runtime as outdated");
the ✗ block and the diagnostics file give that reason, not the cancellation
that ends the part.

On the other Mac the opening says it follows, the status block, "This Mac runs
its part by itself.", then "To change the model, run `darkbloom cluster` or
`darkbloom start` on the other Mac (<its hardware name>). `darkbloom stop` here
stops both Macs." Enter closes; **Start over (unpair and set up again)** is the
other choice, and asks once ("Unpair this Mac and pair the two Macs again?",
**No** by default). Either Mac first asks the other over the cable. When it
does not answer, the screen names that Mac, its likely reasons (its cluster
service is off, or it is asleep, off, or waiting for someone to log in) and what
to run on it (`darkbloom start` or `darkbloom cluster`), and offers **Try
again**, **Start over** (with its question) or **Quit**. Only a saved pairing
made with another Secure Enclave key offers **Pair again** without the question.

A fresh setup opens with what it will ask (this Mac's password on each Mac for
the cable port, Local Network access, Yes when both screens show the same code,
and a Darkbloom login to serve through Darkbloom) and how long it takes (about
2 minutes to connect and pair, a model copy or download depending on its size,
a few minutes to load).

The planner picks tensor parallel or pipeline for your Macs by itself. Phase
split is off. A model whose artifact ships a speculative (MTP) head can also
decode as speculative rounds across the pipeline, and does by default where its
own cross-cable qualification records passed and measured the rounds faster
than the plain pipeline of the same placement (this build: Qwen3.8 27B, Qwen3.5
9B and MiMo V2.6 Flash). The plan (`darkbloom cluster plan`) then names the mode
"pipeline with speculative decoding". A draft is kept only when it is the model's own choice at that
position, as the verify window computes it; the window's arithmetic differs in
its last bits from one-token decode, so, as with the pipeline itself, output
matches a single Mac's up to near ties. Your pair's own measured speed-up
replaces the records' figure in the choice once the pair has served the same
placement both with and without the rounds. GLM-5.3-Flash in tensor parallel
always decodes with its own NextN (MTP) head, at depth 2; `darkbloom cluster
status` and the pair's `/metrics` report MTP on from the start. Speeds the
pair served count only for the Darkbloom build that served them: after an
update, speeds an earlier build served no longer steer the plan (`darkbloom
cluster plan` says how many records it left out). A request that answers fewer
than 64 tokens (the setup's test answer, a quick "Say hi") is not counted as a
speed and does not shape the plan.

Qwen3.8 27B in tensor parallel can also decode with the speculative assistant
its artifact ships, but only on a cluster that serves locally only. The
assistant is not qualified for public traffic, and a setup registered with the
coordinator never carries it. So, with the default `[backend] mtp_mode` of
`auto`:

| You run | Qwen3.8 27B decodes | One request on two M5 Ultras (2026-10-31) | The coordinator |
|---|---|---|---|
| `darkbloom cluster` | without the assistant | about 40 tokens/s | the pair registers when the coordinator serves a matching approval |
| [`darkbloom cluster local`](#serving-locally-only) | with the assistant | about 93 tokens/s | never contacted |

With `mtp_mode = "on"`, `darkbloom cluster` keeps the assistant too. That pair
is then not offered to the coordinator: its plan says "not offered for public
traffic", and it serves on the leader's local API. A serving cluster switched
with **Switch to local only** or **Switch to serving through Darkbloom** keeps the setup it
has; to plan the model again for the new way of serving, stop the pair (`darkbloom stop`) and start it again from the list. Public speculative decoding for Qwen pairs needs
qualification evidence of its own, which no record holds yet. Rules:
[Qwen27 TP assistant policy](../reference/configuration.md#qwen27-tp-assistant-policy).

A JSON `response_format` request that a single Mac would answer under a grammar
(no tools or `tool_choice`, no media, a schema the grammar covers) is refused on
a Qwen pair before any output: a pair's ranks cannot apply the grammar
(`constrained_decoding_unsupported`, HTTP 400). The coordinator moves a public
request refused this way to a single Mac, which constrains it
(darkbloom-platform `fix/coord-pair-refusal-failover`); a request to the owner's
local cluster API gets the refusal. Other JSON requests are served with the
format instruction only, as on one Mac
([constrained Qwen JSON answers](../architecture/inference.md#constrained-qwen-json-answers)).

| # | Where | What you do | What it asks |
|---|---|---|---|
| 1 | the first Mac | Run `darkbloom cluster`. Its first line is "Allow macOS's password and Local Network prompts." It checks the Thunderbolt cable ("✓ Cable ready") and Local Network access. Nobody waits on the cable yet, so this Mac leads; its last line is **"Run `darkbloom cluster` on the other Mac."**, and it waits (q cancels). With two cables it asks "Which cable goes to the other Mac?" | the cable's port, once (your password; sudo in this terminal where macOS shows no window); Local Network access for the terminal app only where macOS blocks it |
| 2 | the other Mac | Run `darkbloom cluster`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code ("Code 123 456. Same on the other Mac?"); a Mac that answered first says "Now confirm on the other Mac." | the same as the first Mac; **Yes** on each Mac when the codes match |
| 3 | both Macs | Each says it is paired ("✓ Paired. This Mac leads." on the leader, "✓ Paired. The other Mac leads." on the other Mac). Both cluster services now run, and macOS asks on both Macs at the same moment to let Darkbloom find devices on your local network: click Allow on each; each screen waits for its own ("✓ Allowed"). Nothing else is ever asked on the other Mac; it says "Waiting for the other Mac (…) to choose the model and start…" and follows the start to the same ✓/✗ block. | Local Network access for Darkbloom, once on each Mac |
| 4 | the leader | It lists every model approved for clusters that the pair can serve (held by both Macs, by one of them, or in Darkbloom's catalog), one line each with its size and how the planner splits it, "tensor parallel" or "pipeline" ("Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline"), ending "copy" or "download" when the model must reach a Mac first (a model no Mac holds yet is split once it arrives, so its line has no split). A model a Mac holds twice (a catalog download beside the cluster's own copy) is listed once. The planner records why a model that has tensor parallel is split otherwise (for example "tensor parallel: slower here", "tensor parallel: not measured yet" or "tensor parallel: link unmeasured"); `darkbloom cluster plan` gives the full reason under "Tensor parallel or pipeline". Models that fit in the Macs' free memory now come first; one that does not ends with "does not fit now". A model a Mac has no room for on disk now comes last, ending "not enough free disk" ([Free disk](#free-disk)). Choose the model with ↑↓ and enter (enter takes the first). If the other Mac does not answer over the cable (its Darkbloom prompt may still wait for Allow), it offers **Try again** or **Cancel**. | the copy first in a list; a short one says its time ("Copy to the other Mac (about 7 s)") |
| 5 | — | Choosing is starting: the leader saves the setup, sends it to the other Mac over the cable and starts both Macs; once both are loaded it says where and how the pair serves ("✓ Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 (earning through Darkbloom)", or "(local only)") and answers one test request ("✓ Test response in 0.61 s"). | nothing |

When it serves, the screen says where in one line, for example:

```
✓ Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 (earning through Darkbloom)
```

Every screen names the Macs from where it is shown: "this Mac" is the Mac the
screen is on and "the other Mac" the other one. A line that must tell them
apart adds the hardware name pairing showed ("the other Mac (Apple M3 Ultra,
256 GB)"), never its host or computer name; only this Mac's own screen names it
as System Settings does ("This Mac (Studio A) leads"). A Mac that does not lead
shows the leader's answers in the same words for its own screen.

When the coordinator in your provider configuration cannot take a cluster
member yet (it is unreachable, or it has no cluster support), the pair still
serves, on the leader's local API only, with the same local token as
`darkbloom start --local`, and its serving line ends "(local only)" instead of
"(earning through Darkbloom)". The leader's part logs why:

```
Notice: Serving locally on this Mac's API; public serving needs a coordinator with cluster support
```

Nothing to do: the next start registers with the coordinator once it supports
clusters. A coordinator that refuses this pair is not treated this way; the
start fails and says why. To serve without any coordinator, use
[`darkbloom cluster local`](#serving-locally-only).

## Registered with the coordinator as a cluster member

When the coordinator serves a cluster approval for this pair's model, the pair
registers with the coordinator by itself. Nothing is typed and no file is
copied. DevNet's coordinator serves the approvals its operator posts.
Production's derives them from each release's
[cluster runtime facts](../operations/provider-release.md#cluster-runtime-facts),
from 0.10.6 on, once it runs darkbloom-platform#643 with
`EIGENINFERENCE_CLUSTER_PAIR_APPROVALS_FROM_RELEASES=true`; such an approval
names one release's build, so a pair registers with it only on that release.
Before that deploy production serves no approvals (`GET /v1/cluster/approvals`
answers 404), staging serves none, and the pair serves as described above. The
pair serves its owner's own requests, and public requests too once the
coordinator has public cluster routing on and a parity qualification for the
pair's model and split; a release's cluster runtime facts carry them for
GLM-5.3-Flash and Qwen3.8-27B
([serving a pair](../reference/cluster-control-protocol.md#serving-a-pair)).
A tensor-parallel pair registers like a pipeline one; its plan names no cut.
A Gemma 4 pipeline pair whose plan prefills serially takes several requests at
once; one planned with the one-chunk lookahead takes one at a time
([Gemma pipeline lanes](../architecture/inference.md#gemma-pipeline-lanes)).

1. Run `darkbloom cluster` and choose a model, as in [the steps](#the-steps-once).
   After the Test stage passes, the leader reads the approvals the coordinator
   serves (`GET /v1/cluster/approvals`) and takes the one whose model and
   prefill schedule match this pair's setup. A build-pinned approval must also
   match the installed app's digests. A model approval names no build and must
   match only the model's artifact, so it stays valid after an update
   ([model approvals](../reference/configuration.md#model-approvals)). Each
   Mac checks it against its own files, and both Macs save it, or neither
   does. Both Macs then start their parts again as cluster members.
2. Read the end of the setup screen. Once the test request answers, it says:

   ```
   Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to accept this pair…
   Starting both Macs' parts again as cluster members…
   ```

   The Mac that joined says the same first line. The logs keep the registration
   line with the approval's id and end (`ClusterApprovalLifetime.offeredLine`).
   Offered is not serving: the coordinator still has to pair both Macs, and
   both then load their share. The leader waits for that (at most 15 minutes,
   its progress in the live rows) and says `✓ Serving <model> through
   Darkbloom on both Macs (<split>)` only once the plan's rank 0 reports that both ranks
   loaded the model and the pair answered its first request (the warm-up). A
   reason the Macs know ends the wait sooner (a missing login at once, others
   once the wait has run 90 s), with the choices [above](#the-steps-once). There
   is no local API in this mode.

An approval ends at its `not_after`, which the operator sets; one derived from
a release ends 90 days after that release registered
([`releaseApprovalExpiry`](https://github.com/Layr-Labs/darkbloom-platform/blob/df61dd6f93714b4458d0eef3125c377087c08b52/coordinator/registry/cluster_release_approvals.go)). The
leader asks again at each start of its cluster service, after each Darkbloom
update and every minute while the pair is registered, and takes a later
matching approval when the saved one ends within a day. A Mac whose approval
ended saves its setup without it before its part starts, and the pair serves on
the leader's local API again. `darkbloom cluster local` never asks the
coordinator and serves without the approval.

The pair also serves on the leader's local API, both Macs without the
approval, when the coordinator gives no answer for the absence grace (10
minutes, the same grace as in [if a Mac goes away](#if-a-mac-goes-away)), when
it no longer lists the approval, or when the coordinator-paired parts end three
times in a row right after starting. An end the coordinator decides is not
counted: one because it could not be reached, or because it did not accept the
part's registration in time, as during a coordinator deploy. This complements
the coordinator's side: a coordinator that ends each pair session before its
shutdown closes the members' connections gives a deploy cleaner ends, and this
rule still covers a coordinator without that change, a coordinator crash and a
slow registration. When the coordinator lists a matching approval again, the
pair registers again (after repeated failures, with the same approval an hour
later, or at once with a later one). Both Macs carry the same approval, or
neither does: the leader compares the two at every check.

What `darkbloom cluster` status says in each mode:

| Mode | Status line |
|---|---|
| Registered, paired and loaded | `Serving <model> through Darkbloom on both Macs (<split>).` |
| Registered, not serving yet | `<model> is not serving yet: <reason or progress>.`, then what to do (a missing login, App Attest, memory) |
| Coordinator gave no answer for the grace | The serving line, then `The coordinator has not answered for 10 minutes: the pair serves on the leader's local API until it answers again, then it is offered again with approval <id>.` |
| Approval no longer listed | The serving line, then `The coordinator no longer lists cluster approval <id>: the pair serves on the leader's local API until it lists a matching one again.` |
| Parts kept ending | The serving line, then `The coordinator-paired parts ended 3 times in a row right after starting with cluster approval <id>: the pair serves on the leader's local API for 60 minutes, then it is offered again with it, or sooner with a later one the coordinator lists.` |
| Approval ended | The serving line, then one line that says the cluster approval `<id>` expired and the pair serves on the leader's local API |
| No approval (staging, production before its coordinator derives approvals from releases, no matching entry) | The serving line, then (only after a refusal) `Not offered for pairing: <reason>.` |

Approval sources, checks and saved fields:
[coordinator-paired member](../reference/configuration.md#coordinator-paired-member).

Counting every key: enter for **Yes** on each Mac and enter for the first
model on the leader (three keys), plus the macOS prompts [above](#the-steps-once).

Running `darkbloom cluster` again on either Mac opens with the same Darkbloom
mark, beside "Darkbloom cluster" and the part each Mac plays and the cable
("This Mac leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable
ready"; with the name System Settings gives this Mac, "This Mac (Studio A)
leads · …", so two identical Macs each say which they are), then shows the
cluster's state as the outcome block ("✓ Serving Qwen3.8-27B-4bit-mtp at
http://localhost:8000 (earning through Darkbloom)", or "Stopped; last model …")
and, on the leader, the pair's model list [above](#the-steps-once). The other
Mac then says its part runs by itself, names the Mac it follows and the command
to run there; Enter closes it, and **Start over (unpair and set up again)** is
the other choice. When the cable moved to a port not set up yet, it offers to
set that up first ([below](#when-something-is-in-the-way)).

If both Macs start waiting at the same moment, the pairing's own rule picks one
to keep waiting (it leads) and the other joins it ("✓ Paired. The other Mac
leads.").

## Serving locally only

`darkbloom cluster local` serves the pair for you alone: the same steps, model
choice, planner, copies, speculative decoding, caches, failover and stop as
`darkbloom cluster`, but no Mac of the cluster contacts a coordinator. Nothing
registers, sends heartbeats, takes public traffic or bills, and serving needs
no network beyond the cable. It is also where Qwen3.8 27B in tensor parallel
decodes with its speculative assistant under the default `mtp_mode`
([above](#the-steps-once)).

1. On the leader, run:

   ```bash
   darkbloom cluster local
   ```

   Not paired yet, it pairs first as in [the steps](#the-steps-once). Name a
   model to skip the list: `darkbloom cluster local glm-5.3-flash` (its id or the
   name the list shows). On a cluster that already serves, it switches the
   cluster to local only and waits until it serves again. On the Mac that joins
   a waiting leader, it pairs like `darkbloom cluster`, says to continue on the
   leader with `darkbloom cluster local`, and then follows the start there.
2. Read the API's place from the ready screen:

   ```
   ✓ Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 and on the network (local only)
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
again, until you switch back. In `darkbloom cluster` on the leader, the list's
**Switch to serving through Darkbloom** serves through Darkbloom again and
**Switch to local only** serves locally only; on a serving cluster the leading
Mac's part restarts that way and the screen waits for it as after a start: a
test request on the leader's API, or, for a pair registered with the coordinator,
until the coordinator paired both Macs and both loaded the model. It ends with
the same outcome block (✓ only then; otherwise ✗ with the reason and the
choices). The model list still
reads Darkbloom's catalog when the network is up (to download a model neither
Mac has); with no network, it lists the models already on the Macs. Only
catalog models are served. Qualification records never gate local-only
serving.

If startup reports that both ranks need the same keyed native worker, install
one Darkbloom build on both Macs and retry. Paired-link startup refuses a
plaintext fallback; see the [cluster encryption contract](../architecture/security/encryption.md#two-mac-cluster-experimental).

## Models

- **Clone in.** Every model the single-Mac product installed and verified
  (`darkbloom models download`, its manifest receipt) is cloned into the cluster
  store with APFS clones, so it costs no disk space. Beside the files it writes
  the model CDN's exact `manifest.json` bytes, which the cluster worker pins
  ([registered manifest pins](../architecture/inference.md#registered-manifest-pins)).
- **Copy over the cable.** A model one Mac lacks is sent by the Mac that has it
  over the link control channel: keyed by the pairing (S17), encrypted and
  authenticated records, 4 MiB chunks acknowledged only after the receiver wrote
  and hashed them. The receiving Mac's cluster service accepts only a manifest
  whose aggregate digest this build's qualification records pin (a pair serves
  nothing they do not grant), refuses hard links, an occupied destination and too
  little free disk (see [Free disk](#free-disk)), writes uncached, hashes every file as it arrives, has its own
  installed worker check the staged configuration and manifest, and only then
  renames the folder into place. An interrupted copy resumes from the staged
  bytes; the leader's screen shows the rate and time left.
- **Download.** A catalog model neither Mac has is downloaded on the leader
  through the product's downloader (catalog manifest, per-file and aggregate
  SHA-256, written uncached), cloned into the cluster store and then copied.

### Free disk

A download or copy starts only when every Mac that receives the model has its
size free on disk now, plus 2.1 GB kept free
(`ClusterModelProvisioning.reserveBytes`). Space macOS could free later is not
counted: Time Machine local snapshots, files iCloud keeps elsewhere and caches.
Finder's "available" figure can include that space, so it can be much larger. On an
M3 Ultra it read 256.6 GB with 54.1 GB free. How the figures are read:
[two-Mac cluster stages](../architecture/inference.md#two-mac-cluster-stages-experimental).

- **The list:** a model a Mac has no room for comes last, ending "not enough
  free disk".
- **Choosing it:** nothing is downloaded or copied. The screen says why, for
  example: "Can't start Xiaomi: MiMo-V2.6-Flash: this Mac has 54.1 GB free; the
  model needs 172.9 GB and 2.1 GB to spare. macOS could free up to 202.5 GB more
  (purgeable files such as local snapshots), but Darkbloom doesn't count on it.
  Free space, then run `darkbloom cluster` again." The sentence about what macOS
  could free appears only when that space would make room.
- **What to do:** free space on that Mac (`tmutil listlocalsnapshots /` lists
  the local snapshots), then run `darkbloom cluster` again.
- **During a copy:** the receiving Mac reads its free disk again as the bytes
  arrive. If something else fills the disk, the copy stops and keeps what it
  staged for the resume.

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
to pipeline when eligible and fitting, without requesting a link measurement.
Where tensor parallel fits both Macs' memory as they are now, it is chosen,
also on a new pair whose link no load has measured yet. A pipeline is chosen
when only a pipeline fits now, and stays until the pair is planned again (another
model chosen in `darkbloom cluster`'s list, or after a Darkbloom update). Changing the model of a
serving cluster (another model in the list, or `darkbloom cluster local <model>`) plans again once both
Macs have stopped their parts and given back their memory, so the memory the
running model held does not turn tensor parallel into a pipeline. Every load records the
encrypted link's cost for later predictions; plans use the median of the
pair's last eight measurements from the last 30 days. GLM-5.3-Flash on two M5
Ultra 256 GB runs tensor parallel on equal shares with eight concurrent
requests; the plan counts its NextN (MTP) layer on both Macs and its
speculative decoding ([GLM tensor parallel](../architecture/inference.md#exact-quote-placement)).
GLM-5.3-Flash has both a pipeline and a tensor-parallel adapter; its private
image candidate is pipeline-only.

Models that run tensor parallel, and when:

| Model | Tensor parallel chosen | Notes |
|---|---|---|
| Qwen3.5 9B, Qwen3.8 27B, Qwen3.5/3.6 35B A3B | wherever it fits | Qwen3.8 27B keeps images, video and logprobs only in tensor parallel |
| GLM-5.3-Flash | wherever it fits | Eight concurrent requests by default |
| Gemma 4 26B (QAT 4-bit, 8-bit) | only where the plan predicts it faster from its own measured speed on both Macs (it keeps every feature of the pipeline, prompt-prefix and SSD reuse included) | Text only; logprobs in tensor parallel only; one request at a time unless you set `DARKBLOOM_CLUSTER_BATCH_LANES` |
| MiMo V2.6 Flash | only where it keeps every feature of the mode it would replace (it keeps the speculative pipeline's rounds, not the plain pipeline's batch lanes) and the plan predicts it faster from its own measured speed on both Macs | Text only; speculative decoding; logprobs in tensor parallel only; one request at a time; see [MiMo V2.6 Flash on the pair](#mimo-v26-flash-on-the-pair) |

For Gemma 4 and MiMo V2.6 Flash, tensor parallel must first keep every feature
and caching behavior of the mode it would replace, as the installed cluster
worker declares them: prompt-prefix and SSD cache reuse, speculative rounds,
batch lanes, media, penalties and logit bias, stop handling and logprobs. What it
adds, such as logprobs where the pipeline has none, never counts against it.
Gemma 4's tensor parallel keeps every feature of its pipeline, prompt-prefix
and SSD reuse included, so speed decides there (below). MiMo's tensor parallel decodes in speculative rounds and keeps every
feature of the speculative pipeline, so speed decides there (below); it is held
back only where the plain pipeline, with its batch lanes, is the mode it would
replace. Where tensor parallel is held back:

- The plan's "Tensor parallel or pipeline" line says what tensor parallel would
  drop ("Pipeline: tensor parallel would drop batch lanes up to 8 (it serves 1)
  that the pipeline keeps; held back until it keeps them."), and the model list
  says "tensor parallel: drops a feature".
- Where only tensor parallel fits the two Macs, the plan refuses and saves no
  setup ("Only tensor parallel fits these Macs, and it would drop ... No
  reduced-feature setup was saved.").
- The developer's forced mode (`DARKBLOOM_CLUSTER_FORCE_MODE`, debug builds only)
  still places tensor parallel, and the plan says exactly what it drops.

See [feature parity before tensor parallel](../architecture/inference.md#gemma-tensor-parallel-placement).

Where tensor parallel keeps every feature, the plan also uses it only when
tensor parallel's own speed has been measured on both Macs. That measurement
is a timing a tensor-parallel load takes of each Mac's half (Gemma), or requests
this Darkbloom build served in tensor parallel. An estimate from each Mac's
device index alone never chooses it: the index overstates how much a half saves
on big Macs. Until then the pair serves the pipeline, as follows:

- Before a load has measured the link, the plan prices tensor parallel on a
  slow assumed link, so two big Macs keep the pipeline.
- Where the estimate says tensor parallel would be faster, the plan's "Tensor
  parallel or pipeline" line says so and keeps the pipeline ("Pipeline: tensor
  parallel is predicted 6% faster ..., but from the device index, not its own
  measured step; it can be chosen once its step is measured on both Macs ..."). The
  model list then says "tensor parallel: not measured yet". This holds for short
  prompts with longer answers on two M5 Ultra once the link is measured, and on
  smaller Macs whose decode is limited by memory bandwidth (for example two 24
  or 32 GB M4 Pro).
- Once both Macs' speeds in tensor parallel are measured, the plan compares
  those, and a tensor-parallel choice ends with "on its own step as measured on
  both Macs".

A normal setup does not load tensor parallel just to measure it, so pairs keep
the pipeline for these models today
([evidence before tensor parallel](../architecture/inference.md#gemma-tensor-parallel-placement)).
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

A model or mode with no passing record is served for you, and the plan says in
one line: "not yet qualified for public traffic".

Time budgets (startup, first token, stop) are derived from the setup and the
installed artifact, not from a per-model table:

- The first-token allowance reaches the setup's request deadline at the
  longest prompt. The planner derived that deadline from the chosen placement's
  predicted speed on your Macs: three times the prediction, plus 30 s.
- The startup allowance comes from the artifact's size, at load rates below the
  slowest any Mac has recorded.

### Response length

Cluster workers accept up to 32,768 output tokens and 32,768 prompt tokens,
within a 65,536-token combined ceiling, except for a model served at its native
context (Qwen3.8 27B in tensor parallel, below). Each model's declared context and both
ranks' live memory admission may reduce that budget. Omitting `max_tokens` on the local endpoint uses the full
allowance, clamped to the model and remaining context; an explicit
`max_tokens: 32768` requests the same allowance. A model can finish earlier
at its stop token. Requests above the output ceiling receive HTTP 400 `output_too_long`;
requests that exceed the admitted combined context are refused before generation.
Qwen3.8 27B on a tensor-parallel pair accepts its native context, as a single
Mac serving it does: prompts up to 262,143 tokens and up to 32,768 output tokens,
within 262,144 combined. The pair is still loaded and planned for the
32,768 + 32,768-token request, at any number of lanes. A longer request is
admitted on its own when both Macs' memory holds it at that moment. If it does
not fit, it alone receives HTTP 503 with the context the pair serves now, and
other requests keep running. The 27B's pipeline modes keep the 65,536-token
ceiling. See
[native context](../architecture/inference.md#qwen27-tensor-parallel-native-context).

After updating, let the normal cluster setup refresh both worker capabilities
and the derived request deadline before serving. For adapters such as GLM that
reserve their whole request scope at load time, automatic placement prices that
full memory budget even when recent chat requests are short. Request history
still guides the speed estimate and choice of split.

### Images and video

A pair takes image and video input only where its placed mode serves it:
GLM-5.3-Flash and Qwen3.8 27B in tensor parallel. In every other mode (any
pipeline, other models) it registers with the coordinator as text only, so no
media request is routed to it, and a pair registered for media serves only
while both Macs' parts report media. GLM-5.3-Flash answers its output
controls as one Mac does: hidden reasoning is withheld, with or without media,
and with images or video a `response_format` JSON answer or a required or
named tool call is refused. Content parts of an unknown type are refused,
never answered from the remaining text
([refused request shapes](direct-mode.md#refused-request-shapes)).

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
`darkbloom cluster` on it says so. When the Mac you set up on is back, it leads
again (it holds rank 0). A pair set up with Darkbloom 0.10.6, on which the Mac
that joined took over leading, moves back to the Mac you set up on at its next
plan: normally the re-plan after its update, which restarts both parts anyway.
Manage the cluster on the Mac that leads; on the other
Mac, `darkbloom cluster` shows the status and names the Mac to use.

## How the split is chosen

The split is worked out from each Mac's hardware and measured speed only: what
is cached or running when you plan never moves it. A Mac is given a share only
when two things hold, by the same rule the load-time memory gate uses:

- **Memory with every app closed.** The gate counts free memory and the files
  macOS keeps cached, so a Mac at rest can give a model its memory less what
  macOS itself wires (a sixteenth, at least 4 GiB): 120 GiB of a 128 GB Mac,
  240 GiB of a 256 GB Mac. If a Mac's apps hold memory the chosen share needs,
  or the Mac is under memory pressure (then the gate counts no cached files),
  the screen says "Quit apps on … first" instead of picking a slower split.
- **The GPU memory limit.** What the share keeps on the GPU (weights, request
  memory and the attention workspace) must fit the Mac's GPU wired-memory limit:
  macOS's default (`iogpu.wired_limit_mb=0`) is the GPU's recommended working
  set, 107.52 GiB of a 128 GB M5 Max and 222.72 GiB of a 256 GB M3 Ultra. A
  split whose GPU part is larger is never offered, however much memory is free,
  because its first requests would fail with "Insufficient Memory".

The plan uses the limit each Mac reports: `iogpu.wired_limit_mb` when it is
set, else macOS's default. `darkbloom cluster` does not change it, so a model
whose split needs more GPU memory than these limits is not offered. MiMo V2.6
Flash fits two 128 GB Macs at the default limit in all three modes (per Mac at
most 95.9 GiB on the GPU, tensor parallel, against 107.52 GiB).

When several splits predict the same time (two identical Macs, or Macs with
equal measured speed), the one that leaves each Mac the largest share of its
own memory is chosen: identical Macs split the layers evenly, and a Mac with
more memory takes more. A faster split is never given up for an even one.

Under tensor parallel both Macs run every token, so the slower Mac's share sets
the pace. Each time a dense Qwen model loads in tensor parallel, each Mac times
its own share, alone and with nothing crossing the cable, before the pair is
ready (at most about a second and a half; a Mac short of memory skips it). The
leading Mac keeps those timings per model in
`~/.darkbloom/cluster/share-probes.json` (each Mac's newest timing at each share
for 30 days) and the next plan balances the shares by them, with no step from
you. For example, with the timings an M3 Ultra and an M5 Max measured for
Qwen3.8 27B, a pair first split 2:1 toward the M3 Ultra is planned 1:1 after
one load. A split that gives a Mac more is still chosen only when that Mac's
memory holds its share. Unequal shares are for a pair that serves you alone
(`darkbloom cluster local`): a pair served through Darkbloom is always planned
with equal shares, because its registration with the coordinator cannot name
unequal ones yet. A pair saved with unequal shares is not offered for pairing,
and its status says why; press `m` in `darkbloom cluster` to plan it again.

## Prompt prefixes on the pair

Both Macs keep the prompt prefixes of every model family, in memory and in the
encrypted SSD tier: a repeated long prompt starts with its prefix restored, and
after both Macs restart the SSD tier gives it back. Gemma 4 keeps each
sliding-window layer's window at every kept frontier, in pipeline and in tensor
parallel, where each Mac keeps its own half of every layer's heads and a prefix
is restored only when both Macs hold it, with exactly the tokens of a request
that prefilled the whole prompt; GLM-5.3-Flash in pipeline
keeps its attention history once per prompt and its linear-attention state per
frontier. GLM-5.3-Flash in tensor parallel keeps one boundary per prompt, the
last whole 4,096-token chunk before its final token: each Mac writes its own
share of it to the SSD once the request has finished, and a later prompt is
restored from it only when both Macs hold it, close to a request that
prefilled the whole prompt at the default record precision below, and with
its tokens when records are `native`
([how it works](../architecture/prefix-cache.md#glm-tp-prefix-ssd-tier)).

The SSD tier stores older attention rows compactly at the same checkpoint
precision as a single Mac (`balanced` by default; a Qwen 3.8 27B record's
attention rows take about a third of their exact size), so a prefix restored
from disk (and kept in memory after that restore) is close to, not identical
with, computing it again; prefixes the pair computed and kept in memory are
exact. For exact disk restores, set the same value on both Macs and restart
the cluster:

```toml
[backend]
engine_v2_kv_checkpoint_quantization = "native"
```

Both Macs must resolve the same precision. The leader does not sync it, and
both default to `balanced`; a Mac set differently makes the pair refuse to
load the model (the ranks' load agreement differs), which is the expected
behavior: set the value on both Macs. The
[record encoding](../architecture/inference.md#cluster-ssd-prefix-record-encoding)
lists what each model stores compactly.

Prefixes are kept per tenant, as on one Mac: a request served through Darkbloom
reuses only prefixes that requests with its own cache scope left, on both Macs.
A request without a cache scope from Darkbloom, a request with its prefix cache
off and a GLM or Qwen request with images or video reuse and keep nothing.
Requests to the local endpoint share prefixes with one another only. How the caches are
partitioned: [encryption and privacy](../architecture/security/encryption.md#two-mac-cluster-experimental).

## MiMo V2.6 Flash on the pair

MiMo V2.6 Flash is granted by its qualification records (pipeline, run on an
M5 Ultra + M3 Ultra pair), on any pair the planner can place it on, at the
planner's cut and in either order. Each start hashes the 172 GB of weights with the file
cache off, so the hash does not fill the Mac's memory before the memory gate
decides; the gate itself is unchanged. Both Macs keep MiMo's prompt prefixes,
in memory and in the encrypted SSD tier, like the Qwen models. MiMo has no paged
KV on the pair yet, and the pair decodes slower than the M5 Ultra alone. Its
phase split (one Mac decodes alone) is kept off like every hand-off mode.

MiMo V2.6 Flash text can also run tensor parallel: each Mac holds half of every
layer, about 84 GB of weights, and MiMo's three draft heads whole (about 2 GB),
about 100 GiB in all with its reserves
([rank memory](../architecture/hardware-support.md#mimo-v26-tensor-parallel-rank-memory)),
so two 128 GB Macs that cannot hold MiMo alone can serve it. It decodes with
speculative decoding by default, as the pipeline does, so it keeps the speculative
pipeline's features. Where the plain pipeline is the mode it would replace, its
batch lanes keep the pipeline. Speed decides after that: tensor parallel must be
predicted faster than the speculative pipeline, which MiMo's qualification
records credit 1.37x, from tensor parallel's own speed measured on both Macs. The
plan credits tensor parallel's own rounds nothing until they are measured:

- Before a load has measured the link, two 128 GB Macs and two 256 GB Macs
  alike keep the pipeline.
- After that, on a fast Thunderbolt 5 link, tensor parallel is predicted faster
  for most requests, including a new pair's longest prompt and answer, but only
  from the Macs' device index, so the pipeline is kept. A long prompt with a
  short answer (for example 8,192 + 128 tokens) or a slow link keeps it anyway.
- MiMo does not yet time its halves when it loads tensor parallel. Only
  requests this Darkbloom build served in tensor parallel measure it, so MiMo
  pairs keep the pipeline today.

In tensor parallel MiMo returns logprobs, serves one request at a time and
decodes with speculative decoding (up to two drafted tokens a round); its output
is the same as without drafting. The image candidate stays a pipeline. Speed
on a real pair is not measured yet. No qualification record covers MiMo tensor
parallel yet, so its grant names only the modes above and a tensor-parallel
MiMo pair serves its owner's local endpoint.

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
happens by itself; `darkbloom cluster` says which applies to each Mac.

## Updating Darkbloom on the pair

The Macs of a pair update themselves together, as a single Mac does, while
`auto_update` is on (the default) and `DARKBLOOM_NO_UPDATE_CHECK` is not set on
either Mac. Nothing needs to be run. Every 30 minutes, at the pair's update slot
(a time fixed by the pairing's cluster ID, the same on both Macs), each Mac's
cluster service asks the coordinator for its latest release:

1. Each Mac downloads, verifies and stages the release while the pair serves.
2. Once both Macs have it, the pair stops taking new requests. The Mac that
   serves the pair finishes the requests it accepted, within 120 seconds, and
   never cancels one.
3. Both Macs install the release and restart their cluster services from it.
4. The leader plans the same model again for the new release once both Macs
   answer with it, and the pair registers again under that release's cluster
   approval. The log says `Darkbloom changed on both Macs: setting the cluster
   up again for <model>`.

A pair still running a request after 120 seconds takes requests again and tries
at the next slot. A release that one Mac cannot download or verify is installed
on neither Mac; both try again at the next slot. Until a new
release's cluster service has stayed healthy for 10 minutes, three of its starts
that end by themselves bring back the previous release and quarantine the new
one, as the watchdog does for a single Mac. A Mac never restarts into a new
release that does not start at all (it checks before the restart): it brings
back the previous release at once and quarantines the new one. When one Mac
brings back the previous release this way, or with `darkbloom update
--rollback`, the other Mac brings back the same release and quarantines the new
one too, so the pair serves the previous release together
([a rollback on one Mac](cluster-always-on.md#a-rollback-on-one-mac)). How the
cluster service does this is in
[the pair's coordinated update](cluster-always-on.md#the-pairs-coordinated-update).

To update at once, run on each Mac:

```bash
darkbloom update
```

It installs the release, then asks this Mac's cluster service to restart into it
together with the other Mac, after the pair drained, and prints its progress
(`drained for v<version>; waiting for the other Mac`). Both Macs restart once both
have the release. The Mac where it ran first waits up to 15 minutes, while it
serves, for the other Mac: for its `darkbloom update`, or for its next slot when
its automatic updates are on.
No log-out is needed. A cluster service started by an earlier release cannot do
this: log out and back in on both Macs once both have the release.

While a Mac serves, the re-plan uses the speed it measured while idle and never
runs a GPU benchmark beside the model
([device profile](../architecture/inference.md#automatic-local-cluster-batching)).
A pair that serves on the leader's local API, or a Mac that serves alone, is not
drained for an update yet: its update waits while it serves (the log says
`this Mac's part does not drain for an update`).

## When something is in the way

- **No macOS prompt can be shown** (for example with no one logged in to the desktop):
  the check writes the exact commands the prompt would run to an owner-only
  script, and the setup runs it with `sudo` in the same terminal (type this
  Mac's password into sudo). If that fails, it says "Cable port not set up. Run
  `darkbloom cluster` again."; an administrator can also run the script once,
  `sudo sh ~/.darkbloom/cluster-device/link-fix.sh`, then `darkbloom cluster` again. A port an administrator already isolated this way
  is recognised and recorded (no change, no prompt).
- **Internet Sharing shares to the cluster port itself**: the check says so and
  stops before any prompt. Turn the cluster port off under System Settings →
  General → Sharing → Internet Sharing → “To devices using”, then run
  `darkbloom cluster` again.
- **The cable moved to another Thunderbolt port**: an already configured port
  is reused without another configuration prompt. For a port not yet configured,
  run `darkbloom cluster` and choose **Set up the cable port** when offered; macOS asks for administrator
  approval to configure that port, and the same run goes on to the Mac's usual
  screen. Recovery RDMA enablement and Local Network privacy permission remain
  separate steps.
- **The Macs were paired again** while their cluster services ran
  (`darkbloom cluster` or `darkbloom cluster pair`): each service answers with
  the new pairing within seconds, and its log,
  `~/.darkbloom/cluster-setup/service.log`, says `this Mac's pairing changed`
  ([listeners](../architecture/inference.md#cluster-service-listeners-follow-the-cable-and-the-pairing)).
  If the other Mac still refuses the connection (`refused (handshakeRejected)`),
  restart its service, since one an earlier release started keeps the earlier
  pairing: on that Mac, run `darkbloom cluster stop`, then `darkbloom cluster`.
- **A part keeps ending the same way**: after three identical ends the screen
  says it and offers **Save diagnostics for Darkbloom**; both Macs
  keep trying by themselves.
- **The leader cannot reach the other Mac**: make sure the other Mac is on and
  logged in; it rejoins by itself. During setup the leader offers **Try again**
  and **Cancel**, since the other Mac's Darkbloom prompt may still be waiting
  for Allow. If you denied the Local Network prompt there,
  allow Darkbloom in System Settings → Privacy & Security → Local Network, then
  run `darkbloom cluster` again. When `darkbloom cluster` is run again and the
  other Mac does not answer, it says why that may be and what to run on that Mac,
  and offers **Start over**, which asks first: a Mac that is away is
  not a broken pairing ([pairing again](#pairing-again)).
- **One Mac waits at "2/4 Pair" while the other shows its status and ends, or
  says "The other Mac (…) isn't answering over the cable"**: the second Mac still
  holds an earlier pairing, so it never joins. Run
  `darkbloom cluster` on it, choose **Start over** and answer
  **Yes, start over** ([pairing again](#pairing-again)).
- **A model is not offered**: the list leaves out every model that is not
  approved for clusters or that these Macs cannot serve, with no reason beside
  it. A model named on the command line says why ("… is not approved for
  clusters yet.", or "… can't run on these Macs: <reason>."). When no
  approved model can run, the screen says so and gives each reason once, after
  the models it holds back, for example "supported on a cluster, but this Mac's
  cluster worker does not take this copy of it"; a model is listed once when
  another copy of it can be served.
- **A model does not fit now**: it is listed after the ones that fit, ending
  "does not fit now". What frees the memory ("Quit apps on the other Mac (…)
  first.") is said, and nothing starts, if it still does not fit when checked
  again right before the start.
- **The start does not finish**: the screen shows each Mac's last error and
  offers **Save diagnostics for Darkbloom**, which writes a file to
  your home folder (no keys, addresses or names in it; nothing is written if any
  would remain).

## Pairing again

Pair the Macs again after either Mac moves between the Darkbloom and DevNet apps,
after the official installer reinstalls Darkbloom ("Secure Enclave ✓ (P-256 key
generated)"), or when one Mac was reset or replaced. Each app keeps its own
Secure Enclave key, and the pair's roster names the keys the Macs paired with,
so a pairing made with another key cannot register: every start of its part ends
with "This Mac's Secure Enclave key is not the one it paired with; pair again."

1. Run `darkbloom cluster` on either Mac.
   - When this Mac's key is not the one its pairing names, it says "This Mac's
     Secure Enclave key changed after it paired (…), so the Macs must pair
     again to serve through Darkbloom." and offers **Pair again** and **Quit**.
   - When the other Mac does not answer, it says "The other Mac (…) isn't
     answering over the cable. Its cluster service is off, or that Mac is asleep,
     off, or waiting for someone to log in. On that Mac, run `darkbloom start` or
     `darkbloom cluster`." Do that first: a Mac that was only asleep, logged out
     or stopped needs no new pairing. If it was reinstalled, unpaired or replaced, use **Start over** here; the Mac that follows lists it after **Try again**. A
     model choice whose other Mac stops answering ends with **Try again**,
     **Start over** and **Quit**; while it waits, the screen says
     why ("Waiting for the other Mac's cluster service: …").
   - On a pairing that works, **Start over** is in the list too.
2. Choose **Pair again**, or **Start over** and answer **Yes, start
   over** (No is the default). This Mac unpairs as `darkbloom cluster pair
   --forget` does ([undo](#undo)), says "✓ Unpaired this Mac.", then runs the
   ordinary setup and waits at "2/4 Pair".
3. Run `darkbloom cluster` on the other Mac. It no longer reaches this Mac over
   the old pairing, so it offers **Start over** (or **Pair again**
   when its own key changed too): choose it. A Mac with no pairing goes straight
   to Pair.
4. Answer **Yes** on each Mac when both show the same code. The Mac that waited
   leads and chooses the model again.

**Quit** changes nothing. Asking the other Mac is one status request over the
cable (`OnboardingLive.otherMacAnswers`); the key check reads this Mac's key
without creating one (`ClusterPairingProvider.existingPin`). Both are explained
in [a saved pairing the onboarding cannot use](../architecture/inference.md#a-saved-pairing-the-onboarding-cannot-use).

## Undo

`darkbloom cluster link --remove` on each Mac restores the cable port's earlier
network settings (one approval). `darkbloom cluster pair --forget <pin>` removes
a pairing; **Pair again** and **Start over** in `darkbloom cluster`
take the same steps (`ClusterUnpairing`). Run on the leader, it first tells the other Mac over the
cable, which removes the pair's prompt-cache records (its own single-Mac cache
stays) and stops its part; each Mac also removes its own pair records when it
unpairs.
`darkbloom cluster stop` stops a Mac's cluster service and keeps it from starting
at login. On the leader it stops the pair first. When the other Mac is gone for
good, `darkbloom cluster stop --local-only` stops only this one.

## Cache settings

The leader's cache choices (`darkbloom cache set`, the prefix cache switch, the
daily write limit, the TTL and an explicit disk budget) reach the other Mac
through its cluster service, which applies them to the ranks it starts. Each Mac
keeps its own cache folder and, without an explicit budget, sizes the pair's
cache from its own free space. The SSD records' precision
(`engine_v2_kv_checkpoint_quantization`) is not synced: each Mac reads its own,
and they must match.

## Not yet in this build

- A pair that serves on the leader's local API, or a Mac that serves alone,
  does not update while it serves
  ([updating Darkbloom on the pair](#updating-darkbloom-on-the-pair)).
- The login agent and macOS's one Local Network approval need the signed
  Darkbloom.app ([always on](cluster-always-on.md)).
- A pair served through Darkbloom cannot use unequal tensor-parallel shares
  yet: on two different Macs it is planned 1:1, so the slower Mac sets the pace
  ([how the split is chosen](#how-the-split-is-chosen)).
- A member cannot yet download a catalog model itself (the leader downloads and
  copies).

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
`darkbloom cluster` on the leader and test a response. An ad-hoc development
service can lose outbound access when its originating session closes; use the
signed app instead of extending lease timeouts. See [background service
permissions](cluster-always-on.md#permissions-asked-once).
