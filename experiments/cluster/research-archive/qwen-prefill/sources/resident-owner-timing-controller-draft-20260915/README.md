# Private owner-control timing cohort

This derivative of `owner-ssh-qualification-20260915/Sources/Controller.swift` measures a bounded sequence on one ready `ClusterWorkerPair`. It uses the current MAIN Foundation Protocol/Bootstrap/Process/Remote sources captured in `upstream-pins.json`, including the per-rank partial-admission cleanup fix. No public repository or frozen controller was edited.

The normal configuration is one excluded warmup followed by three measured requests. Each request uses a fresh generated UUID, exactly 8192 prompt IDs, chunk 512, output 128, no stop IDs, and a declared 128-ID sequence guard. A successful sequence guard is not a full numerical comparison. Use the already qualified same-input sequence; root separately binds native/source/input pins and actual selected prefill policy. `cohortLabel` and `policyLabel` are caller labels, not evidence that a policy engaged. The controller never changes provider capacity or publishes rates to a provider.

`TimingCohort` is sequential MainActor orchestration. It reserves through the Pair, stamps immediately before `start`, then receives validated committed-token callbacks through a small lock-protected capture. It waits for observed request retirement before releasing resources. Each record retains reserve begin/end, start call, first token at count 1, final token at count 128, finished callback, retirement observation, and resource release. Completion requires nondecreasing timestamps, exact expected IDs, length finish, no callback failure, and zero retained request bytes after release. Any failure stops the cohort and retains the partial request; no retry, reload or extra request is attempted.

The named interval is **internal owner-control start-to-first committed-token callback latency** on the controller's `DispatchTime.uptimeNanoseconds` clock. It excludes model loading and request reservation, but includes control queues, authenticated owner transport, native work, and return delivery. It is not external HTTP/OpenRouter TTFT, isolated GPU compute time, or a physical/performance qualification. The final token precedes diagnostic sidecar publication/retirement. Whole-controller load/control/cleanup stamps are retained separately and must not be substituted for prefill latency. No absolute clock value crosses Macs in a worker reservation; the existing remote endpoint translates bounded remaining durations.

Only complete sequence-matched measured requests contribute to the summary, and the summary requires the entire declared cohort to finish. Warmups are excluded. Failed or incomplete cohorts publish no median. The original fixed owner lifetime remains at most 300 seconds; each request deadline is the lesser of its remaining lifetime and the configured request cap (at most 120 seconds). Expired lifetime before the next reservation records incompleteness. The controller never resets or extends the owner lifetime.

Global endpoint cleanup watchdog, actual native cleanup proof, bounded authenticated device-lease ACK drain, diagnostic tails, and the hard publication alarm remain. SSH EOF, a sent signal, and elapsed time never manufacture cleanup or release evidence. If proof is unavailable, the original supervisor remains charged/quarantined and the hard controller alarm may terminate without a final successful receipt. Root should continue retrieving per-node journal/process evidence separately.

Configuration is an explicit bounded JSON file with exactly:

```text
schema = darkbloom_owner_timing_cohort_v1
cohortLabel (ASCII letters/digits/_/-, 1..64)
policyLabel (serial_v1 | one_chunk_lookahead_v1; caller label only)
cpuQualification, clusterID, readyTemplateBase64, membershipEpoch, peers
promptTokenIDs, stopTokenIDs=[], expectedTokenIDs
outputCount=128, chunkSize=512
warmupCount=0..1, measuredCount=1..3  (standard 1 and 3; total at most4)
lifetimeSeconds=1..300, startupSeconds=1..lifetimeSeconds
requestSeconds=1..min(120,lifetimeSeconds)
```

The peer fields remain `host,user,port,knownHostsFile,identityFile,installedOwner`. Use the same owner/native/input/source identities for the matched serial and lookahead runs; set the actual private native environment policy in each trusted owner configuration. The controller's label does not set that environment. To adapt the previous one-request configuration, remove `requestID`, change `schema`, and add the two labels and two counts. Retain all other explicit fields, including actual prompt/expected IDs. Neither prompt IDs nor key contents are written into the controller receipt; it includes the raw configuration SHA and comma-joined token-ID hashes. Raw per-request selected IDs remain bounded to128 for the sequence guard evidence.

Build/run (Foundation only):

```sh
bash build.sh /absolute/new-build-directory
/absolute/new-build-directory/timing-check /absolute/new-build-directory/fake-worker
/absolute/new-build-directory/owner-timing-controller /absolute/explicit-configuration.json
```

For controller deployment, keep its four adjacent dylibs: `libDarkbloomClusterProtocol.dylib`, `libDarkbloomClusterBootstrap.dylib`, `libDarkbloomClusterProcess.dylib`, `libDarkbloomClusterRemote.dylib`. No test binary or fake Runtime module is needed. Libraries use `@rpath`/loader-relative paths. Root owns all real SSH/native/model execution.

The focused checks use actual local owned CPU children, the current production Pair/Request, and invented tokens. They cover four distinct requests on the same two live PIDs, warmup exclusion/median calculation, a second-request refusal, sequence mismatch, an already exhausted lifetime, output failure after retirement, and invalid configuration/timestamp/count observations. These tests do not exercise real SSH or prove remote lease release; the inherited endpoint/controller cleanup path was source-reviewed separately. Earlier shell/Swift fixture failures and the too-short 20-second fake cohort are preserved in `checks-1` through `checks-4`.

Final `build-5` Swift6 warnings-as-errors compile passed in 6.365 seconds. All seven focused groups passed in 43.089 seconds; compile/run stderr were empty and all source pins remained stable (`checks-5/execution.json`). The four-request case retained four complete128-ID records and the same two live child PIDs before final actual termination. No SSH/native-model/GPU run was performed. `current-artifacts.json` gives the five deployable file paths and hashes.
