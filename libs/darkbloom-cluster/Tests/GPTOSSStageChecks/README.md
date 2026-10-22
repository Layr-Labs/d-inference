# GPT-OSS layer-stage metadata checks

```sh
bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh
```

Compiles the GPT-OSS adapter's MLX-free sources (registered specification,
stage plan, quantization and tensor metadata, arithmetic contract, request
state ledger, capability record) with Swift 6 and warnings as errors in a
temporary directory, and runs deterministic checks against byte-exact copies of
the registered artifact's `config.json` and `manifest.json`. No model, no
weights, no GPU. It shows that the metadata is closed and self-consistent; it
does not show that a stage loads or computes anything. Loading and generation
are recorded as real runs, never simulated here.
