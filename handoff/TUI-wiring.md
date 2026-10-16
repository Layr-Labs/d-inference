# Terminal UI wiring (gate G3)

> Last updated: 2026-10-11

What every element of the two cluster screens reads or runs: the setup wizard
that bare `darkbloom cluster` opens on a terminal (six steps: this Mac, the
cable, pairing, model and plan, a check, serving), and the console,
`darkbloom cluster console`. A row is **wired** when at least one of the two
screens runs or reads its real operation; each screen keeps its own list
(`ClusterSetupWizardWiring` and `ClusterConsoleWiring`, both in
`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/`) and
shows an element as live only when it is on that list. Every line a screen
draws that states something names the row it was read from, and every key
names its own; `Tests/ClusterConsoleChecks` fails when a line or a key names
a row its screen has not wired, when a screen's wired row is shown by no line
or key, and when this table and the two lists disagree. Something only the
other screen can do is listed under "Not available" with the reason.

States: **wired** (a screen runs or reads the real operation); **exists, not
wired** (the tree has the operation, no screen reaches it; reason given);
**none** (no operation exists; gap-map row given).

## Setup wizard (bare `darkbloom cluster`)

Rows the wizard adds. It also shows `link.rdma`, `link.port`, `link.fix`,
`pair.saved`, `pair.approve`, `model.plan`, `pair.verify`, `session.start`,
`session.stop`, `session.process`, `session.status`, `host.request` and
`journal.state` from the tables below. It never changes anything on opening:
the link fix runs only after `f` (a dry run that lists the commands) and `y`.

