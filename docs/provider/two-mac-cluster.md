# Two Macs as one provider (guided setup)

> Last updated: 2026-11-11

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

## Before you start: be at both screens

Setting up a pair raises macOS prompts on each Mac's own screen: its
administrator password for the cable port (and again to undo it), Allow for
Local Network, and Yes to the pairing code. Many pair Macs have no display (a
Mac Studio, a MacBook with its lid closed): open Screen Sharing to such a Mac
before you start. `darkbloom cluster` opens with the same note on both Macs
("You'll approve macOS prompts on each Mac's own screen: … For a Mac with no
display, open Screen Sharing to it first."), and once paired it names the other
Mac where its prompt is ("Approve it on the other Mac's screen too (<name>); use
Screen Sharing if it has no display.").

Don't run the setup over SSH. In an SSH session with no desktop macOS can't
show its approval prompt, so `darkbloom cluster` says so before 1/4, before
anything is tried ("macOS can't show its approval prompt over SSH. Run
`darkbloom cluster` in Terminal on this Mac's own screen, or through Screen
Sharing."), and offers Quit (the default: "✗ Nothing changed. …") or Go on over
SSH (the password then goes into `sudo` in that terminal, and Local Network is
still answered on the Mac's own screen). `darkbloom cluster link --fix` and
`--remove` say the same before they start and try no prompt, and
`darkbloom uninstall` over SSH stops before it changes anything when a cable
port setup is left to undo.

## The cluster waitlist

Darkbloom approves accounts for clusters from a waitlist. The waitlist is for
your account, not for each Mac: join it once, from either Mac linked to your
account with `darkbloom login`:

```bash
darkbloom waitlist cluster
```

It puts your account on the waitlist, sending nothing about your Macs, and
prints your place in line; Darkbloom reviews accounts in the order they joined
and approves them by hand. Run it again to see where you stand: it keeps your
place, and once you are approved it says so and names the command that starts
a cluster. `darkbloom waitlist` alone lists every waitlist and where you stand
on each.

A new pair that serves through Darkbloom needs that approval: on a Mac that is
not paired yet, `darkbloom cluster` checks the waitlist before it starts.
Serving on your own Macs only (`darkbloom cluster local`) needs no approval and
no connection to Darkbloom. Not on it, it offers
to join; waitlisted, it shows your place and sets nothing up ("Nothing was set
up. Run `darkbloom cluster` again once Darkbloom approves your account.").
Macs that are already paired are never asked: a pair you set up before the
waitlist keeps working as it did, through updates and restarts. Details:
[CLI reference: waitlists](./cli-reference.md#darkbloom-waitlist).

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
picks a line such as "Qwen3.8-27B-4bit-mtp · 16.3 GB". While the setup waits (for the other Mac,
for Allow), q or Esc stops it and an arrow key does nothing; no prompt asks for
a key to do something. The model list shows only models
approved for clusters (`ClusterPublicModels.declared`: GLM-5.3-Flash,
Qwen3.8 27B, MiMo-V2.6-Flash and Gemma 4 26B QAT) that these two Macs can serve; any other model is left out, and a
model named on the command line that is not approved is refused.

Each Mac asks for up to two macOS approvals, at stated moments while you are at
that Mac, and Connect's first line says so ("Allow macOS permissions."). Each
prompt's line says what to click:

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
  Network prompt for Darkbloom. Approve it on the other Mac's screen too
  (<its name>); use Screen Sharing if it has no display." The setup
  waits until Allow ("✓ Allowed"), however long you
  take at the other Mac, or until q; after 15 s it also names the switch in
  System Settings → Privacy & Security → Local Network. A cluster service that
  reports no probe within 10 s (one an earlier Darkbloom release started) gets
  the line as an "if", and the setup goes on.

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
   other Mac: it leads."). The leading Mac publishes what its screen waits on in
   its status (`ClusterControlReply.step`), and this Mac says each new one once,
   for example "The other Mac (Apple M5 Max, 128 GB): it's waiting for Allow on
   its Local Network prompt." The steps are Allow on its Local Network prompt,
   reading both Macs, Try again, the model list, a copy, a login and starting.
   The live line says the same and how long it has waited out of the bound
   ("… · 2 of 15 min (q leaves)"). The line is fitted to the window's width as
   it is now, so a narrow window, or one made narrower, never wraps it. A plain
   transcript (`NO_COLOR`, `TERM=dumb`, a pipe) has no live line, only the lines
   said once per change. A leader on an older build publishes no step, and the
   line keeps the general words.
   - If the leading Mac refused every model, this Mac ends at once with the same ✗.
     When the two Macs run different builds, that is "✗ Not serving: The two Macs
     run different Darkbloom builds." with both versions when the leading Mac
     said its version, and `darkbloom update` on the Mac that is behind.
   - If nothing starts within 15 minutes, it ends with "✗ Not serving: The other
     Mac (…) didn't start a model within 15 minutes.". Under it: what that Mac was
     last doing, to answer what its screen asks or run `darkbloom cluster` there
     again, and `darkbloom --version` on both Macs. The pair still starts by
     itself if the leader starts later.
2. Once the leader starts, its live line follows the start (loading, offered to
   Darkbloom, then one row per Mac while Darkbloom pairs them). Serving through
   Darkbloom, the leader's start asks Darkbloom whether to offer the pair after
   its test; until it has, the leader's status says so ("Starting <model>: loaded
   on both Macs; checking with Darkbloom before it offers the pair.", with no ✓
   in `darkbloom cluster` on either Mac) and this Mac keeps following. Offered,
   it says "Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to
   accept this pair…" and waits as the leader does, so both screens end the
   same way. When Darkbloom's model catalog does not list the model, Darkbloom
   never pairs the Macs for it; each Mac's part reads the catalog after it
   registers, and both screens and `darkbloom cluster status` end with "✗ Not
   serving: The coordinator does not pair Macs for <model>: its model catalog
   does not list it" (`ClusterLocalServing.catalogRefusal`) instead of waiting.
   A pair Darkbloom pairs under an approval that serves only this account's own
   requests (a model approval such as `devnet/<model>/s1`, a pair approval saved
   by hand, a model a release doesn't approve for public pairs, or a mode it
   doesn't approve) ends with "✗ Not serving publicly: the coordinator paired
   both Macs but doesn't send public requests to this pair (<why>)." and what to
   do, never ✓ (`ClusterPublicServingCheck`).
   Every start the leader's screen makes publishes its test's outcome,
   and this Mac ends with it, without a test of its own: a pass with the leader's
   response time ("Test response in 0.61 s (the leading Mac's test)"), a failure
   with the same ✗, reason and note ("Setup saved, but the test failed."; through
   Darkbloom "… the pair was not offered to Darkbloom."). With **Only me**,
   the leader's status says "Starting <model>: loaded on both Macs; the leading
   Mac is testing it." until its test is answered. With a leading Mac on an
   earlier Darkbloom release, which publishes none of this, this Mac sends its
   own test request and may show ✓ before Darkbloom accepts the pair. Later
   tests from the leading Mac's screen (choosing the serving model, its Retry,
   the test after switching between Only me and serving through Darkbloom)
   replace that result in the status: a failure reads "The last test from the
   leading Mac failed." under the not-serving line. Switching between Only me
   and serving through Darkbloom, the next start or serve, and a stop clear
   it.
3. Offered to Darkbloom and not serving yet, it waits for the leading Mac's
   outcome and never judges the pair by a wait of its own. A reason that clears
   by itself keeps it waiting, with a live row and the time of the bound, e.g.
   "Waiting for Apple to verify this Mac (Darkbloom retries by itself) · 2 of
   15 min" or "Waiting for Darkbloom to pair both Macs".
4. It ends with the leading Mac's outcome. After ✓, the same one-line ✓ block
   and hint as the leading Mac ([the ending](#the-ending)). After the leading Mac's ✗ (`ClusterControlReply.start`
   with phase `failed`, named from this Mac's side), the same ✗ and next step,
   then "Choose Retry on the other Mac (…): its screen shows the choices." That
   line appears only in that ✗, since the leading Mac's screen shows Retry then.
   After a failed test: "To test again, run `darkbloom cluster` on the other Mac
   (…) and choose the model it serves." It ends early only for a reason of its
   own, such as a different Darkbloom build. Between its local test and the
   registration that starts both parts again as cluster members, the leading
   Mac's status says "not offered to Darkbloom". While the leading Mac still
   publishes its start's step, this Mac keeps following until the leading Mac
   shows ✓ or ✗; the 15-minute bound of each stage still applies.

Running `darkbloom cluster` on the Mac that joined while the leading Mac runs a
start (a model or mode change, or a Retry) follows that start the same way: the
steps, the bytes bar, one row per Mac and the final outcome. It no longer shows
"This Mac runs its part by itself … Close" while the other Mac loads.

q leaves at any time: "The pair keeps going; run `darkbloom cluster` here to see
it." The follow is bounded like the leader's start: 15 minutes for the start to
begin, then 15 minutes for each of its stages (loading; the test and the check
with Darkbloom; the registration's restart; the wait once it is offered). A
leading Mac that says no outcome within a stage's bound (an earlier release
publishes none) ends it with "✗ Not serving: The other Mac (…) didn't say how
its start ended within 15 minutes.", the last state, and "Its screen shows how
the start ended and what to do next." Its end always says why. A signed
Darkbloom.app's login agent keeps serving; without one, as for a development
build, the screen ends "Keep this window open." and the Mac serves only while
the window stays open. The Start step opens with "Loading
takes a few minutes for a large model; both Macs show progress here." On a color
terminal the live rows then give the wait and one row per Mac, each with the
time since loading began: "This Mac: ready (layers 0–46)", "The other Mac:
loading its share (layers 47–93)", "starting its part", or "part ended (exit
1); starts again in 5 s" (for a pair registered with the coordinator:
registering, registered, loading its share). There is no bar or percent while
the parts load, since no load fraction is reported. A row that doesn't fit the
window drops its layers, then shortens to "Other Mac: loading". A plain
transcript (`NO_COLOR`, `TERM=dumb`, a pipe) says each row once, when it changes.

Both Macs show the same start. The leading Mac publishes how far it is in its
status (`ClusterControlReply.start`, `ClusterOnboardingStartProgress`): the
step (downloading, copying, stopping the model that served, loading, testing,
registering with Darkbloom), a copy's or download's bytes as the sending Mac
counts them, and which Mac's part is ready. The Mac that joined reads it and
opens its own `4/4 Start` heading. Under that heading it shows the step and its
time, a bar of the real bytes during a copy or download, the same per-Mac rows
(its own row first), and what comes next ("Next: test, Darkbloom"). Each step
it finishes is said once ("✓ Files (9 min 12 s)"). Each new step gets the
follow's whole bound again, and a copy whose bytes still move never counts as
silence. A leading Mac with an older Darkbloom publishes none, and the Mac
that joined keeps its general words.

<a id="the-ending"></a>

Both Macs end the same way: one line in its own block, between two rules,
bold green on a color terminal, then one hint
(`ClusterOnboardingDriver.servedEnding`):

```
────────────────────────────────────────────────
✓ Serving Qwen3.8-27B-4bit-mtp on both Macs
────────────────────────────────────────────────
  `darkbloom status` for details
```

Through Darkbloom is implied. Served locally (`darkbloom cluster local`), the
line says where: `✓ Serving <model> on both Macs, on your local API at
http://localhost:8001` (with `on the other Mac` when that Mac's part serves
the API). The Mac that joined reads the line from the leading Mac's status
(`ClusterOnboardingReady.endingTitle(inStatusLine:)`). The pair's card (its
split, the Macs, the local API, the log, whether it starts at login and the
commands that control it) is in `darkbloom status` on either Mac
([below](#darkbloom-status-on-a-paired-mac)). A build whose cluster service
lives only as long as its window adds "Keep this window open: this Mac's
cluster service stops with it."

On an interactive terminal both Macs then say "Press Enter to exit." and wait
for Enter, q or Esc (`ClusterOnboardingConsole.waitForExit`); the pair keeps
serving. A plain transcript (`NO_COLOR`, `TERM=dumb`, a pipe), an agent's run
and anything without a terminal never wait. A ✗ that ends a run (a failed
test, a different build, the leading Mac's ✗ on the Mac that joined) ends the
same way.

<a id="darkbloom-status-on-a-paired-mac"></a>

`darkbloom status` on a paired Mac starts with `darkbloom cluster status`'s
lines (who leads, the model with its mode and split, how it serves, the
outcome, the local API), then the rest of the card
(`ClusterPairSummary.statusCardLines`):

```
Logs: ~/.darkbloom/cluster-setup/service.log
Starts by itself at login on this Mac.

  darkbloom stop     Stop both Macs
  darkbloom restart  Restart with the current model
  darkbloom cluster  Change the model
```

Darkbloom Dev, the DevNet app, keeps its own pair: its own pairing, cluster
setup, cluster service and ports on the cable, so its pair and the production
app's never answer each other. Only one app's pair runs on a Mac at a time: both
apps take one device lock
(`~/Library/Application Support/io.darkbloom.cluster/native-device.lock`), so
the second app's pair waits, and its status names the app that holds the Mac.
It starts by itself as soon as that app's pair stops, and a wait never counts
as a failing pair, so the production app never falls back to its local API for
it. The production app wins: the DevNet app also waits while the production
app serves on that Mac (even a production version from before the lock) or its
pair is set to serve there, also while it restarts for an update, and its
running pair releases the GPU at once and stops when production starts serving
there. Its
pair's API takes 8000 too, or the lowest free port up to 8020 when the
production app's pair holds it; its card and hints name `darkbloom-dev`.

It says Serving only once both Macs loaded the model and a request answered.
`darkbloom cluster` on the Mac that joined shows the same outcome block once the
cluster has one.

Serving through Darkbloom needs both Macs logged in (`darkbloom login`): the
coordinator pairs only logged-in Macs. Before the Start step starts anything,
the leader names each Mac without a login ("This Mac and the other Mac (…)
aren't logged in to Darkbloom, so the coordinator won't pair them."), says
"To use the pair just for yourself, run `darkbloom cluster local`."
(`ClusterOnboardingDriver.localPairHint`) and offers **Log in on this Mac** (or
**Check again** after `darkbloom login` on the other Mac) or **Cancel**.

A start that does not come to serve shows `✗ Not serving: <reason>.` as the
block, with the next step under it ("The other Mac (…) isn't verified by Apple
yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until
then.", "… lacks free memory for its share", "A part keeps ending the same way:
…"; the time is that Mac's local App Attest key-generation safeguard,
"within minutes" when it is unknown), the same `darkbloom cluster local` hint
when the pair is set to serve through Darkbloom, and stays open with **Retry**,
**Change model** and **Diagnostics** (a redacted file in the home folder). q leaves with "Not serving yet. Both Macs keep trying by themselves;
run `darkbloom cluster` to check." and exit status 1, never Done.

Apple's check is part of every start: each Mac's new part needs a current App
Attest authorization, which lands about a minute after it registers. While it
does, the wait and `darkbloom status` on both Macs say `checking both Macs with
Apple` (or name the one Mac), as progress (`… is not serving yet: checking
both Macs with Apple.`, read as loading). The warning above comes only once a
Mac's part has run 2 minutes without one, or its key-generation safeguard holds
it back (`ClusterOnboardingAppleCheck`).

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
`status` act on both Macs. In a terminal, `darkbloom start`'s first line says
what that screen does: on the leader of a stopped pair whose other Mac answers,
``This Mac is in a two-Mac cluster with the other Mac (…), which is stopped.
Press Enter to start it with Qwen 3.8 27B (last used), or choose another
model.``; otherwise ``…: opening the pair's screen.`` (with the other Mac
silent the screen first offers Try again, Start over or Quit). The screen
opens with both Macs and the cable ("This Mac
(Studio A) leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable
ready"; the other Mac by its hardware name, since no computer name crosses the
cable; "This Mac (Studio A) · the other Mac (…) isn't answering" when it
doesn't answer), then the pair's status: the outcome block (`✓ Serving …` or
`✗ Not serving: <reason>`), or "Stopped; last model …".

On the leader, the pair's model list follows, like `darkbloom start`'s picker:

- The model serving now is marked "serving now", or "last used" when the status
  above says the pair isn't serving, and is preselected. Enter on the model the
  pair serves sends one test request and keeps the mode it serves in.
- Each model shows its size and where it is (copied or downloaded first). The
  list shows no mode and no speed: `darkbloom cluster` chooses the mode itself
  (below). Models these Macs cannot serve are not listed.
- Under the models, **Start over (unpair and set up again)** asks once
  ([pairing again](#pairing-again)). `darkbloom cluster` has no line that
  changes how the pair serves: it always serves Both
  ([below](#both-me-first-the-pairs-own-api-beside-darkbloom)).
  `darkbloom cluster local` shows **Switch to serving through Darkbloom** there.
- q or Esc changes nothing; the screen shows the status again and the commands.

<a id="tensor-parallel-or-pipeline"></a>

**Tensor parallel or pipeline is chosen for you**
(`ClusterOnboardingMode.automaticIndex`): tensor parallel, unless it can't run
on these Macs or this pair measured it slower; otherwise the fastest measured
of the other modes, else the planner's first. `darkbloom cluster` asks nothing
and never asks to switch a model's mode.

- **Can't run:** the model has no tensor-parallel plan here (Qwen 3.8 27B's
  pipeline would drop its media and logprobs, so it has only tensor parallel;
  a mode is offered only if it keeps every feature), or tensor parallel's own
  plan doesn't fit both Macs' free memory now while another mode's does (while
  a model serves, its memory is freed first, so fitting now doesn't decide).
  Through Darkbloom, a mode Darkbloom doesn't serve publicly doesn't count
  while another one is served.
- **Measured slower:** this pair served another mode more than 5 % faster with
  this Darkbloom build (`ClusterServedModes`: at least 3 requests of 64 tokens or
  more). Not measured yet, or a link not measured yet (right after an update,
  or a new pair), is no reason: tensor parallel.
- The model serving now keeps its mode when it is chosen again (a test, not a
  reload). Every start (a new model, a stopped pair's last model, the switch to
  Darkbloom) loads the chosen mode.

`darkbloom cluster local` keeps the question, simplified: both modes, the one
the same rule picks tagged **Recommended** and preselected, so Enter takes it.
No sentence explains it and no line quotes a speed:

```text
  How should both Macs split Gemma 4 26B?
  1) Pipeline · serves one request at a time · context 65,536 tokens, prompts up to 32,768
  2) Tensor parallel · Recommended · serves up to 8 requests at once · context 262,144 tokens
  Choose 1-2 (enter = 2):
```

In a narrow window a line keeps the mode, the tag and the short words
("serves up to 8 at once · context 262,144"). A model named on the command line
(`darkbloom cluster local <model>`) loads the recommended mode without the
question. On a serving pair, choosing its model in another mode asks first
("Switch Gemma 4 26B from tensor parallel to pipeline? …").

The modes:

- **Tensor parallel**: both Macs work on every layer, each holding a share of it
  (half each through Darkbloom; local serving balances the shares by speed).
- **Pipeline**: each Mac runs its share of the layers, uneven on mixed Macs
  (for example "this Mac 6 layers / the other Mac 46 layers").
- **Speculative pipeline** (MiMo): a pipeline that drafts several tokens and
  checks them together.

Each mode in `darkbloom cluster local`'s question also says how many requests
it serves at once: "serves one request at a time" or "serves up to 8 requests
at once" (`DistributedInstalledPlan.batchLanes`: the width the setup saved for
both Macs' memory, or the family's default). It is the same number the pair
reports to Darkbloom. On a GLM-5.3-Flash pair tensor parallel is the one to
use: its pipeline serves one request at a time, and through Darkbloom every
other request waits about 6 s and is then refused as "at capacity". On two M5
Ultras (2026-11-04, DevNet), its tensor parallel served 8 requests at once with
none refused, and each answered about 2.6 times faster (105.6 against 40.8
tokens/s alone).

While a model serves, a mode's split reads "decided when it loads": the list
plans with that model's memory still taken, and the start stops it and plans
again with its memory free. `darkbloom status` shows the split that loaded.

A mode is offered only if it keeps every feature of the model: Qwen 3.8 27B
offers tensor parallel only, because pipeline would drop its image, video and
logprob support. A mode chosen on the following Mac goes to the leading Mac
with the model, so the pair loads it the same way.

Choosing the model that serves sends one test request, the same as a start's,
and changes nothing else; it passes with [the ending](#the-ending)'s ✓ line,
and a failed test shows the ✗ block with **Retry**, **Change model** and
**Diagnostics**. A pair served only through Darkbloom (saved by an earlier
build or an agent's run) has no local API on this Mac to send a test from; the
screen says so ("Already serving Qwen 3.8 27B through Darkbloom; this Mac has
no local API to send a test from.") and shows the pair's status as both Macs
report it. Choosing another while one serves asks once ("Switch to
Gemma 4 26B? Qwen 3.8 27B stops serving on both Macs while Gemma 4 26B loads …",
**No** by default), then says "✓ Stopped Qwen 3.8 27B on both Macs" and shows
each Mac's load. The steps are headed **Model** and **Start**; the numbered "1/4
… 4/4" steps are the first setup's only. Every start ends as
[the ending](#the-ending) says; a pair that does not serve ends with the ✗
block and **Retry**, **Change model** and **Diagnostics** instead. To stop, run
`darkbloom stop`: both Macs stop and free their memory. The start's own test
request is the test.

**Set up the cable port** comes first when the cable moved to a port not set
up yet ([below](#when-something-is-in-the-way)).

Switching how a serving pair serves says what it does ("Switching to serving
through Darkbloom: both Macs load the model again from a plan made for
Darkbloom." or "Switching to local only: the leading Mac's part starts again
that way."), never the result: the outcome block follows once the pair serves, or why it doesn't. A
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
its artifact ships, but only on a pair that serves **Only me**. The
assistant is not qualified for public traffic, and a setup registered with the
coordinator never carries it. So, with the default `[backend] mtp_mode` of
`auto`:

| You run | Qwen3.8 27B decodes | One request on two M5 Ultras (2026-10-31) | The coordinator |
|---|---|---|---|
| `darkbloom cluster` | without the assistant | about 40 tokens/s | the pair registers when the coordinator serves a matching approval |
| [`darkbloom cluster local`](#serving-locally-only) | with the assistant | about 93 tokens/s | never contacted |

With `mtp_mode = "on"`, `darkbloom cluster` keeps the assistant too. That pair
is then not offered to the coordinator: its plan says "not offered for public
traffic", and it serves on the leader's local API. **Switch to serving through
Darkbloom** on a serving cluster plans its model again for Darkbloom (without the
assistant, with equal shares) and starts it as a start does. **Switch to local
only** keeps the setup it has; to plan the model again for local serving, stop
the pair (`darkbloom stop`) and start it again from the list. Public speculative decoding for Qwen pairs needs
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
| 1 | the first Mac | Run `darkbloom cluster`. Its first line is "Allow macOS permissions." It checks the Thunderbolt cable ("✓ Cable ready") and Local Network access. Nobody waits on the cable yet, so this Mac leads; its last line, set apart by blank lines and in bold with the command in color, is **"→ Now run `darkbloom cluster` on the other Mac"** (`ClusterOnboardingPairing.otherMacCallout`; `darkbloom cluster local` names `darkbloom cluster local`), and it waits (q cancels). With two cables it asks "Which cable goes to the other Mac?" | the cable's port, once (your password; sudo in this terminal where macOS shows no window); Local Network access for the terminal app only where macOS blocks it |
| 2 | the other Mac | Run `darkbloom cluster`. The same checks; then it finds the waiting Mac on the cable by itself (no address, no host name). Both screens show the same six-digit code ("Code 123 456. Same on the other Mac?"); a Mac that answered first says "Now confirm on the other Mac." | the same as the first Mac; **Yes** on each Mac when the codes match |
| 3 | both Macs | Each says it is paired ("✓ Paired. This Mac leads." on the leader, "✓ Paired. The other Mac leads." on the other Mac). Both cluster services now run, and macOS asks on both Macs at the same moment to let Darkbloom find devices on your local network: click Allow on each; each screen waits for its own ("✓ Allowed"), up to 10 minutes with a timer, then ends with a ✗ that says where to turn Darkbloom on and what to do if it isn't listed. Nothing else is ever asked on the other Mac; it says "Waiting for the other Mac (…) to choose the model and start…", says what the leader's screen waits on, and follows the start to the same ✓/✗ block. | Local Network access for Darkbloom, once on each Mac |
| 4 | the leader | It lists every model approved for clusters that the pair can serve (held by both Macs, by one of them, or in Darkbloom's catalog), one line each with its size, ending "copy" or "download" when the model must reach a Mac first ("Qwen3.8-27B-4bit-mtp · 16.3 GB"). It asks nothing about how the pair serves (it serves through Darkbloom with this Mac's local API beside it, [Both](#both-me-first-the-pairs-own-api-beside-darkbloom)) or how both Macs split the model ([chosen for you](#tensor-parallel-or-pipeline)). A model a Mac holds twice (a catalog download beside the cluster's own copy) is listed once. Models that fit in the Macs' free memory now come first; one that does not ends with "does not fit now". A model a Mac has no room for on disk now comes last, ending "not enough free disk" ([Free disk](#free-disk)). Choose the model with ↑↓ and enter (enter takes the first). If the other Mac does not answer over the cable (its Darkbloom prompt may still wait for Allow), it offers **Try again** or **Cancel**. | the copy first in a list; a short one says its time ("Copy to the other Mac (about 7 s)") |
| 5 | — | Choosing is starting: the leader saves the setup, sends it to the other Mac over the cable and starts both Macs in the chosen mode; once both are loaded it answers one test request, and the coordinator is asked for the pair ([below](#registered-with-the-coordinator-as-a-cluster-member)). Both Macs end on one line, "✓ Serving Qwen3.8-27B-4bit-mtp on both Macs", and "`darkbloom status` for details" ([the ending](#the-ending)); on an interactive terminal, "Press Enter to exit." | Enter (an interactive terminal only) |

No screen and no status says it serves or earns through Darkbloom unless the
pair is offered (both Macs carry a cluster approval) and the coordinator has
it. A pair set to serve through Darkbloom that the coordinator doesn't take
serves on the leader's local API only, and both Macs say why: `✗ Not serving:
not offered to Darkbloom (<why>).`, then `Meanwhile it answers only on the local
API at http://localhost:<port> (no Darkbloom traffic).`

Every screen names the Macs from where it is shown: "this Mac" is the Mac the
screen is on and "the other Mac" the other one. A line that must tell them
apart adds the hardware name pairing showed ("the other Mac (Apple M3 Ultra,
256 GB)"), never its host or computer name; only this Mac's own screen names it
as System Settings does ("This Mac (Studio A) leads"). A Mac that does not lead
shows the leader's answers in the same words for its own screen.

When the coordinator in your provider configuration cannot take a cluster
member yet (it is unreachable, or it has no cluster support), the pair still
serves, on the leader's local API only, with the same local token as
`darkbloom start --local`. It isn't offered, so both Macs say `not offered to
Darkbloom (the coordinator could not be reached or has no cluster support)`.
The leader's part logs why:

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
   is no local API in a pair saved as the Darkbloom network alone (an earlier
   build or an agent's run); `darkbloom cluster` serves
   [Both](#both-me-first-the-pairs-own-api-beside-darkbloom).

   The wait says only what the Macs report at that moment. "isn't verified by
   Apple yet" appears only while a Mac reports its App Attest authorization
   missing. A coordinator trust word on two authorized Macs reads "The
   coordinator didn't accept the pair yet (<word>)". When the 15 minutes run out
   with both Macs registered and nothing reported, the ✗ says "The coordinator
   didn't pair both Macs within 15 minutes; both are registered with it, and it
   gave no reason". When the coordinator's reason is known (for example a model
   its catalog doesn't list), that reason is shown instead. q or Esc leaves this
   wait: "Left the wait: both Macs stay registered and the pair keeps trying to
   be paired by the coordinator by itself. Check with `darkbloom status`." A
   `darkbloom cluster stop` from any window or either Mac ends the wait at once
   with "Stopped (by `darkbloom cluster stop` on one of the Macs): the pair
   isn't starting any more." The Mac that joined says the same once the leading
   Mac's status has stayed stopped for 20 seconds.

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
| Registered, not serving yet | `<model> is not serving yet: <reason or progress>.` (a missing login, App Attest, memory). The leading Mac's setup screen adds what to do under its ✗; `cluster status` says it in `Next:` |
| On the leader's local API: not offered | `<model> is not serving yet: not offered to Darkbloom (<why>).`, then `Meanwhile it answers only on the local API at http://localhost:<port> (no Darkbloom traffic).` and the test's line. `<why>` is one of the rows below, never "earning through Darkbloom" |
| … coordinator gave no answer for the grace | `The coordinator has not answered for 10 minutes: the pair serves on the leader's local API until it answers again, then it is offered again with approval <id>` |
| … approval no longer listed | `The coordinator no longer lists cluster approval <id>: the pair serves on the leader's local API until it lists a matching one again` |
| … parts kept ending | `The coordinator-paired parts ended 3 times in a row right after starting with cluster approval <id>: the pair serves on the leader's local API for 60 minutes, then it is offered again with it, or sooner with a later one the coordinator lists` |
| … approval ended | The line that says the cluster approval `<id>` expired and the pair serves on the leader's local API |
| … the check refused the approval | `this Mac's check refused it: <reason>` (or the other Mac's refusal) |
| … no approval (staging, production before its coordinator derives approvals from releases, no matching entry) | `no cluster approval is attached to its setup` |

`darkbloom cluster status` reads the first row as `serving` (exit 0) and a pair that isn't offered as `not_serving`
(exit 3), on both Macs. During a model or mode change, or while the pair updates Darkbloom, it can read `stopped`
(exit 4) or `unknown` for a minute or two while the pair is actually reloading: wait about a minute and check again
before running `darkbloom start`.

Approval sources, checks and saved fields:
[coordinator-paired member](../reference/configuration.md#coordinator-paired-member).

Counting every key: enter for **Yes** on each Mac and enter for the first
model on the leader (three keys), plus the macOS prompts [above](#the-steps-once).

In a color terminal at least 40 columns wide, each step folds to one line once
the next step begins: "✓ 2/4 Pair (1 min 12 s)". The lines that stay are the
pairing code, each question with the answer given, and an outcome block. A step
that showed a ✗ stays whole, as does a step taller than the window (rows that
scrolled off can't be redrawn) and a step during which another command wrote to
the terminal (`sudo`, `darkbloom login`). The last step and the outcome stay
whole. The whole flow, line by line, goes to a log file for this run
(`~/.darkbloom/cluster-setup/screens/screen-<UTC time>Z-<pid>.log`; the 20
newest are kept, `ClusterOnboardingTerminal.screenLog`). Its path is the last
line ("Full log: …"), and a ✗ block names it as well. Plain output (a pipe,
`NO_COLOR`, `TERM=dumb`) has every line already: nothing folds and no log is
written.

Running `darkbloom cluster` again on either Mac opens with the same Darkbloom
mark, beside "Darkbloom cluster · Leading Mac" or "Darkbloom cluster · Joining
Mac" (`ClusterOnboardingDriver.title(_:)`; a first setup, before the two Macs
pair, says "Darkbloom cluster" alone), then the part each Mac plays and the cable
("This Mac leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable
ready"; with the name System Settings gives this Mac, "This Mac (Studio A)
leads · …", so two identical Macs each say which they are), then shows the
cluster's state as the outcome block ("✓ Serving Qwen3.8-27B-4bit-mtp through
Darkbloom on both Macs (pipeline)", or "Stopped; last model …")
and, on the leader, the pair's model list [above](#the-steps-once). The other
Mac then says its part runs by itself, names the Mac it follows and the command
to run there; Enter closes it, and **Start over (unpair and set up again)** is
the other choice. When the cable moved to a port not set up yet, it offers to
set that up first ([below](#when-something-is-in-the-way)).

If both Macs start waiting at the same moment, the pairing's own rule picks one
to keep waiting (it leads) and the other joins it ("✓ Paired. The other Mac
leads.").

<a id="both-me-first-the-pairs-own-api-beside-darkbloom"></a>

## Both: the pair's own API beside Darkbloom

`darkbloom cluster` serves every pair one way, with no question (owner,
2026-11-11): through Darkbloom, with the pair's own local API on the leading
Mac beside it, and Darkbloom keeps serving while you use that API
(`ClusterOnboardingOperations.servesBoth`, `ClusterServingChoice.both`).

- **Saved:** as the run begins, on the leading Mac, `[local] mode = "both"` and
  `[local] me_first = false` in its `provider.toml`
  (`Cluster.Setup.saveServingChoice`). A `me_first = true` saved on purpose
  (`darkbloom start --me-first`) stays, and the pair then pauses Darkbloom
  while you use its API, as below. A pair that already serves Both with the
  pause on keeps it until its next start, and the screen says so ("Darkbloom
  keeps serving while you use the pair's local API from the pair's next start
  (`darkbloom restart` starts it again now)."): the leading part reads `[local]`
  when it starts.
- **A pair saved another way** (Only me, or the Darkbloom network alone from an
  earlier build or an agent's run) switches when you run `darkbloom cluster` on
  the leading Mac, and the screen says so in one line ("This pair served only
  on your local API; `darkbloom cluster` serves it through Darkbloom, with your
  local API beside it."): a serving pair switches at once
  ([switching](#switching-how-a-pair-serves)), a stopped one starts that way from
  the list. An update, a restart or the cluster service never change how a
  pair serves.
- **Only in a terminal, and only `darkbloom cluster`** (and `darkbloom start` on
  a paired Mac, which opens the same screen). `darkbloom cluster local` serves
  **Only me** ([below](#serving-locally-only)). Without a terminal (an agent's
  run, the cluster service) the pair serves as its setup says.
- **Where the pair can't serve through Darkbloom** (no login, an account the
  waitlist hasn't approved, no approval for the model, a coordinator without
  cluster support), the screen says "To use the pair just for yourself, run
  `darkbloom cluster local`." instead of offering to serve locally.

With **Both**:

- **The API:** the part that runs rank 0, which hosts the pair's slot, serves
  the pair's local OpenAI-compatible API beside Darkbloom, on the same engine
  and lanes as Darkbloom's requests
  ([a pair's leader beside Darkbloom](./direct-mode.md#a-pairs-leader-beside-darkbloom)).
  Every other Mac answers on its own port too (below).
- **Address and key:** it listens on every network of that Mac, as with **Only
  me**, on that Mac's own port: its saved `[local] port`, which every local API
  on that Mac takes ([your local API](./local-first.md#your-local-api)). A Mac
  with no saved port keeps the one its local API already uses, else takes the
  first free one from 8001, never 8000, where other local AI apps listen, or
  the pair's own ports 47420–47423, and saves it; a Mac updated from 0.10.10
  keeps 8000. It always needs a key: that Mac's own (`local_token`, which
  `darkbloom local` there shows and its tools read), or the pair's
  (`cluster_local_token`, the same on every Mac). With the macOS firewall on,
  macOS may ask once to let Darkbloom accept incoming connections.
- **On every other Mac:** its cluster service passes that Mac's own port, its
  own saved `[local] port` (chosen the same way), to that API over the cable,
  as with **Only me**, so each Mac of the pair answers at
  `http://127.0.0.1:<its port>/v1`. The two Macs' ports may differ, and each
  Mac keeps its own whichever Mac runs rank 0, so tools set up there keep
  working. Tools there use that Mac's own key: `darkbloom local` there prints
  the address and the key, and `darkbloom start --opencode` (or `--hermes`)
  there sets them up for it. The port passes each request on with the pair's
  key instead, and passes every other byte, and every answer, as it comes.
  With the pair's API on loopback or one address (`--bind`), no other Mac
  passes its port on, and tools there dial that Mac.
- **A port another program holds** stays that Mac's: Darkbloom never moves a
  saved port. The pair's API then can't listen there, or that Mac's port
  passes nothing on, and `darkbloom status` there says which port, as
  `darkbloom local` and `darkbloom start --opencode` there do. Free it, or set
  another `[local] port` in that Mac's `provider.toml`, then run
  `darkbloom restart`.
- **When the Mac that runs the pair's API is away** (unplugged, asleep), each
  other Mac's port answers a `503` that says so, at once, until it is back
  ([if a Mac goes away](#if-a-mac-goes-away)).
- **Requests the pair can't take** (a model it doesn't serve, a full queue) go
  on as that Mac's `[local] route` says, with that Mac's account key
  ([the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router)).
  `darkbloom route this-mac`, `my-macs` or `my-macs-first` on that Mac sets it,
  and the pair's API uses it from its next request, with no restart; on the
  other Mac it says to run it on the leading Mac.
  Requests from other machines never use the paid network; they can use the
  pair and your other Macs. That includes the pair's other Mac, its own port
  for the pair's API too: its requests reach the leading Mac from another
  machine, so with `my-macs-first` tools there use the pair and your other
  Macs, never the paid network.
- **Darkbloom keeps serving** while you use the pair's API: your requests and
  Darkbloom's share the pair's lanes. Only where the leading Mac's `[local]
  me_first = true` (set on purpose) does the pair pause: while one of your
  requests runs on it, or waits for a lane, it takes no new Darkbloom request,
  Darkbloom's running requests finish, and it takes Darkbloom requests again 2
  minutes after your last request ends (`[local] me_first_idle_minutes`, 1 to
  120; [owner pause](../architecture/owner-pause.md#pairs)). A request on
  another Mac's port is yours too. While it is paused, the pair keeps its base
  reward on the coordinator that ships with 0.10.11
  ([darkbloom-platform#709](https://github.com/Layr-Labs/darkbloom-platform/pull/709)
  onwards), as a single Mac does.
- <a id="switching-how-a-pair-serves"></a>**Switching:** from the Darkbloom
  network alone the plan stays: only the leading part starts again, and the
  screen waits until the pair serves again. From **Only me**, the model is
  planned again for Darkbloom first. Both need both Macs logged in.
- **Not offered:** while Darkbloom doesn't have the pair (no approval, the
  coordinator away), it serves on the leader's local API as before
  ([above](#registered-with-the-coordinator-as-a-cluster-member)): on that Mac
  only (`127.0.0.1`), on the same port, with that Mac's own key alone
  (`darkbloom local` there shows it, and tools set up there keep working). The
  other Macs pass nothing on meanwhile, and their `status`, `darkbloom local`
  and `darkbloom start --opencode` say so. Tools on
  other machines, the other Macs' ports, and tools set up with the pair's key
  reach the pair again once Darkbloom has it.

`darkbloom status` and `darkbloom cluster status` say it: `Serves: through
Darkbloom, and on its local API`, the pair's line and its `Local API:` line.
With `me_first = true`, on the Mac that runs the pair's API:

```text
Serves: through Darkbloom, and on its local API with you first
✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).
  Pair: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if you stay idle)
Local API: http://127.0.0.1:8001/v1 on this Mac, and port 8001 of its LAN or tailnet address (`darkbloom local` shows the key)
Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; its own port passes your requests to this API
```

`Pair: Darkbloom and you, me first — open to Darkbloom (…)` while you aren't
using it. Times are said from now ("paused for under a minute", "back in about
2 minutes", "back any moment now"), never as a clock time: the other Mac, or an
SSH session, may be in another time zone.

The `Pair:` line comes with the leading Mac's status, which the other Mac asks
for on every `status` anyway, so the other Mac says the same, under the pair's
line (nothing more crosses the cable, and nothing per request):

```text
✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).
  Pair: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if you stay idle)
Local API: http://127.0.0.1:8001/v1 on this Mac, and port 8001 of its LAN or tailnet address (`darkbloom local` shows the key)
Members: the other Mac (Apple M5 Ultra, 256 GB) runs the pair's API; this Mac passes your requests to it, and Darkbloom pauses for them too
```

Each Mac's own port can differ: here both Macs saved 8001. Until its port is
passed on (the pair's API still starting), the other Mac says `Local API: not
listening on this Mac yet; it starts once the pair's API on the other Mac (…)
answers`. While Darkbloom doesn't have the pair, it says `Local API: none on
this Mac while Darkbloom doesn't have the pair; meanwhile the pair answers only
on the other Mac (…) (…)`, and with its port held by another program, ``Local
API: port 8001 on this Mac is held by another program, so this Mac doesn't
answer for the pair; free it, or set another `[local] port` in provider.toml,
then `darkbloom restart` ``. With the pair's API on loopback or one address, it says
where the API is instead (`Local API: on the other Mac (…), which runs the
pair's API; …`). The leading Mac's `Members:` line says the other Mac runs no
local API whenever its own API listens on this Mac only.

`darkbloom local` on each Mac prints that Mac's own address once its port is
up.

No screen or status line quotes a speed, and none prints the key.

<a id="serving-locally-only"></a>

## Only me: the pair for you alone

**Only me** serves the pair for you alone, with `darkbloom cluster local`: the
same steps, model
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
   cluster to **Only me** and waits until it serves again. On the Mac that joins
   a waiting leader, it pairs like `darkbloom cluster`, says to continue on the
   leader with `darkbloom cluster local`, and then follows the start there.
2. Read the API's place from the ending's line. The port is the leading Mac's
   own saved `[local] port`, as for **Both** (8001 on a Mac that had
   none, 8000 kept on a Mac updated from 0.10.10):

   ```
   ✓ Serving Qwen3.8-27B-4bit-mtp on both Macs, on your local API at http://localhost:8001
   ```

3. Get the key: `darkbloom local` on either Mac prints that Mac's base URL,
   network URL and API key: its own `local_token`, which its tools read
   (`darkbloom start --opencode` there sets them up). The other Mac relays its
   own saved port to the leader's API (`ClusterLocalRelay`) and passes your requests
   on with the pair's key (`cluster_local_token`, which works on both Macs
   too), unless the API is kept on the leader (`--bind`, below). Every request
   needs a key.

The API listens on every network of the leading Mac (LAN or tailnet) by
default. To keep it on that Mac alone, run
`darkbloom cluster local --bind 127.0.0.1`; `--bind` takes `localhost` or a
numeric IPv4 or IPv6 address. The API has no TLS, so the key and the text
cross the network in the clear: on a network you do not trust, keep it on the
Mac or reach it over a tailnet (encrypted). With the macOS firewall on, macOS
may ask once to let Darkbloom accept incoming connections.

The choice is kept: after a restart or reboot both Macs serve **Only me**
again, until you switch back. `darkbloom cluster` on the leader switches it to
[Both](#both-me-first-the-pairs-own-api-beside-darkbloom), saying so in one line;
in `darkbloom cluster local`, the list's **Switch to serving through Darkbloom**
serves through Darkbloom again. On a serving cluster, **Switch to
serving through Darkbloom** plans the model again for Darkbloom (a local plan
may carry Qwen's speculative assistant or unequal tensor-parallel shares, which
the coordinator can't register), adopts that plan before anything stops, and
starts both Macs as a start does: a test request, then the coordinator is asked
for the pair, and the screen waits until the coordinator paired both Macs and
both loaded the model. **Switch to local only** restarts the leading Mac's part
that way and waits for a test request on the leader's API. Both end with the
same outcome block: ✓ only then; otherwise ✗ with the reason and the choices,
including `Not serving: not offered to Darkbloom (<why>).` for a pair the
coordinator doesn't take. The model list still
reads Darkbloom's catalog when the network is up (to download a model neither
Mac has); with no network, it lists the models already on the Macs. Only
catalog models are served. Qualification records never gate **Only me**.

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
Ultra 256 GB runs tensor parallel on equal shares with up to eight concurrent
requests, as many as both Macs' memory holds; the plan counts its NextN (MTP) layer on both Macs and its
speculative decoding ([GLM tensor parallel](../architecture/inference.md#exact-quote-placement)).
GLM-5.3-Flash has both a pipeline and a tensor-parallel adapter; its private
image candidate is pipeline-only.

Models that run tensor parallel, and when:

| Model | Tensor parallel chosen | Notes |
|---|---|---|
| Qwen3.5 9B, Qwen3.8 27B, Qwen3.5/3.6 35B A3B | wherever it fits | Qwen3.8 27B keeps images, video and logprobs only in tensor parallel |
| GLM-5.3-Flash | wherever it fits | As many requests at once as both Macs' memory holds beside the model, up to 8 (sized when the pair is set up and reserved when it loads, as far as each Mac's memory then allows; requests beyond that are taken as memory allows); where only one fits, one at a time. A pair set up before Darkbloom 0.10.12 is sized when it is planned again, which the update does by itself |
| Gemma 4 26B (QAT 4-bit, 8-bit) | only where the plan predicts it faster from its own measured speed on both Macs (it keeps every feature of the pipeline, prompt-prefix and SSD reuse included) | Text only; logprobs in tensor parallel only; QAT 4-bit serves 2 requests at once where both Macs' memory holds them beside the model (sized when the pair is set up and reserved when it loads), the 8-bit model one at a time; where only one fits, one at a time, and a request cancelled during its prompt keeps that one lane until the prompt is read (about a minute for a 16K-token prompt) |
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
hold (one layer is a share). Before a Mac's part starts, it clears the model's
own files from macOS's file cache, so the load reads its share from the SSD
into free memory. Nothing in the files changes and no password is asked for; a
start can take a few seconds longer. The worker log records each load's memory
check in a `darkbloom-load-memory-v1` line.

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

<!-- pending R-FULL: local and direct use get each model's full context window, output length and capabilities; only both Macs' memory bounds a request, and the answer says so; OpenRouter is separate. -->

Cluster workers accept up to 32,768 output tokens and 32,768 prompt tokens,
within a 65,536-token combined ceiling, except for a model served at its native
context (Qwen3.8 27B in tensor parallel, and Gemma 4 26B in both modes, below).
Each model's declared context and both ranks' live memory admission may reduce
that budget. Omitting `max_tokens` on the local API uses the full allowance,
clamped to the model and remaining context; an explicit `max_tokens: 32768`
requests the same allowance. A model can finish earlier at its stop token. A
`max_tokens` above the output limit the pair serves, or above what the prompt
leaves of its context, is cut to fit, as on one Mac. A prompt that fills that
context receives HTTP 400 `context_length_exceeded`, in one Mac's words; a
prompt longer than the mode's prompt limit receives HTTP 400 `prompt_too_long`.
Either arrives before any streamed byte.
Qwen3.8 27B on a tensor-parallel pair accepts its native context, as a single
Mac serving it does: prompts up to 262,143 tokens and up to 65,536 output tokens
(the catalog's output limit, which the coordinator also gives a request that
omits `max_tokens`), within 262,144 combined. Gemma 4 26B accepts its native
context on a pair in tensor parallel and in the pipeline: prompts up to 262,143
tokens and up to 32,768 output tokens (its catalog's output limit), within
262,144 combined. Each pair is still loaded and planned for the 32,768 +
32,768-token request, at any number of lanes. A longer request is admitted on
its own when both Macs' memory holds it at that moment. If it does not fit, it
alone receives HTTP 503 before any streamed byte (on the local API, in one
Mac's words: "This Mac's memory can't hold this request right now ..."), and
other requests keep running. In every mode, a request one Mac's memory refuses
while it runs ends alone: the client gets the same 503 (or, once a stream has
started, an error chunk with `code` `request_exceeds_node_budget` and the same
words), and the pair keeps serving. Gemma 4's pipeline serves one request at a
time with the one-chunk lookahead, its default. With lanes (a setup that
prefills serially), a very long request needs about twice its memory on each
Mac, plus about 8 GB, to run to its end: each check while it runs asks for its
whole share again, and the prompt prefix cache's copies of its prompt come on
top. That is about 24 GB a Mac at 131,072 tokens and 38 GB at 262,144, where it
is admitted with about 12 GB and 19 GB. On a Mac with less free memory, it is
admitted and then refused that way partway through its prompt, a 503 for that
request alone; one request at a time and tensor parallel serve it without that.
The pipeline modes of every other model
with a native context (GLM-5.3-Flash, and the 27B where its policy allows
them) keep the 32,768 + 32,768-token request. Their leader refuses a longer
request itself, before either rank is asked: a pipeline is planned and proven
at that request, and serving the whole context there waits for its own proof
on real pairs. See
[the 27B's native context](../architecture/inference.md#qwen27-tensor-parallel-native-context)
and [Gemma 4's](../architecture/inference.md#gemma-4-native-context-on-a-pair).

The leader's heartbeat tells the coordinator these limits for its pair's slot
(`request_limits`): the prompt, output and context limits of the mode it serves,
and the context both Macs' memory admits now. The coordinator sends the pair
only requests within them; it sends any other request to a single Mac. From the
first request it serves, the pair's slot also reports its measured prefill and
decode speeds, as a single Mac's slot does. The warmup canary is not counted.

A long prompt on the pair's own API shows its progress as on one Mac: a
streamed request gets `: prefill in progress, <total> prompt tokens` every 5
seconds until its first token ([a long prompt's progress](./direct-mode.md#a-long-prompts-progress)).
With `darkbloom cluster local`, it takes the place of the leader's 500 ms
keep-alive probe every 5 seconds.

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
while both Macs' parts report media. The pair's own API says the same in its
`/v1/models`: `input_modalities` is `["text", "image", "video"]` where the
pair's mode serves media (`["text", "image"]` on the GLM and MiMo image
candidates' profiles) and `["text"]` otherwise (`LocalInputModalities`).
`darkbloom start --opencode` and `--hermes` follow it for the pair's model,
whatever the catalog says, so a Gemma 4 pair gets no image input in the tools.
The list also says whether the pair's model reasons (`supported_features`:
`["reasoning"]` for every model a pair serves today, by its installed
`model_type`, before its slot is up too), which OpenCode follows the same way.
GLM-5.3-Flash answers its output
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

While the leading Mac waits for the other Mac, its part can't form the pair, and
each start reads its share of the model and registers it again. A part that
ends then waits twice as long as the last time before it starts again, from 30
seconds up to 10 minutes (30 seconds, then 1, 2 and 4 minutes), instead of every
30 seconds; it starts at once when the other Mac answers. `darkbloom cluster status` on the leading Mac says when,
under the line that it waits for the other Mac: ``This Mac's part starts again in
4 min, or as soon as the other Mac answers: …``.

While the Mac that runs the pair's API is away, the other Mac's own port for it
(with **Only me**, and with **Both** on every address) is never a
connection that just closes: it answers every request at once with a `503`
(`code` `pair_mac_unreachable`, `Retry-After: 10`), ``Your pair's other Mac (…)
isn't reachable; this Mac relays to it. Requests resume when it's back, or run
`darkbloom stop`, then `darkbloom start --solo`, to serve this Mac alone
(`darkbloom start --solo` by itself is refused while this Mac's part of the
pair holds its serving lock: up to 15 minutes after the other Mac last answered
over the cable).`` `darkbloom start --solo` by itself is refused that long
because the pair still runs here ([going back to serving on one
Mac](#going-back-to-serving-on-one-mac)); `darkbloom stop` ends it at once.
Those words name the other Mac only to a request with this Mac's key or the
pair's. A request with another key in the local key format (`dk-local-` and 43
characters), such as the other Mac's own, which works through this Mac while
that Mac is there but which this Mac can't judge, gets the same `503` without
the name; any other gets the local API's own `401`, as that API would answer
it, and a liveness check or a browser's preflight, which need no key, the `503`
without names or commands. That Mac is away once it hasn't answered over the
cable for 12 s; a status request to it that fails while it answers there
doesn't count (only before it has answered at all since this Mac's cluster
service started do two failed in a row). In those first 12 s a request gets
the same `503` within 3 s, the longest this Mac waits for that Mac to take the
connection. `darkbloom status` and `darkbloom local` there say the same, after
`Local API: http://127.0.0.1:<port>/v1 on this Mac answers 503 for now.`, and
`darkbloom start --opencode` there says it at once. Relaying resumes by itself
within seconds of that Mac answering over the cable again.

When only that Mac's part stops or starts again (a stop, a restart, an update,
a crash) while that Mac stays on the cable, that Mac is never away: every
request gets a `503` with `code` `pair_api_unavailable` and `Retry-After: 10`
at once, from the first one on, to the same callers the same way. The pair's API
there answers it while its pair doesn't serve (stopping, starting, its warm-up
request), ``The pair's API takes no requests right now: the pair is starting
or stopping. Requests resume when it serves, or run …`` with the same commands,
and never holds a request until the pair serves; once nothing listens there,
this Mac's port answers ``The pair's API on your pair's other Mac (…) isn't
answering yet; this Mac relays to it. Requests resume when it answers, or run
…``. This Mac's port stays up meanwhile, and `darkbloom status`, `darkbloom
local` and `darkbloom doctor` there say `Local API: http://127.0.0.1:<port>/v1
on this Mac answers 503 for now.` with those words. Requests pass again as soon
as that API listens. A Mac that serves the model alone after the 10 minutes
does so on its own saved port (`[local] port`), so its tools keep their
address.

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

GLM-5.3-Flash on two 128 GB Macs is planned differently: each Mac loads its
half on what loading needs, and each request is checked against the memory free
when it arrives (a longer request than fits then gets a retryable "busy" answer,
never an out-of-memory crash). Its plan fits two M5 Max 128 GB at the default
limit too. When a GPU limit is what stops a GLM plan, the plan says so and, on
an Apple silicon Mac with 128 GB or more, names the one command that changes it:
`darkbloom cluster gpu-limit`. Run it on that Mac yourself: it asks once, then
macOS asks an administrator, and it raises the limit to the Mac's memory less
16 GiB (112 GiB of 128 GB), also after restarts. `darkbloom cluster gpu-limit
--undo` takes it back ([GPU memory limit for a GLM pair](../reference/configuration.md#gpu-memory-limit-for-a-glm-pair)).

Only modes that load on the pair are offered. On two 128 GB Macs that is the
pipeline: tensor parallel needs more than either Mac has. On an M4 Max with an
M5 Max, each Mac's part is sized by its own GPU limit (107.52 GiB on macOS 26),
and `darkbloom cluster gpu-limit` runs on both (any Apple silicon Mac with
128 GB or more), so the plan counts a raise on either. When nothing fits as the Macs
are, the model's row says which of two things holds:

- **"Needs `darkbloom cluster gpu-limit` first"**, naming the Mac, its part's
  GPU need and the limit: a split fits once that Mac's limit is raised. Run the
  command there, then `darkbloom cluster` again. Nothing loads before.
- **"Needs more memory"**, with the reason: no split fits even with the limits
  Darkbloom can raise, or the Macs together cannot hold the model. Intel Macs
  and Macs under 128 GB are never raised.

These rules (`ClusterGPUMemoryLimit.raisedByDarkbloom`,
`ClusterSetupPlanning.gpuLimitSteps`, `refusalWords`) are checked pair by pair
in `libs/darkbloom-cluster/Tests/PlacementChecks/GLMPairOfferChecks.swift`.

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
and its status says why (`not offered to Darkbloom (…)`); choose the model again
in `darkbloom cluster` to plan it again.

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
Requests to the local API share prefixes with one another only. How the caches are
partitioned: [encryption and privacy](../architecture/security/encryption.md#two-mac-cluster-experimental).

## MiMo V2.6 Flash on the pair

MiMo V2.6 Flash is granted by its qualification records (pipeline, run on an
M5 Ultra + M3 Ultra pair), on any pair the planner can place it on, at the
planner's cut and in either order. Each start hashes the 172 GB of weights with the file
cache off, so the hash does not fill the Mac's memory before the memory gate
decides; the gate itself is unchanged. Before each start, each Mac also clears
MiMo's files from macOS's file cache, and the load clears the cached pages of
the weight files it reads, so a Mac's share loads into free memory. Before
this, a start on two 128 GB Macs was refused every time: loading a share into
a cache full of MiMo made macOS compress other memory, and the gate then
counted no cache. Both Macs keep MiMo's prompt prefixes,
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
MiMo pair serves its owner's local API.

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

**For pair owners:** run `darkbloom update` on **both** Macs, then check that
`darkbloom --version` shows the same version on both. If either Mac ever ran a
plain `darkbloom start` before 0.10.8 (which meant single-Mac serving), run
`darkbloom stop --solo` on that Mac first.

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
   up again for <model>`. Until both Macs answer with the release, the leader
   checks again every 5 seconds. The other Mac does not start its part from
   the setup saved for the previous release, which names that release's files:
   it waits for the leader's setup, and its log says `this Mac runs Darkbloom
   v<version>, but its saved setup is for an earlier build: waiting for the
   other Mac's setup for v<version> (the old setup is not started)`.
5. The leader does this, and changes the pair's cluster approval, only once the
   other Mac has confirmed that it leads, or hasn't answered for 30 seconds:
   while one Mac restarts, the other may take the lead for a moment. Both steps
   stop the pair to start it again. When that stop fails (the other Mac doesn't
   answer, or refuses it), the pair stays started: the leader sets it up again
   10 minutes later, or checks the approval again a minute later. The log says
   `could not set the cluster up again after the update: <reason>` or `could not
   stop the parts to change the cluster approval: <reason>`. While the other Mac
   doesn't answer, the leader doesn't stop the pair to change its approval. A
   `darkbloom stop` you run meanwhile holds: neither step starts the pair again.

A pair still running a request after 120 seconds takes requests again and tries
at the next slot. A release that one Mac cannot download or verify is installed
on neither Mac; both try again at the next slot. A Mac whose check gets no
answer from the coordinator (3 tries of 15 seconds) asks once more 1 to 2
minutes later, within the same slot, while the other Mac waits; only when that
fails too do both Macs wait for the next slot. So a new release reaches the pair
at its next slot, up to 30 minutes after it is published, and each failed try
waits 30 minutes more; `darkbloom update` on both Macs updates at once. Until a new
release's cluster service has stayed healthy for 10 minutes, three of its starts
that end by themselves (a crash, an error, or a service that stops beating) bring
back the previous release and quarantine the new one, as the watchdog does for a
single Mac. A clean stop someone asks for is not one of them. A Mac never restarts into a new
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
its automatic updates are on. The command ends once this Mac's cluster service
runs the release (`This Mac's cluster service now runs v<version>; …`).
No log-out is needed. A cluster service started by an earlier release cannot do
this: log out and back in on both Macs once both have the release.
If single-Mac serving is also set up on a Mac whose pair is started (for example
from a plain `darkbloom start` before 0.10.8, which meant single-Mac serving),
`darkbloom update` restarts the pair and leaves single-Mac serving as it is. It
says so, with `darkbloom stop --solo` to remove it. The watchdog doesn't start it
again while the pair is started.

### When the two Macs run different versions

One Mac can end up on a newer release than the other: it updated alone through
single-Mac serving, `darkbloom update` ran on it only, or the other Mac was
asleep or off at the pair's update slot. Then:

- **The older Mac catches up within about a minute** (from 0.10.9), once its
  cluster service sees the other Mac running a newer release, or updating to
  one. It runs the pair's update at once instead of waiting for the slot: one
  immediate try per release, then the slots as before. It never installs a
  release it quarantined. With automatic updates off, its cluster service log
  says "the other Mac runs v<version>, newer than this Mac's v<version>, and
  automatic updates are off on this Mac: run `darkbloom update` on this Mac".
- **The provider's own background updater does not leave the pair split.** When
  it updates a Mac whose pair actually runs there, it also asks that Mac's
  cluster service to restart into the release together with the other Mac, as
  `darkbloom update` does, so the other Mac follows. The watchdog doesn't
  install a release while the pair runs on that Mac. A Mac that only serves
  alone, its pair gone, simply updates.
- **Both screens say it at once:** "✗ The two Macs run different Darkbloom
  versions: The other Mac (…) runs 0.10.7, this Mac runs 0.10.8.", then "On <the
  older Mac>, run `darkbloom update`; the pair starts once both Macs run
  <version>." The start doesn't wait or loop. It offers **Check the versions
  again** (it reads both versions again, and starts the pair once they match)
  or **Leave**. A Retry after any other failure checks the versions first. The
  version split is said before single-Mac serving when both apply.
- **`darkbloom status` and `darkbloom cluster status --json`** give the reason
  "the two Macs run different Darkbloom versions, <newer> and <older>: run
  `darkbloom update` on the Mac with <older>", and as `next` the Mac to update,
  named for each Mac: "On this Mac, run `darkbloom update`; …" or "On the other
  Mac (…), run `darkbloom update`; …".
- **The wait lines in the cluster service log name the other Mac's version:**
  the leader's "Darkbloom changed on …: waiting until both Macs answer with the
  same build …" and the other Mac's "waiting for the other Mac's setup for
  v<version> …" end with "; the other Mac runs v<version>, this Mac v<version>:
  run `darkbloom update` on <the older Mac>".

The other Mac's version comes from its cluster service, which publishes it from
0.10.7 on. If the other Mac publishes no version, check with `darkbloom --version`
on both Macs. DevNet builds say `darkbloom-dev`.

While a Mac serves, the re-plan uses the speed it measured while idle and never
runs a GPU benchmark beside the model
([device profile](../architecture/inference.md#automatic-local-cluster-batching)).
A pair that serves on the leader's local API, or a Mac that serves alone, is not
drained for an update yet: its update waits while it serves (the log says
`this Mac's part does not drain for an update`).

## When something is in the way

When a start's part keeps ending
because the link to the other Mac keeps closing, the ✗ says so and names the
other Mac's side ("the other Mac's worker ended or the cable dropped"): that
Mac's service restarts its worker without reporting it, so its line says what
can't be read from here instead of "running, no error". In the DevNet app, the
screens and `status` name its own command (`darkbloom-dev …`).

The mode chosen for the start ([tensor parallel or pipeline](#tensor-parallel-or-pipeline))
is the one that loads, for every model that runs both ways (GLM-5.3-Flash
included). Which Mac's
worker keeps ending is read from the leading Mac's incident log: a
`worker_crashed` carrying this Mac's own worker-exit record
(`worker-exit-v1 rank=<this Mac's rank>`) names this Mac, and one carrying what
the other Mac's link follower said (`rank <its rank> follower said: …`) names
the other Mac's side, as above. When neither (or both) is recorded, when that
log is missing or can't be read, or on the Mac that doesn't lead, the ✗ says it
can't tell which side closed the link and blames neither. When the
other Mac can't dial because macOS keeps it off the local network, the ✗ gives
that reason instead of "make sure it is on". A planned switch's stops (a part
that stopped, or ended with exit 0 and no reason) aren't shown as ends, also
while both Macs register with Darkbloom.

macOS's Local Network privacy can keep a Mac's link follower, the process that
dials the other Mac, off the cable even when the cluster service's own check
passed. The follower's own refusal decides:
- the joining Mac's window says "This Mac can't reach the other Mac over the
  cable: macOS keeps Darkbloom off the local network" and what to do there:
  System Settings → Privacy & Security → Local Network → turn on "Darkbloom".
  The DevNet app (Darkbloom Dev) is listed as "Darkbloom" too, because both
  apps share one bundle ID (`ClusterService.localNetworkRow`). Where macOS
  never recorded an answer for the app, the list has no such row: macOS asks
  on that Mac's own screen the next time the app dials over the cable, and
  someone must click Allow there. On a Mac with no display, do either through
  Screen Sharing;
- the leading Mac's ✗ says the same of the other Mac without waiting for the
  start to give up, once the leading Mac's part has run about 20 seconds (long
  enough for the follower to dial it again, so a setting just turned on shows
  first); a start run from the joining Mac's own window says it of that Mac.
  Its line for that Mac then says only that its part can't reach the local
  network, and a line too long for the ✗ is cut at a word, marked with "…";
- once the follower has connected, or a later dial failed another way, an
  earlier refusal no longer counts, and a part that has stopped counts as not
  blocked until its new follower dials;
- `darkbloom status` and `darkbloom cluster status` say the same on both Macs,
  by the same rule: `not_serving`, with the steps on the Mac that is kept off,
  instead of a load that never ends (the CLI reference quotes their words). On
  the leading Mac it starts about 20 seconds into its part and then holds while
  the other Mac stays refused, also while the leading Mac's part ends on the
  missing link and starts again;
- `darkbloom start` ends its wait with the same instruction, and says first
  when it replaces a cluster service running from a terminal session with the
  login agent.

Retry in the ✗ starts a stopped pair again, and q, Esc or Ctrl-C leave a
start's wait at once. While it waits, the joining Mac's window shows each state
of the leading Mac's start, and where to choose Retry when a part keeps ending.

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
  pairing: on that Mac, run `darkbloom cluster stop --service`, then `darkbloom cluster`.
- **A part keeps ending the same way**: after three identical ends the screen
  says it and offers **Save diagnostics for Darkbloom**; both Macs
  keep trying by themselves.
- **The leader cannot reach the other Mac**: make sure the other Mac is on and
  logged in; it rejoins by itself. During setup the leader offers **Try again**
  and **Cancel**, since the other Mac's Darkbloom prompt may still be waiting
  for Allow. If you denied the Local Network prompt there, turn on "Darkbloom"
  (the DevNet app's row has that name too) in System Settings → Privacy &
  Security → Local Network, then run `darkbloom cluster` again. When `darkbloom cluster` is run again and the
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
- **GLM-5.3-Flash on two 128 GB Macs**: it runs as a pipeline, about half the
  model on each Mac. If the plan names `darkbloom cluster gpu-limit` for a Mac
  whose GPU keeps too little resident, run it on that Mac (it asks once, then
  macOS asks an administrator), then `darkbloom cluster` again. The plan names
  it only on the Macs it runs on, Apple silicon Macs with 128 GB or more. Running it on
  both Macs leaves room for long requests. `darkbloom cluster gpu-limit --undo`
  takes it back. A request longer than what fits at that moment is refused, not
  run out of memory ([figures](../architecture/hardware-support.md#glm-53-flash-pairs-on-128-gb-macs)).
- **The start does not finish**: the screen shows each Mac's last error and
  offers **Save diagnostics for Darkbloom**, which writes a file to
  your home folder (no keys, addresses or names in it; nothing is written if any
  would remain).

## Stopping and starting again

Once the pair is set up, the everyday commands control it, on either Mac, as
they control single-Mac serving on one Mac
([CLI reference](cli-reference.md#darkbloom-cluster-status)):

| Command | On a Mac in the pair |
|---|---|
| `darkbloom stop` (or `darkbloom cluster stop`) | Stops serving on both Macs. They stay stopped after a restart, and both cluster services stay up, idle, so the next start needs no visit to the other Mac. It waits until both Macs' parts have ended and says so (`Memory freed on both Macs ✓`) |
| `darkbloom start` | Starts the pair, whatever its state, also after `darkbloom stop`: in a terminal, the same screen as `darkbloom cluster`; in a script, starts the saved model on both Macs and waits until it serves. A script's start on a pair that already serves keeps it (`…: the pair already serves.`, exit 0), while this Mac's cluster service starts at login; one that runs from a terminal session is moved to its login agent first. `darkbloom start --solo` serves this Mac alone instead: see [going back to serving on one Mac](#going-back-to-serving-on-one-mac) |
| `darkbloom restart` | Stops and starts the pair with its current model. While the pair doesn't run here, restarts single-Mac serving that runs here instead, and never starts the pair or single-Mac serving that was stopped |
| `darkbloom status` | The pair first (who leads, the model, whether it serves now and what to do), then this Mac's fields. When this Mac serves alone instead (`start --solo`), a line under the pair says so, and single-Mac serving's own lines follow. `darkbloom cluster status` gives the pair alone, with `--json` and exit codes |

Each says first that it acts on the pair, in words for what it does (`start`
in a terminal: what its screen does). `--solo` on any of them acts on
single-Mac serving on this Mac only and never touches the pair.

Single-Mac serving and the pair can't run on one Mac at once: both use the
Mac's one serving lock. If single-Mac serving runs on either Mac,
`darkbloom cluster` (or `darkbloom start` in a terminal) says so before it
starts anything, on one ✗ that names the Mac and the process: ``The pair can't
start: a single-Mac Darkbloom provider (process 9523) is serving on this Mac,
and the pair can't share a Mac with it.``, then ``On this Mac: run `darkbloom
stop --solo` to stop single-Mac serving there.``. It offers **Stop single-Mac
serving on both Macs and start the pair** (or on the one Mac named) and
**Leave**. It stops nothing unless you choose to, and it never retries by itself.
Each Mac's cluster service doesn't start its part while single-Mac serving
runs there. Its status names that provider, so the other Mac's screen says the
same thing instead of "no error reported". The Mac that joined shows the same
✗ in its own window, naming its own provider ("… is serving on this Mac"),
with `darkbloom stop --solo` and that the leading Mac's screen offers the stop.
It never says it is registering with the coordinator meanwhile, and it follows
the start by itself once single-Mac serving stops. The leading Mac's part
waits too: it doesn't start, and end again every half minute, while the other
Mac reports single-Mac serving. `darkbloom cluster status` says the block on
both Macs, with `Next:` ``Single-Mac serving doesn't stop by itself: run
`darkbloom stop --solo` on each Mac named, then `darkbloom start` on either
Mac. …``, and a scripted `darkbloom start` ends its wait at once with that
reason (exit status 3).

When nobody chose single-Mac serving since the pair was started on that Mac
(for example, the update from 0.10.8 restarted a job a plain `darkbloom start`
left set up, or a login or the watchdog started it), the Mac's cluster service
stops it by itself, as `darkbloom stop --solo` does. It writes that to its log,
and `darkbloom status` on that Mac says ``Single-Mac serving stepped aside for
the pair at <time> (process <N>): …``. It doesn't stop single-Mac serving you
chose yourself (`darkbloom start --solo`) until you start the pair from that
Mac, or the other Mac's screen offers the
stop and you accept. It never stops it while the pair isn't running there.
Parts that ended because single-Mac serving held the lock don't make the pair
fall back to local-only serving. Once the blocker is gone, the pair is offered
to Darkbloom again straight away. `darkbloom stop --solo` on the Mac without
single-Mac serving finds it on the other Mac and offers to stop it there
(`--yes` for scripts). Plain `darkbloom stop` on a paired
Mac stops the pair, not single-Mac serving. If the leading
Mac doesn't answer, `darkbloom stop` says so and that
`darkbloom cluster stop --local-only` stops this Mac alone.

## Going back to serving on one Mac

On a paired Mac, plain `darkbloom start` always starts the pair, in a terminal
or not, also after `darkbloom stop`. To stop clustering and serve each Mac on its
own again, stop the pair, then serve each Mac alone:

```bash
darkbloom stop            # on either Mac: stops the pair on both
darkbloom start --solo    # then on each Mac: serves that Mac alone
```

The pair "runs here" when this Mac's cluster service has heard from the other
Mac in the last 15 minutes and, since its start, the pair has served or is still
inside its first 15 minutes. While it runs here, `darkbloom start --solo` is
refused: this Mac's part holds the serving lock, so stop the pair first. When it
doesn't run here (it was stopped, or the other Mac is unplugged, off, or serving
on its own), `darkbloom start --solo` serves this Mac alone:

- It takes single-Mac options as on any Mac, for example `darkbloom start --solo
  --model <id>`. Without a terminal it asks nothing: one that names no models
  (`--model`, `--all`) says in one line to add them, before this Mac's part of
  the pair is touched. Without `--solo`, single-Mac options start nothing on a
  paired Mac, in every state of the pair: `darkbloom start --model <id>` in a
  terminal and `darkbloom autopilot enable` are refused by name (exit 64). The
  app's **Start serving** has no `--solo`, so it starts the pair, as a plain
  `darkbloom start` does, never this Mac alone. When it named another model
  than the pair's, it ends with ``This Mac serves in a pair: the pair serves
  <the pair's model>; `darkbloom cluster` changes its model.`` (``… the pair
  was asked to start with …, and isn't serving (above); …`` when it doesn't
  serve yet), and when it asked for a local API this Mac doesn't get from the
  pair (Darkbloom only, or the pair's API kept on the leading Mac),
  ``No local API was added on this Mac: …``. On the other Mac with the pair's
  API on every address, its relay gives it one, so the app never says that
  there; while that relay can't answer once the start is over (the other Mac
  away, Darkbloom not having the pair, its port held), it says `status`'s
  `Local API:` line. The app's onboarding offers
  **Start serving** there, never Autopilot, which serves one Mac and is refused
  on a paired Mac before it downloads anything. It says the pair as this Mac's
  own files tell it ("This Mac serves in a pair with …" only when it serves;
  "… which is stopped", "… that isn't running here", or, on the Mac that
  follows, "started with …", where the summary says Start serving "Makes sure
  the pair serves …" rather than that it starts it). A pair with no model yet gets no **Start
  serving**: the page says to choose its model with `darkbloom cluster` in
  Terminal on the leading Mac first, and so does the CLI (``No model was chosen for the pair yet: choose one with `darkbloom cluster` in a terminal on <the leading Mac>.``).
- A pair that is merely stopped gives one line: ``This Mac is in a two-Mac
  cluster with the other Mac (…), which is stopped: serving this Mac alone
  (`darkbloom start` starts the pair again).``
- A part of a started pair still running on this Mac is stopped first, and the
  pair's saved start on this Mac is cleared, so the part doesn't take this Mac's
  serving lock back at the next login. It says ``… which isn't running here:
  stopping this Mac's leftover part and clearing its saved start (`darkbloom
  start` starts the pair again).`` first, and ``This Mac's leftover part of the
  pair stopped, and its saved start is cleared: serving this Mac alone.`` only
  once that is done. The pairing stays: `darkbloom start` starts the pair again.
- While a cluster command runs on this Mac, it first waits for it (up to 10
  minutes; ^C stops waiting and leaves the pair as it is). One still running
  after 10 minutes stops and starts nothing, and says so.
- If that part doesn't stop within 5 minutes, nothing starts, and the command
  names the step that always works: `darkbloom cluster pair --status`, then
  `darkbloom cluster pair --forget <pin>`, then `darkbloom start`.

While the pair doesn't run here, `darkbloom stop` stops what runs on this Mac
(single-Mac serving, and a leftover part of the pair) and never asks the other
Mac, and `darkbloom restart` restarts single-Mac serving if it runs: with none
running it changes nothing and names `darkbloom start` (start the pair again)
and `darkbloom start --solo` (serve this Mac alone). `darkbloom update`
restarts single-Mac serving if this Mac has it. Before they serve this Mac
alone, `restart` and `update` stop a leftover part as `start --solo` does, with
the same lines. The watchdog brings single-Mac serving back if it stopped. While
the pair does run here, all of these act on the pair as above, and so do `stop`,
`restart` and `update` while the pair is started and the other Mac answers.

**A part doesn't hold a Mac forever.** When the other Mac hasn't answered for
15 minutes, this Mac's cluster service stops its part, which frees the serving
lock, and `darkbloom status` says ``The other Mac (…) hasn't answered for 15 min;
this Mac's part stopped. Run `darkbloom start --solo` to serve this Mac alone, or
`darkbloom start` to start the pair again.`` If single-Mac serving is set up on
this Mac, the watchdog starts it again. The part starts again by itself when the
other Mac answers. A reboot of the other Mac that takes a few minutes doesn't
stop the pair, and time a Mac spends asleep doesn't count toward the 15 minutes. When both Macs answer but the pair never served in its first 15
minutes (it may still be loading a large model), `darkbloom status` says so, but
nothing stops the part without you: only `darkbloom start --solo` serves this
Mac alone then. `restart`, `update` and the watchdog act on the pair as while it
runs.

**On the Mac that follows,** serving alone clears only that Mac's saved start.
While the leading Mac keeps the pair started, it may start this Mac's part again
once single-Mac serving stops here; `darkbloom start --solo` says so. To stop that, run
`darkbloom stop` on the leading Mac, which stops the pair.

**On 0.10.8.** These commands act on the pair there, and `start --solo` is
refused while the pair's start is saved. To serve one Mac alone on 0.10.8, leave
the pair on that Mac:

```bash
darkbloom cluster pair --status            # shows the other Mac's pin
darkbloom cluster pair --forget <pin>      # removes the pairing; the cluster service no longer starts at login
darkbloom start                            # single-Mac serving, as on any Mac
```

Plain `darkbloom stop` on 0.10.8 stops the pair, not single-Mac serving, so it
isn't the way back.

## Leaving the pair

To stop clustering for good, leave the pair on each Mac, in either order:

```bash
darkbloom cluster leave   # on each Mac; asks first (--yes for scripts)
darkbloom start           # then on each Mac: serves that Mac alone
```

`darkbloom cluster leave` says the pair in one sentence and what leaving does,
then asks `Leave the pair? [y/N]` (No by default; without a terminal it needs
`--yes`). It then takes the steps `darkbloom uninstall` takes for the pair:

1. **This Mac's part stops:** the pair stops on both Macs and this Mac's
   cluster service leaves login, as `darkbloom cluster stop --service`. When the
   other Mac doesn't answer, only this Mac's part stops
   (`cluster stop --local-only`), and the lines say so. They say only what
   stopped, never how to serve the pair again. A part that doesn't stop leaves
   the Mac paired, and the command says to try again.
2. **This Mac forgets its pairing,** as `darkbloom cluster pair --forget` and
   **Start over** do ([undo](#undo)). Run on the Mac that leads, it first
   tells the other Mac over the cable, which reclaims its pair cache and stops
   its part.
3. **It says what's next:** ``✓ This Mac left the pair. Nothing serves on this
   Mac now: `darkbloom start` serves it alone, or `darkbloom cluster` pairs it
   again.``, then what the stop did to the other Mac and that it keeps its
   pairing until you run `darkbloom cluster leave` there, then that to pair
   these two Macs again you run `darkbloom cluster` on each Mac, choosing
   **Start over** where it's offered.
   - "Stopped serving the pair too" is said only when the other Mac stopped.
     One that wasn't asked (the Mac that follows a pair that isn't serving, or
     a pair that couldn't stop together) "wasn't asked to stop".
   - One that didn't answer may have left the pair already, so the line says
     that, and that `darkbloom cluster leave` there unpairs it if it hasn't.

Until it leaves too, the other Mac still holds its pairing, and it can't tell
this Mac having left from this Mac being off:
- its `status`, `cluster status` and a `start`'s result say ``If the other Mac
  left the pair, `darkbloom cluster leave` here unpairs this Mac too.``, and no
  longer that `start` on either Mac starts the pair. They name no roles while
  this Mac doesn't answer: ``Cluster: this Mac (…) is paired with the other Mac
  (…), which isn't answering``, then ``■ Stopped; last model …`` with ``The
  other Mac (…) isn't answering over the cable.``;
- its `darkbloom cluster`, which a `start` in a terminal opens, no longer
  reaches this Mac. Its opening line names no roles either (``This Mac (…) ·
  the other Mac (…) isn't answering``), its status says the pair is stopped,
  as `cluster status` does, never that it serves alone, and it says ``If it
  left the pair, choose Start over to pair again, or Quit and run `darkbloom
  cluster leave` here.`` and offers **Start over**.

The models, single-Mac serving and the cable port setup stay on both Macs
(`darkbloom cluster link --remove` undoes the cable setup). Every line:
[CLI reference](./cli-reference.md#darkbloom-cluster-leave).

## Pairing again

Pair the Macs again after the official installer reinstalls Darkbloom ("Secure
Enclave ✓ (P-256 key generated)"), after either Mac moves between a local build
and the signed release, or when one Mac was reset or replaced. The DevNet app
keeps a pairing of its own: pairing it never changes the production app's, and
it is paired once on its own. Each app keeps its own
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
     `darkbloom cluster`. If it left the pair, choose Start over to pair again, or
     Quit and run `darkbloom cluster leave` here." Do that first: a Mac that was
     only asleep, logged out or stopped needs no new pairing. If it was reinstalled, unpaired, replaced or left the pair, use **Start over** here; the Mac that follows lists it after **Try again**. A
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
a pairing; **Pair again** and **Start over** in `darkbloom cluster`, and
`darkbloom cluster leave` ([leaving the pair](#leaving-the-pair)), take the
same steps (`ClusterUnpairing`). Run on the leader, it first tells the other Mac over the
cable, which removes the pair's prompt-cache records (its own single-Mac cache
stays) and stops its part; each Mac also removes its own pair records when it
unpairs. When the other Mac isn't reached, which it isn't once it left the pair,
the leader says ``The other Mac was not reached (…). If that Mac is still paired,
run `darkbloom cluster leave` there.``
`darkbloom cluster stop --service` stops a Mac's cluster service and keeps it
from starting at login. It stops the pair first, from either Mac. On the leader,
when the other Mac's service is already off or does not answer, this Mac's
service still stops, and the command says that the other Mac was not asked to
stop. When the other Mac is gone for good, `darkbloom cluster stop --local-only`
stops only this one, without asking it.
To take Darkbloom off a Mac altogether, see [Uninstall](#uninstall).

## Uninstall

`darkbloom uninstall` takes Darkbloom off one Mac of the pair. It offers
**Remove everything** or **Keep models**, and both do the same for the pair:

- this Mac stops its part, as `darkbloom cluster stop --service` does (the pair
  stops first, from either Mac), and no Darkbloom service starts at login any more;
- it forgets the pairing, as `darkbloom cluster pair --forget` (a leader tells
  the other Mac first, over the cable);
- it undoes the cable port setup, as `darkbloom cluster link --remove`: every
  Thunderbolt port Darkbloom set up (its records, and a "Darkbloom Cluster Link
  (enN)" service whose record is gone), under one macOS approval, never asking
  which port. On each port it removes Darkbloom's service first and only then
  puts the port back in its bridge, and it stops at the first command that
  fails. Where Darkbloom's service is the port's only one (a Mac whose
  Thunderbolt ports start in the Thunderbolt Bridge, such as a MacBook), macOS's
  `networksetup` refuses to remove it, so the service goes through macOS's
  network preferences instead (`scutil --prefs`, `ClusterLinkLastService`),
  checked first by its name and port; macOS then puts the port back in its
  saved bridge itself. Setting the port up again reconfigures an existing
  Darkbloom service in place instead of removing and remaking it. If that step fails after the pairing was forgotten, the summary says
  so, what is left, and the one command that finishes it: `darkbloom uninstall`
  again (the app and the cable records are kept for that).

**Keep models** keeps the models and the cluster model store, so after a
reinstall `darkbloom cluster` pairs again and uses them without copying or
downloading. **Remove everything** deletes them too, after asking once more. A
models folder you chose, and the cluster model store beside it, stay with either
choice. Run it as yourself, not with `sudo`. On a Mac with both the production
Darkbloom and Darkbloom Dev, uninstalling one removes only its own pairing,
cluster setup and cluster service, and keeps the cable port setup the other may
use.

When the other Mac does not answer, this Mac stops only its own part, as
`darkbloom cluster stop --local-only`. The other Mac keeps its own pairing, so
the command ends with one line about it, by name: run `darkbloom uninstall`
there too, or `darkbloom cluster` on it to pair it with another Mac. Every step
and path: [CLI reference](./cli-reference.md#darkbloom-uninstall).

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
