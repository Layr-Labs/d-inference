# True Qwen/Gemma TP: bounded evidence read — 2026-09-20

The existing strict failures remain failures. The compared paths split tensor inner products and reduce partials; whole-layer pipeline and whole-expert EP are separate algorithms. This read uses the12 small pinned sources/receipts in`inputs.json`, not new hardware, payloads or recomputation of raw logits. Numeric summaries in`retained-comparison-summary.json` retain all original cases.

| Scope | Max absolute error | Worst row relative RMS | Argmax |
|---|---:|---:|---|
| Real Qwen9B FFN/native, local two-process M4 Pro |0.1875|0.01586730664|4/4 match|
| Real Qwen9B full/native |0.1875|0.01633654258|4/4 match|
| Real Qwen9B FFN/both-wide |0.1875|0.01572166050|3/4; first4087→10926|
| Real Qwen9B full/both-wide |0.1875|0.01375166936|3/4; first4087→10926|
| Tiny Gemma mixed BF16/native, seed7 |0.1912764|0.060146512095|7/8; row4 token51→271|
| Tiny Gemma mixed BF16/native, seed31 |0.86206334|0.228170394800|8/8|
| Tiny Gemma mixed BF16/native, seed101 |0.7991529|0.249861762161|7/8|
| Tiny Gemma BF16/F32-branch, original two remaining failures |0.05858474 /0.05072674|0.015448485968 /0.015069835156|8/8 each|
| Tiny Gemma BF16/F32-through-norm, six-seed matrix |up to0.05077896|up to0.015319155866|96/96 paired, but4/12 pairs fail strict gate|

Gate remains maximum absolute<0.001, every row relative RMS<0.0001 and equal argmax. Qwen's8 M4 Max and16 M4 Pro matched rows all fail; peers matching each other does not repair solo disagreement. Gemma fully F32-parameter tiny controls pass (worst relative RMS≈2.38e-6), but they are a different arithmetic/model-memory policy. Through-norm changes ordinary native solo by maxabs1.5932577 / worst relative RMS0.493784773898 and4/96 argmax changes. The prior F32-branch policy changes native solo by maxabs0.84647844 /relative0.249677778060 and1/64 argmax changes.

These are teacher-forced short rows. Qwen uses actual registered9B weights; Gemma TP uses H128/four-layer/four-expert synthetic models, not actual26B. Existing Gemma pipeline and current EP work do not provide actual26B true-TP quality evidence. No TP held-out likelihood, perplexity or free-running task-quality evaluation is present in these archives. Other ordinary single-host model-quality reports do not qualify these TP arithmetic modes.

## What the operator evidence does establish

Qwen's first GDN input projection differs before convolution, recurrent state or network reduction: full N12352 versus selected N6176 at M32/K4096 produces125,801/395,264 differing values, max0.25/relative0.002689177293. Padding the selected affine-zero rows to full width then cropping reproduces all395,264 native values. FP32 ranks nearly agree with FP32 full (max9.1552734375e-5/relative7.00219207e-7), but widening changes104,168 native BF16 values. The source predicts split-K1 versus2; actual dispatch was not traced. Width-sensitive arithmetic is demonstrated; split-K as the sole cause and correctness of every downstream shard are not proven.

Gemma's captured F32 branch reductions match384 independently rounded CPU sums. Reconstructed expert selections have zero set/order changes in those four cases. The first reduced boundary differs by at most5.960464477539063e-8, and the cast audit verifies860,160 BF16 values with zero rounding errors. At one actual coordinate, solo−0.17529296875 and TP−0.1752929538488388 round correctly to−0.17578125 and−0.1748046875. The1.49e-8 difference becomes0.0009765625 and survives normalization. This directly demonstrates cast amplification; it does not explain every final logit or prove general sharding correctness. Moving the cast fixes selected seeds and breaks others.

## Separate arithmetic-mode qualification needed

Keep the strict diagnostic gate and its failures. Before a separate mode can be practical, independently validate partition coverage/quantization inverse, per-head/expert identities, norm placement and ordered reduction; capture first divergences at actual registered shapes and compare against an independent higher-precision operator oracle. No forced baseline routes or changed teacher tokens may hide a partition error.

Then compare three explicit policies on the same registered weights/tokenizer: ordinary full-model baseline, full-model candidate arithmetic, and TP candidate arithmetic. Pre-register held-out likelihood/perplexity and token-distribution metrics, repeated free-running task/coding/reasoning evaluations with confidence intervals, representative prompts/context lengths and cancellation/state-isolation checks. Calibrate a distinct quality acceptance decision against baseline variability and intended use; do not retroactively lower the current strict thresholds. Only after that decision and actual memory/communication/latency measurements can a separate arithmetic policy be considered. Neither rounding differences alone nor matching argmax on these few rows establishes acceptable quality or speed.
