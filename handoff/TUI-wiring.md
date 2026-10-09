# Terminal UI wiring (gate G3)

> Last updated: 2026-10-09

What every element of the `darkbloom cluster` console reads or runs. The
console shows an element as live only when its row here says **wired**. A row
in either other state is listed on the screen under "Not available in this
build" with its reason, or is not shown at all. `ClusterConsoleWiring`
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleWiring.swift`)
carries the same identifiers, and `Tests/ClusterConsoleChecks` fails when this
table and that list disagree.

States: **wired** (the screen runs or reads the real operation); **exists, not
wired** (the tree has the operation, the screen cannot reach it; reason
given); **none** (no operation exists; gap-map row given).

## Readiness

| ID | Element | Source of truth | State |
|---|---|---|---|
| `link.rdma` | RDMA enabled and listed | `ClusterLinkReadinessProbe.inspectLocalLink` (`rdma_ctl status`, `ibv_devinfo`) | wired |
| `link.port` | Active port, bridge membership, own IPv4 address (yes/no), IPv4-mapped GID | Same probe, `ClusterLinkReadinessReport.devices` | wired |
| `link.narration` | "RDMA detected, connection detected, address" lines | `ClusterLinkSetupFlow.observed`, the state machine `darkbloom cluster setup` prints | wired |
| `link.wait` | Waiting for a cable | The probe again every `ClusterLinkWatch.pollIntervalSeconds`, only while no link is ready | wired |
| `link.alias` | Whether an address Darkbloom added is still on its port | `ClusterLinkAliasStore.load` and `ClusterNetworkInterfaces.lists`; names only | wired |
| `doctor.checks` | The doctor's check list | `ClusterDiagnostics.doctor` | wired |
| `installed.worker` | Worker binary pin, progress guard, startup-deadline support | `DistributedInstalledFiles.verify`, `DistributedInstalledWorkerFeatures.inspect` | wired |
| `journal.state` | Device journal state | `ClusterDeviceJournalObservation.read` | wired |
| `link.peer` | Which Mac is at the other end of the cable | — | none (A7: pairing steps after the link; the probe contacts no peer) |
| `link.autostart` | Starting by itself when the cable is plugged in | — | none (A7) |
| `link.physical` | Link speed, a physical collective, which device carried bytes | `darkbloom-cluster-collective-check` in the worker package | exists, not wired (not an installed command; the doctor reports `physicalProbePerformed: false`) |

## Pairing and trust

| ID | Element | Source of truth | State |
|---|---|---|---|
| `pair.saved` | Cluster, this member, role, peer label and rank | `ClusterConfigurationStore.load` of the `[cluster]` reference in `provider.toml` | wired |
| `pair.hostkey` | Peer host-key fingerprints and whether the known-hosts pin still matches | The pinned file named by `trust.knownHostsFile`, hashed against `trust.knownHostsSHA256` | wired |
| `pair.identity` | Identity file present and owner-only | `ClusterConfigurationFiles.credentialMetadata` | wired |
| `pair.approval` | Saved coordinator pair approval (id, generation, expiry, chips) | `ClusterConfiguration.nativeMember.approval`; a saved expectation, never a grant | wired |
| `pair.approve` | Approve a setup: two keypresses, never automatic | `ClusterConfigurationStore.configure`, the operation behind `darkbloom cluster configure`, on the files passed with `--input`, `--capability`, `--capability-sha256` | wired |
| `pair.discovery` | Finding a peer without being given its setup | — | none (A7, D1) |
| `pair.verify` | Proving the peer holds the pinned host key before a start | — | none (doctor: SSH authentication is not tested) |
| `pair.revoke` | Removing a saved setup | — | none (no verb clears the `[cluster]` reference) |

## Model

| ID | Element | Source of truth | State |
|---|---|---|---|
| `model.admitted` | Models this build admits across two Macs | `ClusterRuntimeAdapter.admittedModels` (`libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol`) | wired |
| `model.saved` | Saved model, artifact, Plan, schedule, limits | `ClusterStatusBinding`, `ClusterRuntimeCapability` | wired |
| `model.ranks` | Layers each rank owns | `ClusterRuntimeCapability.selection(planSHA256:)` | wired |
| `model.metadata` | Config, manifest and tokenizer pins on this Mac; runtime description equal to the saved capability | `DistributedInstalledValidation.validate`, as the doctor runs it | wired |
| `model.files` | Manifest files present with manifest sizes | `lstat` of each manifest entry in the verified model directory; presence, not content | wired |
| `model.admission` | Per-rank admission result | `ClusterLiveStatus.session.members` (`nativeReady`, `requestCapacityBytes`), reported by each worker after it admitted and loaded | wired |
| `model.weights` | Weight payload hashes verified | The native loader, at load | none (B11: no check short of a load) |
| `model.preadmission` | Admission before a start | — | none (the worker has no admission-only mode) |
| `model.picker` | Choosing among local artifacts on the screen | `darkbloom cluster configure` with another input | exists, not wired (nothing lists local distributed artifacts; a different model is a different setup, approved through `pair.approve`) |

## Session

| ID | Element | Source of truth | State |
|---|---|---|---|
| `session.start` | Start the local distributed session | `darkbloom start --local --distributed` as a child of the console | wired |
| `session.stop` | Stop it | SIGINT to that child, the interrupt `DistributedStartSignals` turns into the bounded cooperative stop | wired |
| `session.process` | Child state and output | The child's own exit status and its standard output and error | wired |
| `session.status` | Host phase, session phase, epoch, admissions, lifetime, each rank's readiness, cleanup and release | `GET /v1/cluster/status` through `ClusterDiagnostics.status` | wired |
| `session.recover` | Clear a stranded journal | `ClusterDeviceRecovery.recover`, the operation behind `darkbloom cluster recover` | wired |
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
| `intent.alias` | Addresses Darkbloom added | `~/.darkbloom/cluster-device/link-alias.json` | wired (read at launch) |
| `intent.journal` | An owner's claim on the device | `~/.darkbloom/cluster-device/native-device.lease` | wired (read at launch) |
| `intent.running` | A session that is already serving | The live status endpoint, never a file | wired (observed at launch) |
| `intent.desired` | "This cluster should be running" | — | none (nothing persists it; the console never starts a session by itself) |

The console adds one file of its own, `~/.darkbloom/cluster-device/console.lock`:
an empty lock held while a screen is open so a second screen refuses to open.
It records no intent.
