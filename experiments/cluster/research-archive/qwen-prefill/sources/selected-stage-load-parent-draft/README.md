# Private selected-stage loading parent

This source/CPU proposal runs one registered 9B or 27B default stage through the
existing `qwen-dense-stage-load-check` native entry. It performs no forward,
request, numerical comparison, resident reuse, or throughput measurement. The
initial intended native qualification is 9B stage 0 on peer24. The 27B branch is
source and fake-test support only; physical qualification remains separate.

The executable is supplied with an explicit SHA-256 pin. Runtime, release and
model directories are explicit absolute paths on the execution Mac. The parent
does not invoke SSH, a compiler, a model downloader, or another launcher. Root
retains responsibility for transferring this package and running the command.

```sh
python3 -B /absolute/path/selected-stage-load-parent-draft/run_selected_stage_load.py \
  --runtime "$EXECUTION_RUNTIME" \
  --release "$EXECUTION_RELEASE" \
  --model-dir "$EXECUTION_9B_MODEL" \
  --profile registered_qwen35_9b --stage-index 0 \
  --expected-native-sha256 "$ROOT_VERIFIED_NATIVE_SHA256" \
  --output "$EXECUTION_RUNS/dense-stage-load-9b-stage0-peer24-20260914"
```

All shell variables must identify the actual execution Mac paths and root's
verified build pin. Stage 1 is a separate fresh invocation with `--stage-index 1`
and a different new output. To reuse a previously retained bundle, add both
`--reuse-bundle /absolute/owned/bundle` and
`--expected-bundle-manifest-sha256 SHA256`. The exact frozen c4832e helper checks
the owned read-only tree, file inventory, current archived runtime helpers and
native pin before creating only the new output's `bundle` symlink. It repeats
the check before native start and in an independent postflight action. A tree
with the historical extra Python cache refuses; it is neither repaired nor
relabelled. Without both reuse arguments, the existing archive runtime creates
a fresh bundle snapshot.

The native command is exactly five pairs: mode, model directory, registered
profile, stage index, and timeout 120 seconds. Parent execution and final outer
validation must complete within 135 seconds measured from immediately before
`Popen`; bounded TERM/KILL cleanup retains its separate existing 5+5 second
limits. Source snapshotting and postflight hashing are preparatory/evidence work
outside that execution deadline, as in the constructor parent. Their inherited
subprocess bounds remain unchanged. There is no override for these limits.

Every saved parent memory observation, including initial/prelaunch/after cleanup,
must show at least 6 GiB from the inherited `vm_stat` Pages-free × page-size
observation, pressure 0 through 2, and absolute zero **reported** swap. The parent
retains the raw observations and preserves missing RSS as missing. A present RSS
sample must belong to the allocated PID/process group and exact native command.
Fixed RSS refusal limits are 4 GiB for 9B and 10 GiB for 27B: conservative loading
screens that allow several GiB of selected weights but stop a larger observed
process. They do not estimate peak memory or prove that either stage fits.

Each memory sample is paired with a bounded `pmset` observation. AC is admitted;
battery power requires one observed internal battery at 15 percent or higher.
This is a brief materialization-only allowance, not a sustained benchmark policy.
The native loader independently enforces its unchanged exact OS zero-swap,
6 GiB floor and dynamic actual-free/allocator bounds before and throughout
payload loading. Parent admission conveys no native allocation permit. Full
checkpoint checksum reads use the source-pinned no-cache implementation; later
ordinary payload reads can consume file-cache headroom and legitimately refuse.

The parent preserves the constructor framework's exact raw configuration and
manifest pins, expected aggregate identity, full source/submodule archive,
release/bundle pins, filtered arithmetic environment and single owned process
group. It copies three frozen helpers without edits. Model metadata is read as
bounded raw bytes with regular-file/stable-fstat checks, never re-encoded. The
parent does not read model payloads; the native verified checkpoint performs the
actual full-file verification. Both metadata pins are checked before and after
the native process. The expected raw pins are the existing two registered
artifacts, with no new model identity or split serializer.

Success needs native exit 0, actual parent reap, no owned group remaining, empty
stderr, at most 8 MiB stdout/64 KiB stderr, and exactly one complete native report.
The closed outer check binds model/stage, source config/aggregate, coherent
profile/Plan fingerprints, loading flags and explicit non-qualification flags.
Nested tensor inventories and resource DTOs remain unaudited. The receipt keeps
`independentMetadataAuditPerformed=false` and
`independentTensorAuditPerformed=false`; a separate prospective audit is needed
for those claims. No plan hash or numerical result is manufactured by this
parent. All primary, cleanup, source, raw-input, bundle-reference, resource and
stream-pin failures remain distinct in the failed receipt. Existing runs and
frozen constructor/readiness parents are untouched.

`python3 -B -m unittest -v test_selected_stage_parent.py` runs fabricated JSON,
temporary small files and fake process objects only. Real subprocess/network
entry points are guarded during tests. These tests cover source/raw identity
drift, refusal before/after bundle creation, owned cleanup, both selected stages,
reuse wiring, strict output/scope, power/free/swap/RSS boundaries and deadline
time charged through final validation. They do not exercise an OS resource
sample, native private gate, weight read, GPU, socket, SSH session or compiler.

The frozen original constructor V2 is retained under `originals/`. The main
delta is explicit execution paths and one selected-stage command, stronger
parent free/swap screens with a narrowly permitted battery observation,
selected-stage outer identity, and independent postflight actions. Historical
constructor policy/results and their separate metadata oracle remain unchanged.
