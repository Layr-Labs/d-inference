# Qwen3.6 contiguous versus paged output regression

> Last updated: 2026-09-05 · commit `47ece4b3c`

The first Qwen3.6 35B B1 comparison between contiguous and paged storage fails
strict generated-token equality. Both backends pass their own cache-off/SSD
comparison. A separate cache-off comparison with MTP disabled also differs.
Default promotion remains on hold; the numerical cause is not yet established.

All six cells use the same build6 probe, exact target aggregate and prepared
5,523-token prompt, a 128-token output cap and production single-slot grants.
The normal quartet has four fresh processes/roots: contiguous off/SSD, followed
by paged off/SSD. Both cache pairs restore 4,096 tokens and pass strict output,
tenant, restored cancellation/recovery and idle/shutdown checks within their
backend. Both cross-backend comparisons fail generated IDs and output counts.

| Cache-off comparison | Contiguous output | Paged output | First differing position, zero-based |
|---|---:|---:|---:|
| Normal adaptive MTP | 78 tokens, natural stop | 79 tokens, natural stop | 53: token7244 versus2919 |
| MTP off | 83 tokens, natural stop | 83 tokens, natural stop | 62: token1928 versus6829 |

Each backend repeats its own complete output identically. Prompt IDs, model
aggregate, input hash and runtime identity match across each comparison.
Normal MTP uses rectangular verification with zero serial rounds. Its aggregate
depth/round distributions differ between backends; these counters do not expose
actual per-position tensor geometry and cannot establish the cause of a token
difference. The MTP-off result establishes that the discrepancy is not confined
to speculative execution. It does not identify a particular kernel or operation.

The diagnostic changes only the MTP flag and fresh output paths from the
corresponding cache-off commands. Production grant calculation remains enabled;
omitting the assistant changes its normal loaded-weight inputs. Neither these
diagnostics nor the failed backend comparisons establish performance gains.
The original strict evaluator and all failed verdicts remain unchanged.

Target aggregate: `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`.
Native source: `a932d38cee0beca41ca1a0e71c1e867913a65353`.
Probe: `1b0df2f9ba18bf6738ae529adaf4e1ad9d7dc43f20dba54c244de71f517cbba3`.
Root reverified all 77 frozen normal-quartet payloads and all 36 diagnostic
payloads. The next investigation captures actual logits and selection geometry
at the first differing positions through the normal request-owned state path.
No precision change, serial production override or tolerance waiver is implied.

The [manifest](evidence/qwen36-backend-parity-regression-2026-09-05/manifest.json)
and [archive](evidence/qwen36-backend-parity-regression-2026-09-05/payloads.tar.gz)
retain 119 payloads (6542839 bytes), including raw reports, commands, telemetry,
strict verdicts, frozen manifests, first-difference analysis and binding review.
Manifest SHA-256: `e1a7ce6df00fc96659399ded818d0dc36f9263098a992ac62da696bdf20c521f`.
Archive SHA-256: `0187ce07d5c7bde4a98aaf5a8ca90ff366a72e1504a1b2a6a8188f20f97c8859`.

Related: [earlier paged-only Qwen3.6 pair](2026-09-05-qwen36-coherent-paged-pair.md),
[normal Qwen3.5 same-budget pairs](2026-09-05-qwen35-useful-tail-pairs.md).
