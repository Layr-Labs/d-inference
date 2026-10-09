# Terminal UI wiring (gate G3)

> Last updated: 2026-10-09

What every element of the `darkbloom cluster` console reads or runs. The
console shows an element as live only when its row here says **wired**. A row
in either other state is listed on the screen under "Not available in this
build" with its reason, or is not shown at all. `ClusterConsoleWiring`
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleWiring.swift`)
carries the same identifiers. Every line the screen draws that states
something names the row it was read from, and every action names its own;
`Tests/ClusterConsoleChecks` fails when a line or an action names a row that
is not wired, and when this table and that list disagree.

States: **wired** (the screen runs or reads the real operation); **exists, not
wired** (the tree has the operation, the screen cannot reach it; reason
given); **none** (no operation exists; gap-map row given).

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
| `link.peer` | Which Mac is at the other end of the cable | — | none (A7: pairing steps after the link; the probe contacts no peer) |
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
| `pair.verify` | Proving the peer holds the pinned host key before a start | — | none (doctor: SSH authentication is not tested) |
| `pair.revoke` | Removing a saved setup | — | none (no verb clears the `[cluster]` reference) |

## Model

| ID | Element | Source of truth | State |
|---|---|---|---|
| `model.admitted` | Models the cluster runtime in this build accepts a setup for | `ClusterRuntimeAdapter.admittedModels`, every pair in `ClusterRuntimeAdapter.registeredProfiles`, the list admission itself checks (`libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol`) | wired |
| `model.saved` | Saved model, artifact, Plan, schedule, limits | `ClusterConfigurationStore.load`: the saved `ClusterConfiguration` and its `ClusterRuntimeCapability` | wired |
| `model.ranks` | Layers each rank owns | `ClusterRuntimeCapability.selection(planSHA256:)` | wired |
| `model.metadata` | Whether the manifest on this Mac matches its pin and describes the saved model | `DistributedInstalledManifest.validate` on the manifest `DistributedInstalledPlan` names; a line of its own only when it fails, since `model.files` is read from the manifest it verified. The doctor's checks of the config and tokenizer pins are rows of `doctor.checks` | wired |
| `model.files` | Manifest files present with manifest sizes | `lstat` of each manifest entry in the verified model directory; presence, not content | wired |
| `model.admission` | Per-rank admission result | `ClusterLiveStatus.session.members` (`nativeReady`, `requestCapacityBytes`), reported by each worker after it admitted and loaded | wired |
| `model.weights` | Weight payload hashes verified | The native loader, at load | none (B11: no check short of a load) |
| `model.preadmission` | Admission before a start | — | none (the worker has no admission-only mode) |
| `model.servable` | Whether a start would serve the saved model on this Mac | `ModelRuntimeRequirements.requireEligible`, as `darkbloom start --local --distributed` applies it to the member's capabilities | exists, not wired (only a start evaluates it; D4: both 27B catalog IDs require a capability no member claims, so a start refuses them, and the screen shows that refusal as the start prints it) |
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
| `session.follower` | Follower live status | — | none (C13) |

## Hosting, observability, export

| ID | Element | Source of truth | State |
|---|---|---|---|
| `host.local` | Local serving API | The session child's listener, reported by `session.status` | wired |
| `export.diagnostics` | Redacted diagnostic export | `ClusterDiagnosticExport.write` over the screen's own snapshot and activity, through `ClusterDiagnosticRedaction` | wired |
| `host.coordinator` | Coordinator-formed pair serving | Member registration and control | exists, not wired (C10: declines every preparation) |
| `host.ownerViews` | Coordinator's view of this account's pairs | `GET /v1/me/cluster-pairs`, `GET /v1/me/providers` | exists, not wired (Privy session only; the provider holds a device token and has no client) |
| `host.request` | A client request through the serving API | `POST /v1/chat/completions` on the local listener | exists, not wired (no client in the provider; G2 has not run it end to end) |
| `observe.requests` | Request speed and first-token time | `DistributedRequestObservation` | exists, not wired (logged only; nothing reads it back) |

## Persisted intent

| ID | Intent | Where it lives | State |
|---|---|---|---|
| `intent.setup` | Which cluster this Mac belongs to | `[cluster]` in `provider.toml`, content-addressed records under `~/.config/darkbloom/clusters` | wired (read at launch) |
| `intent.alias` | Addresses Darkbloom assigned to ports, and the system job that keeps each | `~/.darkbloom/cluster-device/link-alias.json`; `/Library/LaunchDaemons/io.darkbloom.cluster-link.<port>.plist` and whether launchd has it loaded | wired (read at launch) |
| `intent.journal` | An owner's claim on the device | `~/.darkbloom/cluster-device/native-device.lease` | wired (read at launch) |
| `intent.running` | A session that is already serving | The live status endpoint, never a file | wired (observed at launch) |
| `intent.desired` | "This cluster should be running" | — | none (nothing persists it; the console never starts a session by itself) |

The console adds one file of its own, `darkbloom-cluster-console.lock` in the
user's own temporary directory: an empty lock held while a screen is open so a
second screen refuses to open. It records no intent, and opening a screen
writes nothing under the home directory.
