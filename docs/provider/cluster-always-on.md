# Keep a cluster member always on

> Last updated: 2026-11-08

`darkbloom cluster` on each Mac does all of this. Nothing below is needed: it
explains what the onboarding sets up and how to check it.

Each Mac of a cluster runs an ordinary background service, the way a solo
`darkbloom start` runs: it starts at login, waits for the Thunderbolt link,
restarts this Mac's part after a failure with backoff, and asks for macOS
permissions once.

The service prevents idle system sleep while a serving deployment is saved,
including while it waits for a peer, and until its child and relay stop. It
releases the assertions when serving stops or the service exits. This does not
override explicit sleep, shutdown, or closing a laptop lid on battery.
`ClusterServicePowerAssertions` owns these assertions on the supervision thread
in `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/`.

## The cluster service starts at login (`darkbloom cluster`)

The guided onboarding needs none of the steps below: `darkbloom cluster`, on
the leader and on every member, installs this Mac's cluster service (the
process that answers the paired Mac over the link and runs this Mac's part)
as a per-user LaunchAgent, so once each Mac is logged in again after a reboot
the cluster comes back by itself, with no command run on either Mac (see
[After a restart or a power cut](#after-a-restart-or-a-power-cut)).

- launchd runs `darkbloom cluster service --supervise`: the same supervisor as
  below, around `darkbloom cluster service`. A service
  that ends is restarted after 15 s, doubling to 300 s; three runs in a row each
  shorter than 120 s park it (nothing runs) until `darkbloom cluster` is run
  again, which restarts it and resets the budget.
- The supervisor updates Darkbloom on this Mac together with the other Mac
  ([the pair's coordinated update](#the-pairs-coordinated-update)). This Mac's
  part runs no updater of its own
  (`provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift` starts
  `startAutoUpdateMonitor` only for a single-Mac provider), and the single-Mac
  provider does not run beside the cluster.
- `RunAtLoad`, and `KeepAlive` only after an unsuccessful exit (throttled to
  the budget's first backoff): launchd brings back a supervisor that crashed,
  never one that was stopped.
- The label is `io.darkbloom.cluster-service.<12 hex digits>`, a digest of the
  installed app (`Darkbloom.app`, whether `darkbloom` runs from
  `Contents/MacOS`, `Contents/Helpers` or the `~/.darkbloom/bin` symlink) or of
  the folder of a development build. The DevNet app's is
  `io.darkbloom.cluster-service.dev.<12 hex digits>`
  (`BuildEnvironment.clusterServiceLabelPrefix`). One cluster service runs per
  user and app: a newer install of the same app replaces the older one's
  agent, and neither app starts, stops or removes the other's
  (`ClusterServiceAgentPlan.isOwnAgent`).
- The job's `AssociatedBundleIdentifiers` names the actual enclosing app from
  its `Info.plist`. macOS attributes Local Network access to that app after the
  setup terminal exits; the supervisor, service and follower use its approval.
  An older job without this association is replaced once by the normal CLI.
- Running `darkbloom cluster` again is idempotent: an unchanged, running
  agent is left alone; a changed one (another binary or options) is replaced;
  a parked one is restarted. A service an earlier version started from a
  terminal is stopped (SIGTERM, then it releases its part) and replaced by the
  agent.
- Nothing is asked: a per-user agent needs no administrator approval. macOS
  shows its "Background item added" notice once, as for the provider's own
  agent. The cluster link's one administrator approval stays the only
  administrator approval. One macOS privacy decision remains, as for every
  launchd-started member (see [permissions](#permissions-asked-once)): a
  service started by launchd no longer runs under the terminal's Local Network
  approval, so the signed release asks once per Mac ("find and connect to
  devices on your local network") the first time the service uses the link;
  the app must retain its signing identity across updates. A development build
  without that identity uses a session-only fallback. Keep its originating
  Terminal or SSH session open: detaching does not preserve that session's
  Local Network access. Use a signed app for background qualification.
- `darkbloom cluster stop --service` (from either Mac, the pair stops serving first)
  and unpairing (`darkbloom cluster pair --forget`, once no pairing is left)
  remove the agent; the service stops this Mac's part first (SIGTERM, up to
  300 s for a rank to release its model; launchd's exit allowance is 360 s).
- `darkbloom status` shows it, for example
  `Cluster service: running; starts at login (launchd io.darkbloom.cluster-service.0123456789ab)`
  and `  supervisor: running; member pid 1234 up 310 s; runs 1, quick failures 0/3, guard teardowns 0/6`.
- Logs: `~/.darkbloom/cluster-setup/service.log` (`cluster service supervisor:`
  and `cluster service:` lines); this Mac's part logs to `rank.log` beside it.


### Check after a reboot (owner)

1. Pair and serve once with `darkbloom cluster` on both Macs (the leader picks
   the model). On each Mac, `darkbloom status` shows
   `Cluster service: running; starts at login`.
2. Restart both Macs (any order). Log in to the desktop on each (or use
   automatic login); do not run any `darkbloom` command.
3. Within a few minutes of both being logged in: `darkbloom status` on each Mac
   shows the service running with `runs 1`; on the leader,
   `darkbloom cluster` shows the cluster serving the same model, and its
   test request answers.
4. Note any macOS prompt or notice that appeared after the restart (expected:
   none; the "Background item added" notice appears only at install).
5. To leave it off: `darkbloom cluster stop --service` on each Mac; after a further
   restart, `darkbloom status` shows no cluster service line except
   `not running and not set to start at login` on a paired Mac.


### After a restart or a power cut

The cluster service is a login agent: it needs the logged-in session for its
keys and attestation, so it starts when the Mac is logged in. `darkbloom cluster`
says which applies to each Mac, from its own settings:

- Automatic login on: "After a restart or power cut, this Mac comes back by
  itself and serves again (automatic login is on)."
- FileVault on: "After a restart or power cut, this Mac serves again once
  someone logs in (FileVault keeps the disk locked until then)."
- Otherwise: "After a restart or power cut, this Mac serves again once someone
  logs in. To make it automatic, turn on automatic login (System Settings →
  Users & Groups; needs FileVault off)."

Darkbloom does not switch to a system daemon for this: with FileVault on, the
disk stays locked until someone logs in, so a daemon would not help.

### The pair's coordinated update

Each Mac's cluster service supervisor runs the single-Mac updater's sequence
(`AutoUpdateController`) for the pair, with the single-Mac gate: `auto_update`,
`DARKBLOOM_NO_UPDATE_CHECK` and the configured coordinator, read when the
supervisor starts (`Watchdog.settings`,
`provider-swift/Sources/darkbloom/ClusterServiceCommand.swift`,
`supervisorConfiguration`). One cycle
(`provider-swift/Sources/ProviderCore/Update/ClusterPairUpdateCycle.swift`,
`ClusterPairUpdateCycle`) runs beside the serving cluster service:

| Step | Single Mac | Pair (both Macs) |
|---|---|---|
| When | 5 min after start, then every 30 min | Every 30 min at the update slot of the pairing's cluster ID (`ClusterMemberUpdateSlot`), the same moment on both Macs; or at once for `darkbloom update` |
| Check, download, verify, stage | While serving (`SelfUpdater`). The check makes up to 3 tries of 15 s | The same, on each Mac, while the pair serves. At the slot or catching up with the other Mac, a check without an answer makes a second round 60–120 s later (`ReleaseCheck.pairCycle`, `ClusterPairUpdateCycle.Environment.live(automatic:)`); the other Mac waits for its fresh `checking` |
| Stop taking requests | Once staged | Once staged on both Macs (each reads the other's progress, `ClusterPairUpdateProgress`, from the other cluster service's status over the link) |
| Drain | Accepted requests finish, at most 120 s; never cancelled | The part that serves the pair (rank 0) finishes its accepted requests, at most 120 s (`ClusterUpdateDrainRequest`, through its lifecycle mailbox); the other part serves none. A request still running reopens the pair on both Macs and defers to the next slot |
| Install | Commit the staged bundle | Each Mac commits once both drained |
| Restart | launchd restarts the provider | The supervisor stops its cluster service (the drained part stops with it), checks that the installed binary starts, and starts again from it |
| Recovery | The watchdog promotes the candidate after 600 s of fresh heartbeats, rolls back after 3 failed starts | A binary that fails the start check is never restarted into: the supervisor restores the previous release and quarantines the new one at once, and starts its cluster service again. Otherwise the restarted supervisor does what the watchdog does, with its cluster service's heartbeat (`ClusterCandidateRecovery`), on an update record checked against the installed app ([an install outside the updater](#an-install-outside-the-updater)) |

The rules each Mac applies to the other's progress are in
`provider-swift/Sources/ProviderCore/Service/ClusterSupervision/ClusterPairUpdate.swift`
(`ClusterPairUpdate.partnerState`), and those for its own part in
`ClusterPairUpdateCycle`:

1. Neither Mac stops taking requests before both have the release on disk, and
   neither installs before both drained, so a release one Mac cannot download,
   verify or stage is installed on neither; both retry at the next slot.
2. The drain never cancels an accepted request and sends no drain barrier: a
   drain the pair gives up reopens admission on the same coordinator connection.
   The stop that follows a completed drain acknowledges it as every stop does.
3. A Mac whose partner cannot be asked (no answer, a build without this
   progress, or a progress not rewritten for
   `ClusterPairUpdate.progressStaleSeconds`) goes on alone only when no cluster
   worker runs on it, checked again before it installs, so it never breaks a
   serving pair; with a pair loaded it waits, then defers.
4. Only the coordinator-paired part answers the drain
   (`ProviderLoopConfig.clusterMemberAnswersUpdateDrain`). A part that serves
   otherwise (the leader's local API server, a Mac serving alone) does not, so
   the update defers while it serves. A service whose status says so
   (`localOnly`, a solo part) gives the release up before downloading it.
5. A Mac whose partner has automatic updates off gives the slot's release up
   before downloading it. A Mac with automatic updates off reports `disabled`
   whenever no cycle runs on it, except for the minute after a cycle that
   `darkbloom update` asked for ended. A cycle for `darkbloom update` instead
   waits, while serving, for the other Mac's `darkbloom update`, at most
   `ClusterPairUpdate.partnerStageWaitSeconds` (900 s) from its start.

The supervisor restarts by replacing itself with the installed binary
(`execv`). Unlike a single Mac's watchdog, no other process outlives that
restart to roll a release back, so the supervisor first runs the binary once as
its child (the start check, `ClusterCandidateRecovery.startCheckFailure`):
`darkbloom --version` must exit 0 within
`ClusterCandidateRecovery.startCheckTimeoutSeconds` (30 s) and print the
release's version. This loads the binary as the restart would: the dynamic
loader and the frameworks it links, its code signature and the argument parser.
A binary that fails is not restarted into. The supervisor counts one failed
start, restores the verified predecessor and quarantines the release at once
(`ClusterCandidateRecovery.recordFailedStartCheck`), and starts the cluster
service again from the restored binary. The other Mac follows that rollback
([a rollback on one Mac](#a-rollback-on-one-mac)). A rollback after three
failed starts checks the restored predecessor the same way; if that check fails
too, the supervisor starts the cluster service itself instead of restarting
into it. A binary that passes the check but whose supervisor fails before it
starts the cluster service is still not rolled back.

### An install outside the updater

The update record (`~/.darkbloom/recovery/state.json`, `UpdateRecoveryState`)
names the installed release, a release installed but not yet promoted, and the
release kept for rollback. Only the updater writes it: `install.sh` and a copied
app replace `Darkbloom.app` and leave it naming releases that are gone. Before
each start of the cluster service, and before an end of it counts toward a
rollback, the supervisor checks the record against the installed app under the
update lease (`ClusterCandidateRecovery`, `noteLaunch` and `recordFailedStart`;
`provider-swift/Sources/ProviderCore/Update/UpdateRecoveryStore.swift`,
`reconcileWithInstalledApp`). A release's version is the one its signed
`Info.plist` names (`CFBundleShortVersionString`); an app that names none counts
as the release the supervisor runs.

| The record | What the check does |
|---|---|
| Names the installed app: the hashes the updater recorded and its version | Nothing |
| Names another release: the installed app's signed version or hashes differ | Records the installed app as the installed release, drops the pending release without counting a failed start, and removes the rollback copy |
| Names the installed app, but the app cannot be read (a file it needs is missing or unreadable) | Nothing: failed starts still count, and the third restores the verified copy |
| Keeps a rollback copy recorded as another release than its app names | Records the copy as the release its app names, when its files are the recorded ones and its signature holds (`verifyPredecessor`); otherwise removes it |
| Keeps a rollback copy whose app names no version | Removes the copy |

A pair forms only between Macs on the same build
(`ClusterConfiguration.peerBuildDiffers`). A rollback restores the release this
Mac ran before the installed one, recorded as the version its app names, and
the pair forms again once the other Mac, which keeps the same release, follows
([a rollback on one Mac](#a-rollback-on-one-mac)). A copy that an earlier
updater recorded under a stale label is still that release, so it is relabelled
and kept. A copy kept for an install that is gone is not, so it is removed, and
nothing is rolled back until an update keeps a copy of the installed release.
The supervisor logs
one line, for example `cluster update: v0.10.7 is installed, but the update
record said v0.9.22 with v0.10.6 pending (installed outside the updater): it now
records v0.10.7, v0.10.6 is no longer pending and the rollback copy (recorded as
v0.9.22) is removed; nothing is rolled back until an update keeps a copy of
v0.10.7`. A relabelled copy logs `cluster update: the rollback copy recorded as
v0.10.6 is a v0.10.7 app: it is now recorded as v0.10.7 and kept for rollback`.
A record it cannot check otherwise (an unreadable record) counts no start
toward a rollback.

Two rules keep an update from acting on such a record too:

- The release that runs is never an update target. A pending release older
  than it is not pending, and a release is offered only when it is newer than
  both the running and the installed release (`SelfUpdater.checkForUpdate`).
- An update over an app installed outside the updater keeps a copy of that app,
  also when the record names a pending release that is not installed, and
  records the copy as the release the app's `Info.plist` names
  (`UpdateRecoveryStore`, `preparePredecessor`).

### A rollback on one Mac

When one Mac of a pair rolls a release back, the other Mac rolls back to the
same earlier release, and the pair serves that release together. This answers
the question the coordinated update left open: before, the pair stayed split
(each Mac on another release, so the leader never planned it again) until a
newer release updated both Macs.

A rollback is any of: three failed starts of the release's cluster service, a
failed start check, or `darkbloom update --rollback` run while the Mac's
cluster service was stopped. Each restores the verified predecessor and
quarantines the release on that Mac. The Mac's progress then reports the
quarantined release beside the version it runs
(`ClusterPairUpdateProgress.quarantined`), and the other Mac reads it over the
link with the rest of the progress.

The other Mac's supervisor checks for a rollback to follow at its start and
then every `ClusterPairUpdate.followCheckSeconds` (60 s) while no update cycle
runs, also with automatic updates off: the release it restores is one the Mac
ran before. It follows (`ClusterPairUpdateCycle.followRollback`) when the other
Mac quarantined the release this Mac runs (installed or promoted) and runs the
release this Mac keeps for rollback. The check reads both Macs' recovery state
without the update lease; only a Mac that runs the quarantined release and keeps
the other Mac's release for rollback takes the lease and verifies it. The follow is the update cycle's sequence
with a rollback in place of the install:

1. It takes the update lease, the one every update cycle, candidate recovery
   and `darkbloom update --rollback` take, and decides again under it. Another
   holder (this Mac's own cycle, still installing or restarting) makes it wait
   for the next check, with nothing changed.
2. It waits until the other Mac reports the earlier release (it does already,
   so this is at once), then drains this Mac's part as for an update. An other
   Mac that stops answering is waited for at most
   `ClusterPairUpdate.progressStaleSeconds` (60 s) while a pair runs on this
   Mac. The follow is then deferred with the reason `the other Mac did not
   confirm it runs v<version> within 60 s`, nothing is changed, and it is tried
   again at the pair's next update slot, as a deferred update is. With no pair
   running on this Mac, it follows alone, as an update goes on alone.
3. It restores the verified predecessor and quarantines the release
   (`SelfUpdater.rollBackToPredecessor`), with the reason `the other Mac of the
   pair rolled v<release> back to v<previous>; this Mac followed`. Both Macs
   now keep the release quarantined: neither's update slot installs it again,
   and a Mac whose partner reports the release quarantined gives it up too
   (`ClusterPairUpdate.partnerState`). The next newer release updates both.
4. The supervisor restarts the cluster service from the restored binary, after
   the same start check as for an update. Once both Macs answer with the same
   build, the leader plans the model again.

It does not follow, changes nothing, and says why once in its log
(`cluster update: not following the other Mac's rollback: <reason>`) when:

- it keeps another release for rollback, or none: the pair serves again once a
  newer release updates both Macs;
- its part does not drain for an update (it serves on the leader's local API,
  or alone): it follows once its part can drain.

The Mac that rolled back says once `cluster update: the other Mac still runs
v<release>, which is quarantined on this Mac` while the other Mac has not
followed, or has installed the release again on purpose. Other lines:
`cluster update: the other Mac rolled v<release> back to v<previous> and
quarantined it; this Mac follows to v<previous>` and `cluster update: restored
v<previous> and quarantined v<release>, as on the other Mac`.

To install a release both Macs quarantined anyway, run `darkbloom update
--override-quarantine` on both Macs: the cycle the first command starts waits,
while serving, for the other Mac's, as for `darkbloom update` with automatic
updates off. An update slot, by contrast, gives up a release the other Mac
reports quarantined. Right after an override, the other Mac may still read the
old quarantine for up to a minute and follow it.

Both Macs need a build that follows rollbacks. The quarantine is reported by
the Mac that rolled back after the rollback, so by the restored release's
binary: a rollback *to* a release without this behaviour is not reported, and
the other Mac does not follow it. The first release with this behaviour is
therefore not followed when it is itself rolled back; rollbacks from the
release after it on are. The other Mac must run a build with the follow too.

A cluster-member provider service (`darkbloom start --cluster-member
--always-on`) does not run this coordinated update and does not follow a
rollback: roll back both Macs.

After both Macs restarted, the leader's cluster service plans the same model
again once both answer with the same worker build
(`ClusterOnboardingUpdate.oneBuild`), and the pair registers again under the
new release's cluster approval. Each step is one `cluster update:` line in
`~/.darkbloom/cluster-setup/service.log`, for example `cluster update: waiting
for the other Mac to have v<version>`, `cluster update: this Mac's part finished
its accepted requests`, `cluster update: installed v<version>`, `cluster update
deferred: <reason>; no request was cancelled; the next update slot tries again`,
`cluster update: v<version> failed its start check (<reason>), so the supervisor
does not restart into it; restored v<previous> and quarantined v<version>`,
`cluster update: starting the cluster service on candidate v<version>` and
`cluster update: this Mac's part serves again on v<version>`.

Planning again and registering again both act only once the other Mac has
confirmed the leader's claim, or hasn't answered for the lease's 30 s
(`ClusterControlNode.leadershipConfirmed`): the two Macs restart seconds apart,
and the one that comes back first may take control after the lease's 30 s, so a
restarted leader's saved claim may be superseded. Both stop the pair
(`OnboardingLive.localStop`, which clears the pair's saved start first) only to
start it again
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterService+RestartingStop.swift`):
when the stop fails, the saved start is put back and the stop request it left
is dropped, so the next check tries again. The log says `could not set the
cluster up again after the update: <reason>` or `could not stop the parts to
change the cluster approval: <reason>`, followed by `The pair stays started`.
While the other Mac doesn't answer its status, a change of approval that would
stop a serving pair waits: every change is sent to the other Mac. The
coordinator is still asked at each check.

An owner's stop is never undone by either step. Every stop of the pair takes
the control command lock: `darkbloom cluster stop`, `darkbloom stop` (also on a
Mac where the pair doesn't run and the other Mac doesn't answer) and
`darkbloom start --solo`, which wait up to 10 minutes for a cluster command that
runs. A step that waited for the lock goes on only while the pair's start is
still saved.

## Permissions asked once

One administrator approval sets up the cluster link per Mac; macOS then decides
two permissions per program identity, which a release meets with no further
system setting:

| Permission | Why the member needs it | What makes it once |
|---|---|---|
| Local Network privacy | The follower dials the leader over the Thunderbolt link (a local network address). A member started by hand in a shell runs under that shell's approval, which is why it works there while the same binary started by launchd is refused (`Local network prohibited`) until Darkbloom itself is approved. | The LaunchAgent runs the executable inside `Darkbloom.app` (the recorded path is the resolved one, not the `~/.darkbloom/bin` symlink); the app carries `CFBundleIdentifier` `io.darkbloom.provider` and `NSLocalNetworkUsageDescription`, and is Developer-ID signed, notarized and stapled. The approval follows that signed identity, so updates keep it. The owner and worker processes the member starts inherit it. No configuration profile can pre-approve Local Network, so one click per Mac is the minimum. |
| Cluster link setup (administrator approval) | The cable port needs Darkbloom's own link service for RDMA. | Done once per Mac with the onboarding's one macOS approval. macOS keeps the service through reboots and updates; the supervisor only waits for it at boot and never changes it. |
| Application firewall (when on) | A rank that listens: by default only the leader (rank 0) listens; a follower only dials out. | With **Automatically allow downloaded signed software** on (the macOS default), any Developer-ID-signed program may accept connections without an alert. The release signs the main executable and the cluster worker and placement tool it ships in `Contents/Helpers`, under their own identifiers. An ad-hoc build is not covered and raises one alert per new build. |

The release workflow (`.github/workflows/release-swift.yml`) writes the usage
string, checks it after signing, and signs the cluster helpers with
`provider-swift/entitlements-cluster-worker.plist` when the unsigned artifact
carries them.

Which processes open sockets on the link decides what needs the approvals:

- The provider process (`Darkbloom.app/Contents/MacOS/darkbloom`): the
  leader's link listener, the follower's dial, the coordinator connection.
- The cluster worker, only with the direct JACCL bootstrap: rank 0's worker
  listens on the JACCL coordinator port and rank 1's worker dials it. With the
  bootstrap carried over the authenticated link channel, the worker opens no
  socket at all (its RDMA traffic is not a socket). Either way the worker is
  started by the member, so it inherits the member's Local Network approval.

The release ships `darkbloom-cluster-worker` and the placement tool
`darkbloom-cluster-plan` inside `Darkbloom.app/Contents/Helpers`, with the
`mlx.metallib` (the same bytes as `Contents/MacOS/mlx.metallib`) and
`pagedattention.metal` they load beside themselves. The release build makes
them with `scripts/build-cluster-helpers.sh` (the worker package's native
build: macOS 26.2, real JACCL, the source-matched metallib), the packaging
check (`provider-signing-validation.py cluster-helpers`) refuses an app without
them before and after signing, and `scripts/sign-cluster-helpers.sh` signs
them under their own Developer ID identifiers. A setup that names no worker
uses `Contents/Helpers/darkbloom-cluster-worker` of the app `darkbloom` runs
from (a development build keeps `worker/` beside `darkbloom`). A worker
outside the bundle is not Developer-ID signed: on a Mac whose rank listens
with the firewall on, it can raise a firewall alert per build when it opens
the JACCL coordinator socket.


## Owner steps not automated

These need the owner at the Mac or an owner decision; Darkbloom changes no
system setting:

1. Approve the Local Network alert once on each Mac. If it was dismissed:
   **System Settings → Privacy & Security → Local Network**, turn on
   **Darkbloom**, then run `darkbloom cluster` again.
2. Unattended reboots: the service starts only when the user's session starts.
   For a Mac to return to serving after a power cut with nobody there, it must
   log in automatically (**System Settings → Users & Groups → Automatically log
   in as**), which macOS offers only with FileVault off. Otherwise serving
   resumes when the owner logs in; `darkbloom cluster` says which applies.
3. If the firewall is set to **Block all incoming connections**, a listening
   rank cannot work; allow Darkbloom under **Firewall → Options**.
4. Reboot test, after the first approval: reboot both Macs, log in, and check
   that `darkbloom cluster` shows the cluster serving with no alert on either Mac.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Supervisor `parked` (`exhausted`) | The last three `member ended` lines in the provider log | Fix the cause, then `darkbloom restart` (a new supervisor starts with a fresh budget) |
| Supervisor `waitingForLink` | `darkbloom cluster link` | Connect the cable, or follow the printed fix |
| Follower never connects; log shows `Local network prohibited` | **Privacy & Security → Local Network** | Turn on Darkbloom; an ad-hoc build needs this per build |
| A firewall alert after an update | `codesign -dv` on the listening binary | The binary is not Developer-ID signed; install the release build |
| Install or provider log says `permissions: not asked once` | The listed reasons | Install the signed release (a locally built binary is ad-hoc signed and outside `Darkbloom.app`) |
| The pair does not update | `cluster update:` lines in `~/.darkbloom/cluster-setup/service.log` on both Macs | `automatic updates are off`: run `darkbloom update` on both Macs, or set `auto_update` on both (`darkbloom autoupdate enable`), which takes effect when the cluster service next starts (at login, or after its next update). `deferred`: a request ran past 120 s, or one Mac could not take the release; the next slot tries again. `does not drain for an update`: the pair serves on the local API or a Mac serves alone. `failed its start check`: the release did not start on this Mac, which keeps its previous release and does not install that release again; the other Mac follows it back ([a rollback on one Mac](#a-rollback-on-one-mac)), and a newer release updates both. `not following the other Mac's rollback` or `the other Mac still runs`: see [a rollback on one Mac](#a-rollback-on-one-mac) |

## Developer: a coordinator-paired member as a service

Nothing in this section is part of the user path; `darkbloom cluster` replaces
it. It documents the developer route that runs `darkbloom start
--cluster-member` under the provider's own LaunchAgent.

### Prerequisites

- A saved coordinator-paired setup on each Mac
  ([coordinator-paired member](../reference/configuration.md#coordinator-paired-member)).
  `darkbloom start --cluster-member` must already work in the foreground.
- The cluster link set up once on each Mac (the onboarding's one macOS
  approval): the Thunderbolt port gets Darkbloom's own link service with its
  own IPv4 address, which RDMA needs (JACCL refuses a port without an
  IPv4-mapped GID). macOS keeps that service across reboots and updates;
  `darkbloom cluster link` reports `ready` when it is done.
- The signed, notarized Darkbloom release installed by the installer
  ([installation](installation.md)). A locally built binary works, but macOS
  treats every new ad-hoc build as a new program and asks again (see
  [permissions](#permissions-asked-once)).
- Both Macs signed in to the same account and logged in to a desktop session
  (the service is a per-user LaunchAgent, like the solo provider).

### Steps

1. On each Mac, install the member as a service:

   ```bash
   darkbloom start --cluster-member --always-on
   ```

   This replaces any running provider service on that Mac (after a drain) with
   the provider LaunchAgent (`io.darkbloom.provider`) and arms the watchdog
   (`io.darkbloom.watchdog`). launchd runs `darkbloom start --cluster-member
   --supervise`, the supervisor, which runs the member.
   The command ends with a **Permissions** line: either macOS will ask once,
   or the reasons it will not (an ad-hoc build, an executable outside
   `Darkbloom.app`, a release without the Local Network usage string).
   Run it in Terminal on that Mac's own screen, so you are there when macOS asks.
2. The first time the member reaches the link, macOS shows
   **"Darkbloom" would like to find and connect to devices on your local
   network**. Click **Allow** on each Mac where it appears. This is the only
   permission step; it is not repeated after restarts, reboots or updates.
3. Wait for the pair: the coordinator forms it once both members have
   registered.

### Verify

- `darkbloom status` on each Mac prints a line such as
  `cluster member supervisor: running; member pid 1234 up 310 s; runs 1, quick failures 0/3, guard teardowns 0/6`.
- `~/.darkbloom/provider.log` shows `cluster-member supervisor:` lines: the
  permissions verdict (`permissions: asked once (...)`), the link wait, each
  member start, and the reason and wait of every restart.
- The coordinator lists the pair as serving.


### What the supervisor does

| Situation | Behaviour |
|---|---|
| Boot, port not ready | Waits for this Mac's cluster port before the member registers: port active, its own IPv4 address, and the IPv4-mapped GID that RDMA needs published (rechecks every 5 s; RDMA off or absent: every 60 s with the fix in the log) |
| Coordinator unreachable at boot or restarting | The member keeps reconnecting; this is not counted as a failure |
| Member exits or is killed (anything the supervisor did not ask for, a clean exit included) | Restarts it after 15 s, doubling to 300 s; a run of 120 s or more resets the wait |
| Three runs in a row each shorter than 120 s | Stops restarting and parks, holding no memory, until `darkbloom restart` |
| JACCL guard teardown (exit 75) | Restarts without counting a startup failure; six inside 120 s mean the link is flapping and it parks |
| The other Darkbloom app holds this Mac's GPU, or (DevNet) production serves here: the member exits 76 | Waits without counting anything, says why once in the log and the status (`backoff`), and starts the member as soon as the hold ends (a hold already over: after 15 s) |
| Member alive but its heartbeat is 75 s old (after a 180 s start grace) | Asks it to stop (SIGTERM), then restarts it; SIGKILL only if it ignored SIGTERM for 300 s |
| The leader's pair engine stays wedged (its own watchdog's verdict) for 180 s | Same recycle |
| An active request made no progress at all for `clamp(120, 120 + prompt tokens / 1000, 900)` s (when the member reports one) | Same recycle |
| A pair forms | The leader runs one greedy 8-token warmup request before the pair accepts work; if it fails or takes over 300 s the pair is retired and formed again (`DARKBLOOM_CLUSTER_WARMUP=0` turns this off) |
| Cluster update slot (every 30 min, at an offset fixed by the cluster ID, the same on both Macs), with `auto_update` on (the default) | On this route, if a release is available and the pair is idle: drains the member, installs, restarts from the new binary. The cluster service of `darkbloom cluster` runs [the pair's coordinated update](#the-pairs-coordinated-update) instead |
| `darkbloom stop` | Drains, stops the member and keeps it stopped across reboots |
| Before every run, and at the member's own start and end | Orphan sweep: a worker or owner whose parent is gone is given its own contract to end, then SIGTERM, SIGKILL only after the kill margin; a stranded device journal is cleared once nothing it names runs; bootstrap directories whose socket no process holds any more are removed (read from the descriptor tables; nothing connects). One log line when it found something (`darkbloom cluster reap --json` runs the same sweep by hand) |

The policies are ported from the owner's ThunderMLX restart loop and live in
`provider-swift/Sources/ProviderCore/Service/ClusterSupervision/`; the process
is `provider-swift/Sources/darkbloom/ClusterMemberSupervisor.swift`. After a
stop, `darkbloom cluster verify-teardown --json` says whether anything is left on
this Mac (processes, wired memory against a baseline, the journal, bootstrap
directories) and exits 1 when it is not clean; `darkbloom cluster cancel-all`
force-cancels every request served on this Mac without the leader or SSH.


### Signing and the release check (owner identity)

1. Signing and notarization (owner identity): the release workflow signs the
   cluster helpers with `scripts/sign-cluster-helpers.sh` (Developer ID
   certificate from the release secrets), then the app, and notarizes it. To
   sign a locally packaged app the same way, run
   `scripts/sign-cluster-helpers.sh <Darkbloom.app> <keychain> "<Developer ID
   Application identity>" <team id> provider-swift/entitlements-cluster-worker.plist`
   before signing the app; no agent holds or uses the identity.
2. Release check, once per Mac with someone at the screen: install the signed
   release, `darkbloom start --cluster-member --always-on`, answer the one
   Local Network alert, then reboot, restart the member 20 times and update to
   a second signed build: no further alert.
3. Check the installed identity on each Mac:
   `codesign -dv --verbose=2 ~/.darkbloom/Darkbloom.app` (authority
   `Developer ID Application`), `spctl -a -vv ~/.darkbloom/Darkbloom.app`
   (accepted, notarized) and
   `plutil -extract NSLocalNetworkUsageDescription raw ~/.darkbloom/Darkbloom.app/Contents/Info.plist`.
