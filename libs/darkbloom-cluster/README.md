# Darkbloom cluster modules

Shared Swift modules for the experimental distributed provider. The current
implementation provides process control, an SSH owner protocol, a private local
bootstrap channel, paired bootstrap relay and a native resident model runtime.
The installed provider exposes explicit `start --local --distributed`; ordinary
startup remains solo. See the [CLI reference](../../docs/provider/cli-reference.md#darkbloom-cluster-experimental).

| Module | Responsibility |
| --- | --- |
| `DarkbloomClusterProtocol` | Bounded JSONL commands/events, membership and request identity, sequence validation, reserve/start/stop state machine. |
| `DarkbloomClusterProcess` | Owned duplex child pipes, independent deadlines and process termination, two-worker admission, committed token decisions, retirement and resource release. |
| `DarkbloomClusterRemote` | Configured SSH endpoint, paired native bootstrap relay, child supervision, owner/lease identity, conservative accounting, durable device journal and quarantine until actual native cleanup. |
| `DarkbloomClusterBootstrap` | Bounded private Unix socket between an owner and its actual direct child, with kernel peer identity, epoch/rank/sequence checks and deadlines. |
| `DarkbloomClusterRuntime` | Private native executor, verified selected-weight loading, resident stage ownership, and bounded Qwen generation. |

The protocol, process, remote and bootstrap modules support macOS 14 and have no MLX dependency. ProviderCore's
`DistributedPipeExecutionOwner` adapts them to the existing distributed
execution-owner contract. The installed session and local HTTP host retain the
pair through actual cleanup and owner release acknowledgements.
Native workers must not spawn untracked descendants. Local child exit does not
prove that a worker on another machine has stopped.

The runtime depends on MLX. The sibling
[`darkbloom-cluster-worker`](../darkbloom-cluster-worker/README.md) package builds
the native rank executable separately with a macOS 26.2 minimum for JACCL.
It is not built into the provider's normal control dependency path. The shared
runtime currently admits registered Qwen3.5 9B 4-bit weights with BF16 activations,
greedy decoding and MTP off;
other model profiles and production serving remain unqualified.

From the repository root, run the focused control checks:

```sh
bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh
bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh
bash libs/darkbloom-cluster/Tests/DeadlineChecks/run.sh
bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
bash libs/darkbloom-cluster/Tests/BootstrapChecks/run.sh
bash libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh
```

These runners compile the actual source modules with Swift 6 and warnings as
errors, using temporary build directories. They exercise actual local pipes and
owned test children without loading a model. The process runner also compiles
the actual provider owner/lease contract with explicit MLX value stand-ins;
the full provider build remains a separate integration check.
The deadline runner checks conversion from the originating request budget;
queue time does not grant a fresh generation or first-token deadline.
The remote checks compile the current control sources in a temporary package
and exercise ownership state without contacting a peer. `ClusterWorkerEndpoint`
keeps connection loss separate from actual native cleanup; its process fixture
withholds simulated owner proof even after the local test child exits.
The SSH checks exercise actual local owner/native test children, queue budgets,
terminal observations, disconnection and journal refusal; they do not contact
another host. The bootstrap checks use actual local sockets and children, plus
the real C/Swift callback bridge with explicit native factory/cache stand-ins.
They also check worker argument admission with explicit MLX value stand-ins.
The paired relay admits the closed two-member native mesh bootstrap and preserves
the cleanup channel when cancellation races a bootstrap round. The SSH runner
also exercises that path with actual local owner/native children. A
[private configured owner tool](Tools/ConfiguredOwner/README.md) supports the next
cross-host qualification; no such execution is established by the local tests.
Unresolved journals refuse a new launch; automatic orphan recovery remains
unsupported. Installed `cluster worker-owner --stdio` uses the same ownership
service with saved local configuration and the canonical device lease.

The pinned capability advertises supported prefill schedules; saved setup selects
`serial_v1` or `one_chunk_lookahead_v1`. Serial remains the default. Native peers
bind selection before loading weights and charge lookahead's existing additional
allowance before readiness and request execution. The product uses the ordinary
serving driver without benchmark capture. See the
[configuration contract](../../docs/reference/configuration.md#saved-distributed-setup-experimental)
for compatibility, limits and admission semantics.

See the [distributed execution plan](../../docs/design/distributed-cluster-execution-plan.md)
and [provider test instructions](../../docs/developer/test.md#distributed-provider-lifecycle).