| ID | Element | Source of truth | State |
|---|---|---|---|
| `mac.profile` | Chip, cores, GPU cores, memory, what the GPU may keep resident, memory free for a model now, macOS, power | `darkbloom-cluster-plan device --json` beside the worker (the host memory gate's own reading); `sysctl` and `ProcessInfo` for chip, memory and macOS when that tool is not installed | wired |
| `mac.disk` | Free space on the models volume | `URLResourceValues.volumeAvailableCapacityForImportantUsage` of the model directory's volume | wired |
| `mac.version` | Darkbloom version | `ProviderCore.version` | wired |
| `link.isolation` | Whether the cluster port belongs to the cluster alone, the findings, and what stands in the way of the fix | `ClusterLinkReadinessReport.Device.isolation`, link setup v2's inspection | wired |
| `link.thunderbolt` | Generation and speed of the cluster port's connection (Thunderbolt 5 at 80 Gb/s or more; 40 Gb/s called Thunderbolt 4 or USB4), what it connects to, the other ports | `system_profiler -json SPThunderboltDataType`, matched to the port by its hardware port name ("Thunderbolt N" is receptacle N); unit identifiers and route strings are not kept | wired |
| `pair.code` | The six-digit pairing code both screens show | SHA-256 of the follower's SSH host key fingerprint: on the leader the key its setup pins, shown only after the pinned connection succeeded; on any other Mac its own key, read with `ssh-keyscan` from 127.0.0.1 | wired |
| `pair.confirm` | The person saw the same code on both screens: `enter`, then `y` | `ClusterSetupStore.updateRecord`, the wizard's record | wired |
| `pair.link` | Pair over the Thunderbolt link with no SSH (S17): `l` listens and shows what to type on the other Mac, `c` dials the address it shows; both screens show one six-digit code, `y` on each Mac when they match (only `y` after the dwell, or `n`, answers); then each Mac's pinned key, roster and generation | `ClusterLinkPairing.run`, the operation behind `darkbloom cluster pair` (commitment-based code exchange on the link control channel, Secure Enclave proofs, attested keys, roster countersigned by both); read back from `~/.darkbloom/cluster-pairing/pairings.json` (owner-only) | wired |
| `pair.inbox` | A setup the leader sent, waiting for this Mac's approval | `darkbloom cluster inbox --receive` on this Mac (strict codecs against the capability it carries), read back from `~/.darkbloom/cluster-setup/` | wired |
| `peer.report` | What the other Mac reports about itself: chip, memory, cable, saved setup, journal, memory left wired, models | `darkbloom cluster report --json` on the other Mac over the pinned route | wired |
| `model.inventory` | Model folders on this Mac and on the other | `manifest.json` of each folder beside the setup's model directory (model ID, version, aggregate digest, size); the other Mac's report | wired |
| `model.adopt` | Use a plan: `enter`, then `y` | Both setups written from `ClusterPlacementFlow.decide` (restricted to placements this Mac leads, since only it holds the pinned route); this Mac's saved with `ClusterConfigurationStore.configure`; the other Mac's sent over the pinned route into its inbox, where it is approved on that Mac | wired |
| `check.run` | The cross-cable check: `c`, then `y` | Both links (this Mac's probe and the other Mac's report), `darkbloom start --local --distributed`, "N of 2 ranks ready" from `session.status`, an 8-token request through the local API, the interrupt, then the device journal and wired memory read again on both Macs; a pass is recorded | wired |
| `session.cleanup` | Memory left wired by an earlier run, and what a stop left on each Mac | `ClusterOrphanWiredGuard.evaluate` (S00: wired memory against the idle baseline when no Darkbloom process runs) and the device journal, on this Mac and in the other Mac's report | wired |

How the wizard is built, for whoever changes it: the screen is a pure function
of `ClusterSetupState` (`ClusterSetupWizardScreen.swift`, `ClusterSetupWizardContent.swift`),
whose only writer is the reducer (`ClusterSetupWizardReducer.swift`); every
reading and change is an effect the run loop performs through
`ClusterSetupOperations` and reports back as an event. Each Mac describes
itself in one Codable `ClusterSetupReport` (hardware, cable, saved setup,
inbox, models, memory, pairing code); the leader asks the other Mac for its
own over the pinned route, so both screens show one Mac in the same words.
Where a step stands (`ClusterSetupWizardProgress.swift`) is computed from the
snapshot and the wizard's record, which is why a new run opens at the first
step that is not done. Pairing: the screen shows a six-digit code and asks
whether both screens show it; it does not know how the code was made beyond
`ClusterSetupPairingCode.basis`. Today the code is the follower's SSH host key
(pinned on the leader, proved by the pinned connection; read from its own SSH
server on the follower). The SSH-free ceremony (S17) supplies the code from
its key agreement instead, and the setup is delivered the same way it is now
(into the other Mac's inbox, approved there); the screens do not change.

## Readiness

| ID | Element | Source of truth | State |
|---|---|---|---|
| `link.rdma` | RDMA enabled and listed | `ClusterLinkReadinessProbe.inspectLocalLink` (`rdma_ctl status`, `ibv_devinfo`) | wired |
| `link.port` | Active port, bridge membership, own IPv4 address (yes/no), IPv4-mapped GID | Same probe, `ClusterLinkReadinessReport.devices` | wired |
| `link.narration` | "RDMA detected, connection detected, address" lines | `ClusterLinkSetupFlow.observed`, the state machine `darkbloom cluster setup` prints | wired |
| `link.wait` | Waiting for a cable, or for the system job to put a lost address back | The probe again every `ClusterLinkWatch.pollIntervalSeconds`, only while no link is ready; for the system job, as many readings as `darkbloom cluster setup` allows it (`ClusterLinkSetupFlow.keeperWaitSeconds`) | wired |
| `link.fix` | Fix link: give the active port an address and install the system job that keeps it, behind one macOS approval | `ClusterLinkRepair.fix`, the operation behind `darkbloom cluster link --fix` (`--temporary`: the address alone); with `--dry-run`, the same call's dry run, which lists the commands and asks, records and changes nothing | wired |
| `link.alias` | For a port Darkbloom has on record: whether it carries its assigned address, and whether the system job that keeps it is installed and loaded | `ClusterLinkReadinessReport.Device.assignedAddress` and `addressKept`, which the probe reads from `ClusterLinkAliasStore` and `ClusterLinkAddressKeeper.isRunning`; names only | wired |
| `doctor.checks` | The doctor's check list | `ClusterDiagnostics.doctor` | wired |
| `installed.worker` | Worker binary pin, progress guard, startup-deadline support | `DistributedInstalledFiles.verify`, `DistributedInstalledWorkerFeatures.inspect` | wired |
| `journal.state` | Device journal state: absent, empty, not empty, or not safely readable | `ClusterDeviceJournalObservation.read`, which looks at the file and not into it | wired |
| `link.peer` | Which Mac is at the other end of the cable | — | none (A7: pairing steps after the link; the probe contacts no peer; the wizard's `link.thunderbolt` names its model only) |
| `link.autostart` | Starting by itself when the cable is plugged in | — | none (A7) |
| `link.physical` | Link speed, a physical collective, which device carried bytes | `darkbloom-cluster-collective-check` in the worker package | exists, not wired (not an installed command; the doctor reports `physicalProbePerformed: false`) |
| `link.remove` | Removing the port's address and its system job | `ClusterLinkRepair.remove`, the operation behind `darkbloom cluster link --remove` | exists, not wired (the screen has no key for it; it would take the link from under a session, and the command asks its own approval) |

## Pairing and trust

| ID | Element | Source of truth | State |
|---|---|---|---|
| `pair.saved` | Cluster, this member, role, peer label and rank | `ClusterConfigurationStore.load` of the `[cluster]` reference in `provider.toml` | wired |
| `pair.hostkey` | Fingerprints of the keys in the pinned known-hosts file, by kind, and whether the pin still matches | The pinned file named by `trust.knownHostsFile`, hashed against `trust.knownHostsSHA256` | wired |
| `pair.identity` | Identity file present and owner-only | `ClusterConfigurationFiles.credentialMetadata` | wired |
| `pair.approval` | Saved coordinator pair approval (id, generation, expiry, chips) | `ClusterConfiguration.nativeMember.approval`; a saved expectation, never a grant | wired |
| `pair.approve` | Approve a setup: `a`, then `y` once the question has been on the screen for half a second; never automatic | `ClusterConfigurationStore.configure`, the operation behind `darkbloom cluster configure`, on a private copy of the files passed with `--input`, `--capability`, `--capability-sha256`, refused unless they are still the setup whose digest was shown, and not offered when the pinned known-hosts file or the identity file does not check out | wired |
| `pair.discovery` | Finding a peer without being given its setup | — | none (A7, D1) |
| `pair.verify` | Proving the peer holds the pinned host key before a start | The pinned route (`ClusterSSHConfiguration`: StrictHostKeyChecking against the pinned known-hosts file, this member's identity only) running the peer's `darkbloom cluster report --json`; the wizard's step 3, `p`. The console has no key for it | wired |
| `pair.revoke` | Removing a saved setup | — | none (no verb clears the `[cluster]` reference) |

## Model

| ID | Element | Source of truth | State |
|---|---|---|---|
| `model.admitted` | Models the cluster runtime in this build accepts a setup for | `ClusterRuntimeAdapter.admittedModels`, every pair in `ClusterRuntimeAdapter.registeredProfiles`, the list admission itself checks (`libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol`) | wired |
| `model.saved` | Saved model, artifact, Plan, schedule, limits | `ClusterConfigurationStore.load`: the saved `ClusterConfiguration` and its `ClusterRuntimeCapability` | wired |
| `model.ranks` | Layers each rank owns | `ClusterRuntimeCapability.selection(planSHA256:)` | wired |
| `model.holdings` | What each Mac holds while a session of the saved Plan is up: its layers and bytes of weights, beside this Mac's own memory | `ClusterInstalledHoldings.observe`: layers from the saved Plan, bytes from `darkbloom-cluster-plan layout` (installed beside the worker) on the saved model directory, by the planner's own rule (`ClusterPlacementHoldings`). The plan's figure, not a measurement of what a worker loaded; `darkbloom cluster status` prints the same line | wired |
| `model.metadata` | Whether the manifest on this Mac matches its pin and describes the saved model | `DistributedInstalledManifest.validate` on the manifest `DistributedInstalledPlan` names; a line of its own only when it fails, since `model.files` is read from the manifest it verified. The doctor's checks of the config and tokenizer pins are rows of `doctor.checks` | wired |
| `model.files` | Manifest files present with manifest sizes | `lstat` of each manifest entry in the verified model directory; presence, not content | wired |
| `model.admission` | Per-rank admission result | `ClusterLiveStatus.session.members` (`nativeReady`, `requestCapacityBytes`), reported by each worker after it admitted and loaded | wired |
| `model.weights` | Weight payload hashes verified | The native loader, at load | none (B11: no check short of a load) |
| `model.preadmission` | Admission before a start | — | none (the worker has no admission-only mode) |
| `model.servable` | Whether a start would serve the saved model on this Mac | `ModelRuntimeRequirements.requireEligible`, as `darkbloom start --local --distributed` applies it to the member's capabilities | exists, not wired (only a start evaluates it; D4: both 27B catalog IDs require a capability no member claims, so a start refuses them, and the screen shows that refusal as the start prints it) |
| `model.plan` | Choosing which Mac leads, where the model is cut and the mode, from what each Mac detects | `ClusterPlacementFlow.decide`, the planner behind `darkbloom cluster plan`, per model folder: this Mac's profile and each model's layout through the installed plan tool, the other Mac's profile from its report, each model's capability record from the worker. The wizard's step 4; the console has no key for it | wired |
| `model.picker` | Choosing among local artifacts on the screen | `darkbloom cluster configure` with another input | exists, not wired (nothing lists local distributed artifacts; a different model is a different setup, approved through `pair.approve`) |

## Session

| ID | Element | Source of truth | State |
|---|---|---|---|
| `session.start` | Start the local distributed session: `s`, then `y` | `darkbloom start --local --distributed` as a child of the console, in a session of its own with default signal handling | wired |
| `session.stop` | Stop it | SIGINT to that child, once, the interrupt `DistributedStartSignals` turns into the bounded cooperative stop; also sent on every way the screen ends | wired |
| `session.process` | Child state and output | The child's own exit status and its standard output and error | wired |
| `session.status` | Host phase, session phase, epoch, admissions, lifetime, each rank's readiness, cleanup and release | `GET /v1/cluster/status` through `ClusterDiagnostics.status` | wired |
| `session.recover` | Clear a stranded journal: `c`, then `y` | `ClusterDeviceRecovery.recover`, the operation behind `darkbloom cluster recover` | wired |
| `session.percent` | Load progress as a fraction | — | none (a worker reports `ready` and nothing before it) |
| `session.stopOther` | Stop a session another process started | — | none (C13) |
| `session.join` | Join | `darkbloom start --cluster-member` | exists, not wired (C10: a member in this build declines every preparation, so joining cannot reach a serving pair) |
| `session.leave` | Leave | — | none (C13) |
| `session.drain` | Drain | `DistributedLocalServer.drain` | exists, not wired (C13: no verb or control reaches a running leader) |
| `session.follower` | Follower live status: state, model, free and wired memory, thermal state, requests, its newest incidents, and how old the mirror is | The follower member publishes `ClusterLinkStatusMirror` every 2 s on the link control channel (`ClusterFollowerStatusReporter`); the leader's `ClusterFollowerStatusMonitor` keeps the newest per rank, records an incident when it reports a failure or goes silent, and writes `~/.darkbloom/cluster/follower-status.json`, read through `ClusterDiagnostics.status` | wired |

## Hosting, observability, export

| ID | Element | Source of truth | State |
|---|---|---|---|
| `host.local` | Local serving API | The session child's listener, reported by `session.status` | wired |
| `export.diagnostics` | Redacted diagnostic export | `ClusterDiagnosticExport.write` over the screen's own snapshot and activity, through `ClusterDiagnosticRedaction` | wired |
| `host.coordinator` | Coordinator-formed pair serving | Member registration and control | exists, not wired (C10: declines every preparation) |
| `host.ownerViews` | Coordinator's view of this account's pairs | `GET /v1/me/cluster-pairs`, `GET /v1/me/providers` | exists, not wired (Privy session only; the provider holds a device token and has no client) |
| `host.request` | A client request through the serving API | `POST /v1/chat/completions` (streamed) on the local listener with the local token: the wizard's test prompt (`t`) and its check's 8 tokens. The console has no key for it | wired |
| `observe.requests` | Per-request pair telemetry: mode, cut, first token, decode rate, hand-off, MTP acceptance, cached tokens, and their medians | `~/.darkbloom/cluster/pair-telemetry.json`, written by the leader's `DistributedPairTelemetryContext` from `DistributedRequestObservation` and the ranks' `requestTelemetry` events, read through `ClusterDiagnostics.status` (`ClusterObservabilitySnapshot`) | wired |
| `observe.incidents` | Open incidents with reason, guidance and what to do | `~/.darkbloom/cluster/incidents.json` (`ClusterIncidentLog`, the durable log every launch and serving failure is recorded in), read through `ClusterDiagnostics.status`; `darkbloom cluster incidents` lists and dismisses | wired |

## Persisted intent

| ID | Intent | Where it lives | State |
|---|---|---|---|
| `intent.setup` | Which cluster this Mac belongs to | `[cluster]` in `provider.toml`, content-addressed records under `~/.config/darkbloom/clusters` | wired (read at launch) |
| `intent.alias` | Addresses Darkbloom assigned to ports, and the system job that keeps each | `~/.darkbloom/cluster-device/link-alias.json`; `/Library/LaunchDaemons/io.darkbloom.cluster-link.<port>.plist` and whether launchd has it loaded | wired (read at launch) |
| `intent.journal` | An owner's claim on the device | `~/.darkbloom/cluster-device/native-device.lease` | wired (read at launch) |
| `intent.running` | A session that is already serving | The live status endpoint, never a file | wired (observed at launch) |
| `intent.wizard` | The pair the wizard was given, codes confirmed, setups sent, checks passed: where a new run resumes | `~/.darkbloom/cluster-setup/wizard.json`, owner-only, written only by a key on the wizard (and by `--pair`, which it remembers) | wired (read at launch) |
| `intent.desired` | "This cluster should be running" | — | none (nothing persists it; the console never starts a session by itself) |

The wizard itself reaches the other Mac in two places only, both inside
`ClusterSetupOperations`: `reachPeer` (its report, which is also the identity
proof behind the pairing code) and `adoptPlan`'s delivery to its inbox; the
check and serving read the other rank through the leader's status. Today both
run over the pinned SSH route; the SSH-free
link control channel (S06, `work/link-control-channel`, not merged here) and
the S17 pairing ceremony replace those closures and the code's source, not the
screens, keys or checks.

The console and the wizard share one lock, `darkbloom-cluster-console.lock` in
the user's own temporary directory: an empty lock held while a screen is open
so a second screen refuses to open. It records no intent. Opening the console
writes nothing under the home directory; the wizard writes its record only for
`--pair` and for a key that confirms a code, adopts a plan or records a check,
and its inbox only for a setup the leader sent.
