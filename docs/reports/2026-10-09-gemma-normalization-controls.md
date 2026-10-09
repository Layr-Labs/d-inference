# Gemma 4 shared-normalization controls

> Last updated: 2026-10-09

This completed experiment retains native production normalization because the
shared-normalization candidate failed its preregistered measured-benefit gate.

The shared global K/V projection can reuse the unweighted RMS normalization before applying the learned K scale. The pinned CPU and Metal operators round the normalized projection to the output dtype before scaling. A helper tested that relationship for matching FP16, BF16 and FP32 dtypes; mixed learned-scale dtypes retained the original weighted operator. Those two tests passed with native storage-bit comparisons, nonuniform scales and widths 32, 256 and 512.

This mechanism does not reduce the stored K/V tensors. It removes a repeated reduction. The real-model experiment did not meet its preregistered benefit gate, so the helper is preserved as a patch and is not pinned into serving.

## Actual model comparison

The original native normalizer and the candidate were separate signed SDK revisions, `45fedc12e55075072faa16871992119ad5e77c27` and `f4fb61cefc202670a9468874a4d6cc96d6074f66`. The first changes only benchmark receipt recording and formatting; it retains the original Gemma implementation. Both were built in release mode with system Swift 6.4, the same local MLX Swift/core revisions and an identical source-matched metallib. Archived build receipts include source, binary and metallib hashes. The portable candidate patch reproduces the second revision's source delta.

The local `gemma-4-26b-qat-4bit` checkpoint ran on Apple M4 Max with 128 GiB RAM. Inputs were the benchmark's seeded synthetic token IDs. The campaign ran 24 separate process cells: prompts of 128 and 4,096 tokens, B=1 and B=2, 64 generated tokens per request and three counterbalanced native/candidate pairs per shape. Each image performed the same warmup. The campaign owned the exclusive model lease; no local build ran during measured cells.

All **1,152 candidate tokens**, finish reasons and prompt/completion counts matched their paired native controls. Native repeats were stable. This establishes bounded synthetic continuation identity; it is not a task-score, long-context or storage-format qualification.

Median timings across each arm's three runs:

| Prompt | Batch | Native ITL ms | Candidate ITL ms | Native TTFT ms | Candidate TTFT ms |
|---|---:|---:|---:|---:|---:|
| 128 | 1 | 8.640 | 8.612 | 112.791 | 113.115 |
| 128 | 2 | 11.108 | 11.041 | 179.419 | 178.514 |
| 4,096 | 1 | 10.316 | 10.262 | 2,562.061 | 2,589.260 |
| 4,096 | 2 | 14.285 | 14.382 | 5,462.497 | 5,120.874 |

The preregistered gate required at least 1% geometric-mean paired ITL improvement and no cell median ITL or TTFT regression above 2%. The observed paired ITL ratio was **0.997324**, a **0.27% improvement**. The token-identity gate (recorded as `quality_gate`) passed; the benefit gate failed. The 4K/B2 TTFT median was lower, but one paired sample was neutral, and the overall gate was not met. No larger performance claim is made from that cell.

## Evidence and reproduction

- [Preregistered plan](evidence/gemma-normalization-2026-10-09/preregistration.json), [summary](evidence/gemma-normalization-2026-10-09/summary.json), [complete cell receipts](evidence/gemma-normalization-2026-10-09/runs.json) and [artifact hashes](evidence/gemma-normalization-2026-10-09/artifact-manifest.json).
- [Native build](evidence/gemma-normalization-2026-10-09/native-build.json), [candidate build](evidence/gemma-normalization-2026-10-09/candidate-build.json) and [portable candidate patch](evidence/gemma-normalization-2026-10-09/normalization-candidate.patch.gz).
- The [raw cell archive](evidence/gemma-normalization-2026-10-09/raw-cell-reports.zip) retains all 24 original `.md` filenames and byte streams, including complete token identities. Its [archive receipt](evidence/gemma-normalization-2026-10-09/raw-cell-report-archive.json) pins the container and members; the unchanged artifact manifest pins each original payload. Sibling `.log` files retain invocation, host, provenance and process-memory receipts. The archive keeps generated measurement output separate from maintained documentation.
- [Original campaign driver](evidence/gemma-normalization-2026-10-09/gemma-native-normalization-controls.py) and [original operator probe](evidence/gemma-normalization-2026-10-09/gemma-raw-kv-probe.py), with [source hashes](evidence/gemma-normalization-2026-10-09/original-script-manifest.json), preserve the exact experiment scripts before the validation cleanup.
- The [current campaign driver](../../scripts/benchmarks/gemma-native-normalization-controls.py) uses explicit image-hash guards, complete generation identities and a unique lease owner. Its pure summary helper reproduces the archived summary without changing thresholds or measurements.

Build the receipt-only native SDK revision using the ephemeral local-MLX recipe in [developer tests](../developer/test.md), archive the release binary, metallib and runtime bundles, then apply the candidate patch in an isolated checkout and build the second image. The patch applies to `45fedc12e55075072faa16871992119ad5e77c27` and reproduces the complete candidate tree `420b728c60e39145d4890c2649b474db7b4d04e7` at `f4fb61cefc202670a9468874a4d6cc96d6074f66`; it does not repeat the receipt change. The campaign's invocation and build receipts identify the tested artifacts; its weight inventory records paths, sizes and mtimes, not a freshly recomputed full checkpoint aggregate hash. Future model-bound storage qualification must verify the actual model aggregate and native K/V/Gamma payloads.

The separate [single-projection operator investigation](2026-10-09-gemma-shared-projection-kv.md) rejected full historical reconstruction because of its attention cost. A native V512 plus retained rotated-K128 encoding remains a separate proposal. Its real native K/V relationship, sequential import traffic, charged tile bounds and checkpoint restoration are unqualified here. It makes no INT4/Hadamard composition claim.

The native-state follow-up uses the same unmodified native model math and separately verified model aggregates. Its public [Gemma packet receipt](evidence/native-kv-packets-2026-10-09/gemma/receipt.json) proves the unrotated K relation for all five global owners at positions 32 and 33; the [GPT packet receipt](evidence/native-kv-packets-2026-10-09/gpt/receipt.json) captures the BF16-to-FP32 native layer transition. The [raw-basis CPU prototype](evidence/gemma-native-basis-2026-10-09/probe/summary.json) restores all ten Gemma pairs byte-identically with eight-row tiles. It stores 62.5% of native global tensor bytes but reads 112.5% of the original scalar bytes during sequential K-then-V restoration. This is not encrypted production-import qualification. The 20 MiB charged host bound and traffic gates are [preregistered separately](evidence/gemma-native-basis-2026-10-09/preregistration.json).
