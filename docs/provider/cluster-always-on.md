# Keep a cluster member always on

> Last updated: 2026-10-12

Run each Mac of a coordinator-paired cluster as an ordinary background
service, the way a solo `darkbloom start` runs: it starts at login, waits for
the Thunderbolt link, restarts the member after a failure with backoff, updates
together with the other member, and asks for macOS permissions once.

## Prerequisites

- A saved coordinator-paired setup on each Mac
  ([coordinator-paired member](../reference/configuration.md#coordinator-paired-member)).
  `darkbloom start --cluster-member` must already work in the foreground.
- The cluster link set up once on each Mac (step 2 of `darkbloom cluster`,
  or `darkbloom cluster link --fix`): one administrator approval gives the
  Thunderbolt port Darkbloom's own link service with its own IPv4 address,
  which RDMA needs. macOS keeps that service across reboots and updates, so it
  is not asked again; `darkbloom cluster link` reports `ready` when it is done.
- The signed, notarized Darkbloom release installed by the installer
  ([installation](installation.md)). A locally built binary works, but macOS
  treats every new ad-hoc build as a new program and asks again (see
  [permissions](#permissions-asked-once)).
- Both Macs signed in to the same account and logged in to a desktop session
  (the service is a per-user LaunchAgent, like the solo provider).

## Steps

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

## Verify

- `darkbloom status` on each Mac prints a line such as
  `cluster member supervisor: running; member pid 1234 up 310 s; runs 1, quick failures 0/3, guard teardowns 0/6`.
- `~/.darkbloom/provider.log` shows `cluster-member supervisor:` lines: the
  permissions verdict (`permissions: asked once (...)`), the link wait, each
  member start, and the reason and wait of every restart.
- The coordinator lists the pair as serving.

## What the supervisor does

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

## Permissions asked once

One administrator approval sets up the cluster link per Mac; macOS then decides
two permissions per program identity, which a release meets with no further
system setting:

| Permission | Why the member needs it | What makes it once |
|---|---|---|
| Local Network privacy | The follower dials the leader over the Thunderbolt link (a local network address). A member started by hand in a shell runs under that shell's approval (or a remote-login exemption on a bench rig), which is why it works there while the same binary started by launchd is refused (`Local network prohibited`) until Darkbloom itself is approved. | The LaunchAgent runs the executable inside `Darkbloom.app` (the recorded path is the resolved one, not the `~/.darkbloom/bin` symlink); the app carries `CFBundleIdentifier` `io.darkbloom.provider` and `NSLocalNetworkUsageDescription`, and is Developer-ID signed, notarized and stapled. The approval follows that signed identity, so updates keep it. The owner and worker processes the member starts inherit it. No configuration profile can pre-approve Local Network, so one click per Mac is the minimum. |
| Cluster link setup (administrator approval) | RDMA over Thunderbolt needs an IPv4 address on the cable port itself (JACCL refuses a port without an IPv4-mapped GID); macOS leaves the port in the Thunderbolt Bridge with none. | Done once per Mac from step 2 of `darkbloom cluster` (or `darkbloom cluster link --fix`): one macOS administrator approval adds Darkbloom's own link service to the port. macOS keeps the service through reboots and updates; the supervisor only waits for it at boot and never changes it. |
| Application firewall (when on) | A rank that listens: by default only the leader (rank 0) listens; a follower only dials out. | With **Automatically allow downloaded signed software** on (the macOS default), any Developer-ID-signed program may accept connections without an alert. The release signs the main executable and, when shipped in `Contents/Helpers`, the cluster worker and placement tool under their own identifiers. An ad-hoc build is not covered and raises one alert per new build. |

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

The release does not yet ship `darkbloom-cluster-worker` and the placement
tool inside `Darkbloom.app/Contents/Helpers` (the signing step is ready for
them; the build step that produces them is not). Until it does, a setup points
at a worker outside the bundle, which is not Developer-ID signed: on a Mac
whose rank listens with the firewall on, it can raise a firewall alert per
build when the worker opens the JACCL coordinator socket.

## Owner steps not automated

These need the owner at the Mac or an owner decision; Darkbloom changes no
system setting:

1. Approve the Local Network alert once on each Mac (step 2). If it was
   dismissed: **System Settings → Privacy & Security → Local Network**, turn on
   **Darkbloom**.
2. Unattended reboots: a LaunchAgent starts only when the user's session
   starts. For a Mac to return to serving after a power cut with nobody there,
   it must log in automatically (**System Settings → Users & Groups →
   Automatically log in as**), which macOS offers only with FileVault off.
   Otherwise serving resumes when the owner logs in.
3. If the firewall is set to **Block all incoming connections**, a listening
   rank cannot work; keep the default placement (the leader listens) or allow
   Darkbloom under **Firewall → Options**.
4. Reboot test, after the first approval: reboot both Macs, log in, and check
   that `darkbloom status` shows the supervisor running and the pair serving
   with no alert on either Mac.
5. Release engineering (not a setting): build `darkbloom-cluster-worker`
   and `darkbloom-cluster-plan` (with `mlx-cluster-worker.metallib`) in the
   release build and stage them into `Contents/Helpers` of the unsigned
   artifact; the signing step then signs them under their own identifiers.
   Default the setup's worker path to that location.
6. Release check, once per Mac with someone at the screen: install the signed
   release, `darkbloom start --cluster-member --always-on`, answer the one
   Local Network alert, then reboot, restart the member 20 times and update to
   a second signed build: no further alert.
7. Check the installed identity on each Mac:
   `codesign -dv --verbose=2 ~/.darkbloom/Darkbloom.app` (authority
   `Developer ID Application`), `spctl -a -vv ~/.darkbloom/Darkbloom.app`
   (accepted, notarized) and
   `plutil -extract NSLocalNetworkUsageDescription raw ~/.darkbloom/Darkbloom.app/Contents/Info.plist`.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Supervisor `parked` (`exhausted`) | The last three `member ended` lines in the provider log | Fix the cause, then `darkbloom restart` (a new supervisor starts with a fresh budget) |
| Supervisor `waitingForLink` | `darkbloom cluster link` | Connect the cable, or follow the printed fix |
| Follower never connects; log shows `Local network prohibited` | **Privacy & Security → Local Network** | Turn on Darkbloom; an ad-hoc build needs this per build |
| A firewall alert after an update | `codesign -dv` on the listening binary | The binary is not Developer-ID signed; install the release build |
| Install or provider log says `permissions: not asked once` | The listed reasons | Install the signed release (a locally built binary is ad-hoc signed and outside `Darkbloom.app`) |
