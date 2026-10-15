# Darkbloom cluster control

Shared Swift modules for the experimental distributed provider. The current
implementation controls two local direct child workers; authenticated remote
supervision and native model integration are still in progress.

| Module | Responsibility |
| --- | --- |
| `DarkbloomClusterProtocol` | Bounded JSONL commands/events, membership and request identity, sequence validation, reserve/start/stop state machine. |
| `DarkbloomClusterProcess` | Owned duplex child pipes, independent deadlines and process termination, two-worker admission, committed token decisions, retirement and resource release. |

Both modules support macOS 14 and have no MLX dependency. ProviderCore's
`DistributedPipeExecutionOwner` adapts them to the existing distributed
execution-owner contract. No default model slot or CLI command installs it yet.
Native workers must not spawn untracked descendants. Local child exit does not
prove that a worker on another machine has stopped.

From the repository root, run the focused control checks:

```sh
bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh
bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh
```

These runners compile the actual source modules with Swift 6 and warnings as
errors, using temporary build directories. They exercise actual local pipes and
owned test children without loading a model. The process runner also compiles
the actual provider owner/lease contract with explicit MLX value stand-ins;
the full provider build remains a separate integration check.

See the [distributed execution plan](../../docs/design/distributed-cluster-execution-plan.md)
and [provider test instructions](../../docs/developer/test.md#distributed-provider-lifecycle).
