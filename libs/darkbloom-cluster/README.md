# Darkbloom cluster modules (private staging, slice 1)

Shared Swift modules for the experimental distributed provider. This staging
branch currently contains only the two foundation modules extracted from the
research branch, verbatim, with their focused check runners. Nothing in the
provider or coordinator references this package yet — it is default-off and
carries no serving behavior.

| Module | Responsibility |
| --- | --- |
| `DarkbloomClusterProtocol` | Bounded JSONL commands/events, membership and request identity, sequence validation, reserve/start/stop state machine, runtime capability pins. |
| `DarkbloomClusterSecurity` | Bounded, fail-closed AES-256-GCM/HKDF authenticated record channel and record transport. Key authority is external: the codec never proves membership, peer identity, or key freshness by itself. |

Both modules support macOS 14 and have no MLX dependency.

Source ledger: extracted unmodified from the private research branch
(`Layr-Labs/d-inference` PR 1226 head `78397f4c395af9b9e016ba817c475a61a175a222`,
paths under `libs/darkbloom-cluster/`). Deferred modules (Bootstrap, Process,
Remote, Runtime, native key prelude) are tracked in the staging handoff.

## Focused checks

```sh
bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh
python3 libs/darkbloom-cluster/Tests/SecurityChecks/run.py
```

These compile the actual sources with Swift 6 and warnings as errors in a
temporary build directory and run deterministic local checks. They use no
model, no GPU, no network peer, and no RDMA; they do not qualify cross-host
execution.
