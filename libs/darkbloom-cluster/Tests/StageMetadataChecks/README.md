# Stage metadata checks

Run from any working directory on macOS; choose a fresh output directory whose parent exists:

```sh
python3 libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py --output /private/tmp/darkbloom-stage-metadata-checks
```

This compiles the current checkout's 17 Foundation Runtime sources, six retained fixtures, and the exact CheckpointManifest declaration extracted from current VerifiedCheckpoint.swift into the private output directory. No installed model, research directory, MLX module, payload read or network is required. The fixture retains the captured Gemma configuration/index/header bytes and Qwen metadata-only golden identities under Inputs.

The checks cover all29 Gemma cuts, exact selected/excluded/replica conservation, full source-to-local mapping, global attention phase and quantization relocation, malformed/refusal cases and three unchanged Qwen Plan/stage fingerprints. The first reviewed research execution passed191 accepted and36 refused cases. That result does not claim this relocatable launcher was executed; its initial repository integration is source-only until run.

The runner reuses the exact reviewed owned-child helper, observes post-reap groups without signalling them, bounds Swift compilation to60s/jobs2 and fixture execution to10s, and rechecks every source/input around execution. A diagnostic file larger than1MiB fails after child exit; this is not an in-flight IO cap. Output receipts are retained on failure.

Native construction, complete payload verification, measured KV dtype, resource fit and numerical execution are outside this fixture.
