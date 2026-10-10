# Darkbloom cluster modules

Shared Swift modules for the experimental distributed provider. The provider
links `DarkbloomClusterProtocol`, `DarkbloomClusterProcess`,
`DarkbloomClusterBootstrap` and `DarkbloomClusterRemote` for its opt-in
`start --local --distributed` path; ordinary startup is unaffected. The native
rank worker that links `DarkbloomClusterRuntime` is built separately, in
[`../darkbloom-cluster-worker`](../darkbloom-cluster-worker/README.md).

| Module | Responsibility |
| --- | --- |
| `DarkbloomClusterProtocol` | Bounded JSONL commands/events, membership and request identity, sequence validation, reserve/start/stop state machine, runtime capability pins. |
| `DarkbloomClusterSecurity` | Bounded, fail-closed AES-256-GCM/HKDF authenticated record channel and record transport. Key authority is external: the codec never proves membership, peer identity, or key freshness by itself. |
| `DarkbloomClusterBootstrap` | Bounded private Unix socket between an owner and its actual direct child, with kernel peer identity, epoch/rank/sequence checks and deadlines. Adds the opt-in `nativeKeyPreludeV1` authorization round (closed packet header, phase state machine at both ends) that hands a confirmed X25519 transcript to the record transport. |

| `DarkbloomClusterProcess` | Ownership of one local worker child: explicit environment, pipes, fence, reap, device lease and journal. |
| `DarkbloomClusterRemote` | The owner service and the leader's endpoint to a remote owner over a pinned SSH channel, with the native key relay. |
| `DarkbloomClusterRuntime` | The two-stage Qwen layer pipeline: verified checkpoint and tensor loading, resident admission and lifecycle, generation driver, collective transport. Links MLX. |

The control modules support macOS 14 and have no MLX dependency. The runtime
compiles for macOS 14 too, but there the pinned `mlx-swift` builds the JACCL
stub, so a collective can only be created by the 26.2 worker build.

Source ledger: extracted from the research branch (`Layr-Labs/d-inference`
PR 1226 head `78397f4c395af9b9e016ba817c475a61a175a222`); the native key prelude
and record authority come from the PR 1227 draft `b16c97bf` with new
exchange and refusal checks. Two research files are not staged
(`JACCLBootstrap.swift`, `QwenResidentBootstrap.swift`): they need the mlx-c
bootstrap bridge (`Layr-Labs/mlx-c` `489e965`), which the pinned mlx-c
(`02cf6f4`) does not carry. The submodule pins are unchanged.

## Focused checks

```sh
bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh
python3 libs/darkbloom-cluster/Tests/SecurityChecks/run.py --output <new-dir>
bash libs/darkbloom-cluster/Tests/NativePairChecks/run.sh
bash libs/darkbloom-cluster/Tests/BootstrapChecks/run.sh
bash libs/darkbloom-cluster/Tests/PreludeChecks/run.sh
bash libs/darkbloom-cluster/Tests/CheckpointChecks/run.sh
python3 libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py --output <new-dir>
bash libs/darkbloom-cluster/Tests/StageTransferChecks/run.sh
bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh
bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
bash libs/darkbloom-cluster/Tests/CapabilityChecks/run.sh
bash libs/darkbloom-cluster/Tests/DeadlineChecks/run.sh
bash libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh
bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh
```

Runtime tests (tensor verification, resident admission, generation and owned
state contracts) need the pinned `mlx.metallib` beside the test binary:

```sh
swift build --package-path libs/darkbloom-cluster --build-tests
./scripts/fetch-metallib.sh libs/darkbloom-cluster/.build/out/Products/Debug
BUNDLE=libs/darkbloom-cluster/.build/out/Products/Debug/DarkbloomClusterRuntimeTests.xctest/Contents/MacOS
cp libs/darkbloom-cluster/.build/out/Products/Debug/mlx.metallib "$BUNDLE/"
swift test --package-path libs/darkbloom-cluster --skip-build
rm "$BUNDLE/mlx.metallib"   # a later build cannot re-sign the bundle with it inside
```

Fetch the metallib after the build: the build replaces `.build/debug` with a
link to `out/Products/Debug`, which discards a file placed there earlier.

These compile the actual sources with Swift 6 and warnings as errors in a
temporary build directory and run deterministic local checks. They use no
model, no GPU, no network peer, and no RDMA; they do not qualify cross-host
execution.
