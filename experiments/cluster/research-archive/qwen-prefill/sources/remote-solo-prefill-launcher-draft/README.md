# Remote solo prefill launcher draft

2026-09-14. This is a root-run, outside-repository launcher for the integrated
`qwen-layer-stage-solo-prefill-check` mode. It has prospective fake/CPU validation
only. It does not run a native reference request: the first native record is
`qwen_layer_stage_solo_prefill_ready`, after verified full-model loading and
before fresh request-state construction. Exactly one final solo report follows.

The fixed input is the pinned natural 65-token prefix, chunk size 32, output
count 1, no teacher, no warmup, one request, and at most 180 seconds of parent
native supervision. The pinned 9B artifact, source layout, native precision,
CBv2 path and native memory admission remain unchanged. This launcher reports
outer protocol/ownership checks; it treats the nested native `execution` as
opaque. The separate CPU numerical oracle is required before interpreting it.

## Reference bytes

- Original descriptor SHA-256:
  `782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b`.
- Baseline evidence fingerprint:
  `54213f9c90b92033cf9ea78976f3cd8f6af355dc45930f6432a49351f97bc1a8`.
- The independently reproduced worker serialization currently has SHA-256
  `8a61a536778b1988196ec3621c83210859055c414d2c29b5d8abcf80933eb22a`.

`inputs/solo-reference.origin.json` retains the exact original bytes. Sorted
`rank.json` embeds the decoded descriptor; unchanged `rank_worker.py` writes
`json.dumps(content)` with its default separators and no newline. The launcher
independently reproduces those bytes as `inputs/solo-reference.staged.json`,
binds their SHA in the native argument, and verifies the exact saved rank
configuration reproduces them. The remote pinned control repeats the expected
serialization check before execution, then hashes the actual remote
`solo-reference.json` after execution. Its retrieved copy is
`remote-metadata/solo-reference.final.json`. Original and staged byte identity
are explicitly separate; the original bytes are not claimed to survive JSON
reserialization unchanged.

## Guarded root invocation

Supply an explicitly reviewed native binary pin; the launcher has no default
binary hash. The host argument must be a configured SSH alias, with batch-mode
key access. This example is a command template, not a record of execution:

```sh
python3 launch_remote_solo_prefill.py \
  --release "$SOLO_RELEASE" --runtime "$CLUSTER_RUNTIME" \
  --output "$NEW_SOLO_OUTPUT" --host "$SSH_ALIAS" \
  --remote-model-dir "$REMOTE_MODEL" \
  --input-origin "$PINNED_INPUT_ORIGIN" \
  --expected-inventory "$PINNED_EXPECTED_INVENTORY" \
  --solo-reference "$PINNED_SOLO_REFERENCE" \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 "$REVIEWED_NATIVE_SHA256" \
  --timeout-seconds 180
```

Only controls are uploaded before the remote actual-free screen (at least
6 GiB); model hashing and bundle upload follow that screen. After hashing,
the existing remote gate requires at least 8 GiB reclaimable memory, 4 GiB
disk space and descriptor headroom. Pressure must stay at most 2, with zero
new OS-reported swap from the post-hash baseline through all saved samples.
These are resource screens, not a proof of peak-memory safety.

The launcher creates an exclusive UUID directory, pins source/runtime/bundle
and controls, and checks original model metadata and payload aggregate before
and after. It never reads local model payloads. It saves raw native output,
bounded remote observations, metadata and the complete failure receipt.

The unchanged worker owns the native process group; the launcher owns the SSH
client and requests cancellation of the whole owned remote run on failure,
including an already-exited SSH client. Parent timeout, worker timeout and
native alarm remain separate bounds. `primary_failure`, `cleanup_errors` and
`post_run_errors` preserve distinct diagnostics. Local wait completion and an
empty remote PID observation are recorded without claiming independent remote
reaping proof. Root must resolve any surviving remote process before another
cohort. No unrelated host processes are targeted.

## Prospective validation

```sh
python3 -m unittest -v test_remote_solo_prefill.py \
  test_solo_reference_and_cleanup.py test_solo_launcher_flow.py
```

All tests prohibit real subprocess and socket creation. They cover inherited
resource/path/control guards, ready/report admission, distinct reference byte
pins, saved worker serialization, post-run file verification, malformed output,
deadline cancellation, and preservation of the primary failure when cleanup
also fails. A separate CPU-only check stages the actual pinned reference and
checks saved rank serialization; it loads no model and executes no native code.

The receipt makes no network, physical transport, warmed-model, throughput or
800-TPS qualification. A single solo diagnostic cannot establish a causal
comparison with earlier two-rank measurements.
