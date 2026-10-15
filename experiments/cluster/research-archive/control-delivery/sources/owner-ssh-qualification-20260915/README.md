# Configured SSH owner qualification

This private increment is ready for a CPU-only run on the two configured Macs. It exercises the installed owner, authenticated SSH stdio, the paired bootstrap relay, exact native worker arguments, two fabricated committed tokens, and native/device-lease cleanup. It performs no model inference and makes no numerical or performance claim.

The current artifacts are **build-v3/** and **configuration-v3/**. Earlier builds, configurations and failed local-check receipts remain historical. The four existing owner libraries/executable come from frozen relay `753e07c8f9640a5e15acd6718f4325ad62675beb1612220cb3e0fb728ca6ddbe`. The only product-source delta is the read-only `ownerDeviceLeaseReleasedObserved` endpoint property in `release-observation.patch`.

## Root deployment and invocation

Root already staged the unchanged owner executable and its four libraries at `/Users/developer/DarkbloomDev/owner-ssh-qualification-20260915` on both hosts, with a private empty `lease/` directory. Add these files without replacing the staged owner libraries:

| Local file | Destination on each Mac |
| --- | --- |
| `build-v3/native-standin` | `native-standin` |
| `build-v3/libDarkbloomClusterRuntime.dylib` | `libDarkbloomClusterRuntime.dylib` |
| `configuration-v3/owner-rank0.json` on `192.0.2.250` | `owner.json`, mode 0600 |
| `configuration-v3/owner-rank1.json` on `192.0.2.223` | `owner.json`, mode 0600 |

The Runtime dylib above is an explicitly fabricated **parser-only CPU fixture**. Keep it in this CPU qualification directory. It must never replace an MLX/native Runtime library. The stand-in uses the exact production worker/bootstrap parsers but never opens its configured `cpu-model-not-opened` path.

Run the local controller with its adjacent **build-v3** libraries:

```sh
/Users/developer/DarkbloomDev/cluster-research/owner-ssh-qualification-20260915/build-v3/owner-controller \
  /Users/developer/DarkbloomDev/cluster-research/owner-ssh-qualification-20260915/configuration-v3/controller.json
```

The controller uses the existing explicitly pinned known-host file, the configured public-key identity path, and the public `ClusterSSHConfiguration` implementation. The preparation tool did not open authentication files or contact either host. Root owns deployment, SSH execution and retrieval.

Retain controller stdout/stderr and exit status. A complete CPU result requires exit 0, `completed=true`, `cpuQualification=true`, tokens `[9,10]`, finish `length`, both `nativeCleanupObserved=true` and both `ownerDeviceLeaseReleasedObserved=true`. Native termination and lease release are distinct observations; SSH exit/EOF satisfies neither. Root should additionally retain the two zero-size `lease/native-device.lease` files and owner/native process observations after the run.

The configuration carries a fresh membership epoch and request UUID. For another run, invoke `prepare-cpu` with a **new** local output directory and the same five arguments shown in `records/configure-3.json`; do not reuse an old membership epoch. It writes a new controller file and matching per-node templates. Existing unresolved journals must remain in place and refuse new work.

## Scope and reuse

`NativeStandIn.swift` parses the exact twelve worker argument pairs and complete bootstrap triple, verifies its configured identity/rank, connects to its actual parent through the kernel-checked private Unix socket, and completes four closed mesh rounds. It uses the existing WorkerSession/Codec for reserve, start, token decisions, clean retirement and shutdown. Capacity 4096/rank, artifact/configuration/Plan hashes and tokens are explicit invented fixture data. Build hashes identify the actual stand-in executable.

`Controller.swift` is configured by an explicit JSON file, not hardcoded token geometry. Its Pair lifecycle can later drive a separately installed real worker with real profile/Plan/source identities, prompt IDs, output count 128 and optional expected token IDs. That future input must set `cpuQualification=false`; the current controller still emits `numericalQualification=false`, because token-only evidence is not an independent logits/state comparison. The private configured owner points at that separate native executable; no product CLI configuration interface is added here.

The controller retains endpoint diagnostics and a started/result JSONL record. It anchors the overall lifetime before endpoint creation, keeps a hard alarm through final output publication, independently requests native cleanup at expiry, and waits for actual cleanup without manufacturing proof on timeout. After either successful or failed cleanup, it allows a bounded two-second release-ACK drain within owner lifetime plus its existing two-second grace. A missing ACK leaves `completed=false`; the original failure is retained.

## CPU evidence and known partial-admission defect

`records/build-3.json`: Swift 6 warnings-as-errors build passed, 3.645 s, empty output/error. `records/local-check-run-v3.json`: two actual local-child cases passed, 4.068 s, empty stderr. The success case launched two configured owners and two actual stand-in processes, exercised the exact argument parser and all four bootstrap rounds, returned `[9,10]`, observed both native terminal proofs and both release ACKs, and checked both journals were empty. This used the existing internal local-child test initializer, not SSH.

The negative case deliberately requests output count 3, which the CPU stand-in refuses before admission. The Pair sends reservations sequentially, so rank 1 has not received a reserve when rank 0 exits. `ClusterWorkerPair.reserve` cancels its active request on admission failure; `ClusterWorkerRequest.cleanup` currently sends cancel to every unacknowledged rank, including rank 1. The rank-1 owner correctly rejects a cancel without a current request in `ClusterWorkerSession.accept`, fences the child, and abandons the release handshake. The retained run observed actual native cleanup on both ranks but no rank-1 lease ACK and a nonempty rank-1 journal.

This is a **follow-up Pair lifecycle defect**, not healthy recovery. A later correction should distinguish ranks to which a reservation was submitted and use native cleanup for an unreserved rank, preserving command/request sequencing. Service validation must remain strict. The current controller reports this as failure; it does not erase the journal or claim release. The first two local-check failures incorrectly required release after this invalid-protocol path; those receipts are preserved. The final fixture separately requires successful-path release and truthful unresolved negative evidence. Its temporary directories and journals are retained at paths recorded in the output.

No real SSH, model, GPU, physical RDMA, or external TTFT measurement was executed by this increment. The root-reviewed runtime corrections and independent source review are recorded separately; source review does not replace the upcoming remote check.
