# Initial supported backend and SSD comparison groups

> Last updated: 2026-09-05 · commit `82ce12db8`

GPT-OSS20B and the 8-bit Gemma4-26B artifact pass their initial B1 contiguous/paged
cache-off comparisons and paged SSD comparisons. Qwen3.5 passes both within-backend
SSD comparisons but fails both contiguous/paged comparisons. These are first
repetitions, with the original strict evaluator and unsupported cells preserved.

## Runtime and exact artifacts

All ten cells use the same build6 probe, native `a932d38`, production single-slot
grants, output budget 128 and original reviewed matrix inputs on M5 Max, 128 GiB.
Qwen and Gemma use their normal configured MTP assistants; GPT uses its normal
catalog setting with MTP off. Cache roots and ephemeral keys are isolated per run;
no resident prefix bank is enabled.

Probe SHA-256: `1b0df2f9ba18bf6738ae529adaf4e1ad9d7dc43f20dba54c244de71f517cbba3`.
Metal library SHA-256: `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.
These precede the later diagnostic and provider receipt-fix source; they do not
validate a rebuilt serving CLI.

| Model ID | Exact target aggregate SHA-256 |
|---|---|
| `qwen3.5-35b-a3b` | `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c` |
| `gpt-oss-20b` | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` |
| `gemma-4-26b` | `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6` |

Gemma's exact two-file assistant is unchanged. The [production Gemma QAT artifact](2026-09-05-gemma-qat4-initial-pairs.md)
is a separate target and is not covered by this backend comparison.

## Results

All ten individual cells pass integrity, tenant isolation, cancellation/recovery
and idle/shutdown checks. Root independently reran all eight available paired
comparisons: six pass and the two Qwen backend comparisons fail.

| Model | Prompt tokens | Actual output, contiguous / paged | Cache-off backend comparison | Paged off/SSD comparison |
|---|---:|---:|---|---|
| Qwen3.5 | 5,523 | 79 / 74, natural stop | Fail | Pass |
| GPT-OSS20B | 5,472 | 128 / 128, length stop | Pass | Pass |
| Gemma4-26B, 8-bit | 5,418 | 64 / 64, natural stop | Pass | Pass |

Qwen's first differing output is zero-based position 39: contiguous token 7042
versus paged token 5790 after 39 identical generated IDs and identical prompt IDs.
Both long-first and long-repeat reproduce that difference. Its contiguous
cache-off/SSD pair also passes; cross-backend tenant and recovery outputs differ.
The earlier [Qwen3.6 backend regression](2026-09-05-qwen36-backend-parity-regression.md)
remains unresolved. Neither failure is waived or attributed to a numerical cause
by these measurements.

Historical contiguous SSD is unsupported for GPT and Gemma. Those two cells were
not run, and the four comparisons that depend on them remain explicitly missing.
No legacy codec was added and no cold recomputation was counted as a cache hit.

## Initial latency observations

| Model and backend | Repeat TTFT, cache off | Repeat TTFT, SSD | Restored tokens |
|---|---:|---:|---:|
| Qwen3.5 contiguous | 1.269171417s | 0.410672708s | 4,096 |
| Qwen3.5 paged | 1.286522167s | 0.419749708s | 4,096 |
| GPT-OSS20B paged | 1.585373125s | 0.5223865s | 4,096 |
| Gemma4-26B paged | 1.181851417s | 0.422960625s | 4,096 |

These are single-pair TTFT observations, not repeated medians, decode-throughput
results or evidence of a general backend speedup. SSD donor terminal tails are
also retained: approximately 73ms for paged Qwen, 95ms for GPT and 141ms for Gemma.
Cache benefits and donor costs are separate from attention-backend correctness.

## Evidence and remaining gates

Root rehashed all 377 original frozen payloads, verified the ten raw reports with
the current strict integrity evaluator and reran the eight comparisons without
changing the oracle. Postflight checks preserve all target, runtime and assistant
identities. Owned model processes were stopped and run roots retained.

The [manifest](evidence/supported-backend-groups-2026-09-05/manifest.json) and
[archive](evidence/supported-backend-groups-2026-09-05/payloads.tar.gz) preserve
382 payloads (22,009,765 bytes), including raw runs, commands, input identities,
strict failures, unsupported-cell metadata, postflight checks and root review.
Every archived member was verified; model weights and compiled binaries are excluded.
Manifest SHA-256: `8078ce49cc651ab76b32bf7143b15fdee44f7d1de44591b21fee58e4d61509f5`.
Archive SHA-256: `1730bb604651b97905f79a5f712a199f3159bd912c0c0a8f6a13555cd602b0d0`.

Qwen numerical diagnosis, repeated B1/B2/B4 runs, context/capacity, all-model
connected HTTP, persistent-key restart, default promotion and release CI remain
separate requirements.
