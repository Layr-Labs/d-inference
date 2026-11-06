# Private full-model generation reference

This overlay adds a real single-request reference entry to the existing experimental full-model harness. It preserves the original frozen harness and main repository. The entry loads one complete registered Qwen3.5 9B model, runs the frozen full CBv2 generation reference, retires request state, releases the model, and emits CPU evidence. It does not use a stage forward, transport, teacher forcing or MTP.

`integration.json` maps 24 sources: fourteen exact helper copies, seven new entry/CLI/resource/check helpers, and two existing loader wrappers plus private Main replacement. The fourteen include the frozen five reference files with the native-error V2 override, its narrow CBv2RequestSession clean-EOS change, the seven generation value/control files, and the existing resident request-resource helper. The actual full-model type remains the experimental `LoadedModel`. No full loader is copied into the shared serving runtime.

Example after the separately supervised build:

```sh
cluster-inference --mode qwen-full-generation-reference \
  --model-dir /absolute/registered-9b \
  --tokens-file /absolute/prompt.json --tokens-sha256 RAW_PROMPT_SHA256 \
  --request-id 00000000-0000-0000-0000-000000000017 \
  --stage-cut 4 --output-count 128 --stop-token-ids '[]' --timeout-seconds 300
```

All nine pairs are mandatory. Paths are absolute; UUID/SHA and integers are canonical. The source profile is fixed registered 9B, prompt 8192, chunk 512, batch 1, greedy BF16, MTP off; output count is 1...128, cut 4|8|12|16. Stop IDs use a sorted unique bounded integer-array spelling without whitespace. Match these values and the request UUID to the candidate. Empty stops force the output limit; otherwise the frozen helper permits clean EOS. The same profile/UUID does not itself establish numerical equivalence.

The first JSONL record is `qwen_full_generation_reference_admitted`, explicitly before verified model loading. The final `qwen_full_generation_reference_report` follows successful request retirement and weak model-release verification. Its `execution` is the unchanged full-reference result: all selected tokens, compact per-token full-row identities, last full vocabulary row, final whole-model state metadata/hashes, and diagnostic clocks. The nested helper's `modelRemainsResident` describes its return point; the outer producer then releases the model before emitting the report. It contains no raw prompt or state bytes. Each encoded record is capped at 16 MiB. The final runtime metadata remains reported data, not binary/hardware attestation. Native exit and complete output still require parent validation.

Two optional hooks are threaded through the existing baseline/diagnostic loader. Nil hooks retain old caller behavior. This entry supplies the expected raw manifest SHA, an actual prepared descriptor/read-plan callback, per-tensor callback and live check. The materializer loop, legacy source/host caps, BF16 conversion, full-model layout checks and source FD verification are unchanged. The new prepared hook constructs the registered profile from the exact verified descriptor metadata and checks the raw configuration/manifest/artifact binding before any payload read.

The loading ledger uses actual per-array bounds for remaining full weights R and largest host tensor H. It derives full-state allowance at P+O once, both disjoint fusion banks, two simultaneously retained CPU logit rows, and the current native row/Float32 conversion arrays. The old output-one state receipt remains metadata only. The live policy requires actual free at least `max(6 GiB, R + 2H + full request reserve + 4 GiB)`; allocator requirements include active/cache, R, H, state/fusion/native capture and the existing 2 GiB headroom. CPU capture storage is not counted as a Metal allocation. Every actual observation retains zero swap, pressure 0...2, AC, normal power mode and nominal/fair thermal requirements. No memory limit/cache setting is changed. Named terms and encoding caps are not whole-process peak proofs.

Per-tensor hooks run before the current payload read. Remaining R advances only in the fixed ordered materializer path; complete source counts/bytes and its verified receipt are checked before request admission. Request/capture callbacks keep resource and absolute-deadline checks active. A process alarm covers initialization, blocked native work and output; the parent must still supervise and fence the process. Error cleanup synchronizes and clears cache without calling an expired deadline check, preserving the primary failure and reporting cleanup errors. No success report is emitted on failure.

Validation is pending full native typecheck. All 24 sources syntax-parse. The source check verifies fourteen exact helper hashes and byte-identical materializer/legacy storage-validation bodies. The new native CPU check is `--mode qwen-full-generation-reference-check`, with `DARKBLOOM_RETAINED_PROFILE_FIXTURE` pointing to the existing retained metadata fixture. It exercises actual CLI/source admission, O1/O128 geometry, all four cuts, malformed controls/pins/arithmetic, full state/fusion/capture arithmetic, per-array bounds/overflow, and ordered source accounting without MLX allocation, model load or network execution. Expected source-derived counts are 16 accepted/32 rejected; execution has not yet confirmed them.

The first actual native run and fresh candidate/reference comparison remain root-owned hardware work. This source package and the prior cut4/output-one success do not qualify O128 correctness or serving performance.
