# Keep a cluster member always on

> Last updated: 2026-10-20

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
  below, around `darkbloom cluster service`. A service that ends is restarted
  after 15 s, doubling to 300 s; three runs in a row each shorter than 120 s
  park it (nothing runs) until `darkbloom cluster` is run again, which
  restarts it and resets the budget.
- `RunAtLoad`, and `KeepAlive` only after an unsuccessful exit (throttled to
  the budget's first backoff): launchd brings back a supervisor that crashed,
  never one that was stopped.
- The label is `io.darkbloom.cluster-service.<12 hex digits>`, a digest of the
  installed app (`Darkbloom.app`, whether `darkbloom` runs from
  `Contents/MacOS`, `Contents/Helpers` or the `~/.darkbloom/bin` symlink) or of
  the folder of a development build. One cluster service runs per user: a
  newer install's agent replaces an older one's.
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
- `darkbloom cluster stop` (on the leader, the cluster stops serving first)
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
5. To leave it off: `darkbloom cluster stop` on each Mac; after a further
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
| Member alive but its heartbeat is 75 s old (after a 180 s start grace) | Asks it to stop (SIGTERM), then restarts it; SIGKILL only if it ignored SIGTERM for 300 s |
| The leader's pair engine stays wedged (its own watchdog's verdict) for 180 s | Same recycle |
| An active request made no progress at all for `clamp(120, 120 + prompt tokens / 1000, 900)` s (when the member reports one) | Same recycle |
| A pair forms | The leader runs one greedy 8-token warmup request before the pair accepts work; if it fails or takes over 300 s the pair is retired and formed again (`DARKBLOOM_CLUSTER_WARMUP=0` turns this off) |
| Cluster update slot (every 30 min, at an offset fixed by the cluster ID, the same on both Macs) | If a release is available: drains the member, installs, restarts from the new binary; both Macs do this together |
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
