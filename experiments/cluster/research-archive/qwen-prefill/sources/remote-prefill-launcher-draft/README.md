# Remote-host prefill compute check

This separate root-run draft moves the frozen one-process prefill correctness
check to one SSH host. Both full-width stages still run inside one native
process. It is not interprocess pipeline inference, a two-machine model run,
or a throughput result. The original local prefill launcher remains unchanged.

The model, input, and native record contract are unchanged: the pinned
registered Qwen3.5-9B artifact, saved 65-token prose prefix, chunk size 32,
one output token, no teacher, one repeat, zero warmups, and native
`cbv2-contiguous`. There are three prefill forwards and no decode forward.
No epoch or transport option is passed to the native executable.

The root archives its local inference sources, dependency identities, runtime,
inputs, and exact binary bundle. These provide build provenance; they are not
a substitute for verification of the model on the remote execution host. No
local model payload is read and no model weights are copied.

The launcher creates a fresh, exclusive UUID directory under the remote user's
`~/DarkbloomDev/cluster-runs/` (or an explicit `--remote-run-root`). Existing
UUID paths or SCP destinations are rejected. Native files live under its
`native/` subdirectory; private control and metadata directories are siblings.
It does not need a remote Git checkout and does not alter an existing service.
SSH aliases and remote absolute paths have narrow syntax admission; every
remote command uses the existing runtime's `shlex.join` argument quoting.

A separately staged control manifest pins the control script, imported memory
helper, unchanged runtime artifact verifier, and operation configuration.
A fixed Python bootstrap verifies all four file hashes before executing them.
The controls perform these checks on the remote host:

1. Record timestamped raw `vm_stat` and require at least **6 GiB in Pages free**
   before remote bundle staging or full remote artifact hashing. Local source
   snapshots have already happened; they do not read the remote model.
2. Verify every remote bundle file and the full registered model payload;
   check the exact configuration and rank-file hashes; retain bounded copies
   of model metadata. Then require at least 8 GiB estimated reclaimable memory,
   4 GiB disk space, and descriptor headroom. The post-hash actual-free reading
   is recorded but is not asserted to remain at least 6 GiB.
3. From that post-hash baseline, require pressure at most level 2 and **zero
   increase in reported swap** during the native run and postflight. Each
   observation also retains exact-run-path supervisor/native PIDs and sampled
   RSS bytes (`ps` KiB × 1024). Missing samples are not treated as zero, and
   sampled RSS is not a peak or total unified-memory measurement.
4. Reverify the full remote model, bundle, configuration, and input bytes after
   execution. Copy only the before/after model metadata and final rank/prompt
   files back. Native stdout/stderr stream through SSH into local `native/`.

These resource observations do not guarantee peak-memory safety. The unchanged
remote `rank_worker.py` independently verifies the model/bundle before starting
the native executable. Its native process-group cleanup remains in `finally`.
The local parent deadline and remote worker/native deadlines are 180 seconds.
An errored or disconnected SSH client still causes a request to touch the
owned remote cancel file. Local SSH cancellation/reaping and remote PID
observations are separate fields: the launcher never labels the SSH client PID
as a remote supervisor or claims that a PID observation proves remote reaping.
The root separately records the final remote process inventory.

The stdout contract remains exactly the baseline checkpoint followed by the
schema-1 prefill report. The launcher validates outer source/request/release
declarations only. The nested native `comparison` stays opaque and requires
the independent CPU audit. The copied frozen parser keeps the 64 MiB total
stdout, 60 MiB line, and 4 MiB stderr bounds.

Root run command, using a new local output directory:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/remote-prefill-launcher-draft/launch_remote_prefill.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --host darkbloom-24 \
  --remote-model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 48931adacab531e289063dbe3f5a03871ee3fd420f3767be82024e7699d74f46 \
  --input-origin /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913 \
  --expected-inventory /Users/developer/DarkbloomDev/cluster-research/qwen-layer-stage-real9b-expected-20260913.json \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-prefill-peer24-20260914 \
  --timeout-seconds 180
```

The draft has 19 pure/fake tests. They prohibit actual subprocess and socket
creation, use only temporary CPU fixtures, and do not read model payloads or
invoke SSH, native code, builds, or a GPU:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/remote-prefill-launcher-draft
python3 -m unittest -v test_remote_prefill.py
```

The frozen local archive, contract, input, and memory helpers are copied byte
for byte. New files separate remote admission/bootstrap, pinned observations,
staging/control calls, supervision, orchestration, and tests. The final draft
receipt records every source hash and verifies the frozen local source hashes.
