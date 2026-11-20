# Selected MTP payload loading check

This private increment adds one loading-only Benchmark SPI and a separate
`MTPSelectedLoadCheck` executable. The ordinary worker, capability and generation
paths are unchanged. It does not initialize a collective or allocate request
history. No actual registered payload load has run for this increment yet.

## Source and build

The base is the completed private MTP native build, source snapshot
`b5aa892521d4b01142aba0e5e4e1b2c9541e76987c5cdecea39f1fa4b98d4095`.
The previous nine-file loader and dependency bytes remain intact. `integration.json`
maps ten files: four Runtime files, five private fixture files and its package
entry. The only changed loader file extracts the exact materialization body from
`loadQwenResidentStageWithMTPAssets` into
`materializePreparedQwenResidentMTPAssets`. `source-check.json` verifies this and
the exact copied worker argument/bootstrap parsers. No target-loader or receipt
schema change is made.

After the root coordinator grants the compiler slot, use the isolated workspace:

```sh
python3 prepare_workspace.py /path/to/qwen-resident-mtp-native-build-20260915/workspace
bash Tests/run-foundation.sh /new/absolute/output-directory
swift build --package-path workspace/libs/darkbloom-cluster-worker \
  --scratch-path workspace/libs/darkbloom-cluster-worker/.build-native-worker \
  -c release --jobs 2 --disable-automatic-resolution --skip-update \
  --disable-build-manifest-caching --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2 --product MTPSelectedLoadCheck
python3 Tests/check_arguments.py /absolute/path/to/MTPSelectedLoadCheck
```

The completed base's idle cache may be APFS-cloned into this new scratch path;
rewrite only clone-local workspace paths and quarantine only its stale relocated
ModuleCache. Preserve the source cache and all resolved dependency revisions.
Retain compiler output, native SHA256, actual Mach-O minimum 26.2 and the exact
source-matched `mlx.metallib` (SHA256
`2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`).
Also preserve the normal MLXLMCommon paged-attention resource bundle. A build
or parser test is not a real payload-load result.

## Root-owned physical invocation

Use only the 48 GiB Mac after confirming the installed provider and all other
native owners are stopped. The executable itself acquires the canonical private
`~/.darkbloom/cluster-device/native-device.lease` and requires an empty journal.
It writes an owned sticky journal before the SPI and resolves it only after the
SPI returns retired, encoded CPU evidence. Errors leave the journal unresolved;
do not truncate or automatically treat an empty process list as recovery.

The command is explicit `MTPSelectedLoadCheck load` followed by the existing
twelve worker argument/value pairs: model directory, rank **1**, cut **4**, fresh
membership UUID, registered model/artifact/configuration identities, two distinct
planned peer/build labels, and an absolute same-Mac uptime deadline no more than
**300 seconds** away. Optional bootstrap arguments and lookahead are refused.
There is no prompt or generation argument. The peer labels are supplied local
configuration bindings, not bilateral readiness or remote attestation.

Obtain the deadline origin from the same installed executable's pure `clock`
command, which prints Swift `DispatchTime.now().uptimeNanoseconds`. Add the fixed
300-second lifetime once on that same Mac. Do not use Python3.9
`time.monotonic_ns()` or wall time as the Swift absolute origin; the former can
be process-relative in the target interpreter. `check-arguments` also performs
no model IO and uses this exact Swift clock in its CPU tests.

Supply the existing admitted arithmetic environment and unchanged local rank1
JACCL metadata configuration (`JACCL_RANK`, `JACCL_IBV_DEVICES`,
`JACCL_COORDINATOR`, with no conflicting fallback variables). The matrix file is
read and rechecked, but no RDMA device is opened or network connection established.
No RDMA alias, second Mac or owner relay is needed for this check. Parent/native
resource gates must use the same original 6 GiB actual-free floor, zero swap,
acceptable pressure, AC/normal power and nominal/fair thermal state.

Reuse the already reviewed full-reference supervisor's byte-identical
`PipeWorkers`, `WorkerSpec` and `ResourceGate` with **315-second parent lifetime**.
Only the job/argv and two-record validation change. The parent retains raw stdout,
stderr, resource samples, native exit, reaping/group fence, journal postflight and
input rechecks. It must verify the actual installed executable/metallib and
registered config/manifest hashes before launch. Native runtime metadata
explicitly does not verify its own binary hash. Any deadline, partial stream,
nonzero exit, missing cleanup proof or changed input is a failed attempt.

## Evidence required for a passing actual load

Exactly one `admitted` then one completed `report` under schema
`qwen_resident_mtp_selected_load_check_v1`, each at most 8 MiB, followed by EOF and
exit0. The report repeats the exact admission; declared identities, rank/cut,
deadline, arithmetic and local JACCL metadata must match the predeclared job.

- The target receipt must equal the retained cut4/rank1 MTP-off source control
  for every semantic field. Compare the complete receipt except its operational
  `selectedPayloadReadAccounting`, which must be validated separately. It has
  809 active tensors, 3,979,190,464 selected payload bytes, 8,192 inert bytes and
  Plan `67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f`.
- The additive receipt must contain exactly the 31 verified inline head tensors
  and three explicitly replicated embedding tensors: 136,881,152 + 572,129,280
  = **709,010,432 bytes**, with the preserved metadata shapes/dtypes. The target
  norm/output head are shared; no new output-head payload is counted. Artifact
  checksum verification remains unchanged and is separate from selected-materialization IO counters.
- The additive `targetLoadReceiptSHA256` must equal SHA256 of canonical complete
  target receipt, including its actual operational read accounting. Both read
  receipts must account exactly for their selected bytes and satisfy the existing
  aligned-read constraints. Rounded allocation bounds must cover all 34 extras.
- Native completion requires each extra array's existing evaluated-buffer
  uniqueness/donatability, zero-offset, contiguous shape/type/extent checks; all
  ordered reads and source checks must finish. The report is returned only after
  weak target, assistant and verified-checkpoint owners are nil, GPU/CPU streams
  synchronized and freed-buffer cache is zero. Preserve the initial/loaded/released
  allocator observations; do not infer that released active memory is exactly zero.
- Confirm the canonical journal is empty after successful native exit while the
  parent independently proves reaping and process-group fencing. A resolved
  journal alone is not sufficient evidence of complete output or exit0.

The existing API's `isUnique` is the evaluated array's native donatability check,
not a new pairwise buffer-address enumeration. The replica's lifetime is covered
by its assistant ownership graph; no separate public replica weak pointer is
exposed. On a preparation failure before a weak observer can be installed, no
success receipt is produced and the process/journal remain for external fencing.
This check performs no tensor-value replay, forward, history, accepted-prefix
transaction, numerical parity, provider eligibility or performance measurement.
