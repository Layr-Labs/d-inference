# Qwen3.6 paged SSD pair with coherent idle observations

> Last updated: 2026-09-05 · commit `9e49059a1`

Qwen3.6 35B passes a fresh paged B1 cache-off/SSD pair on M5 Max 128GiB.
The unchanged strict evaluator from `437bea4fe` accepts exact prompt/output tokens,
tenant isolation, restored cancellation, recovery, and idle/shutdown retirement.
This is one initial correctness pair; repeated performance and release acceptance remain pending.

Both arms use normal MTP, 5,523 prompt tokens, 32 output tokens, production-derived
single-slot KV grants, ephemeral keys, fresh roots and no resident prefix bank.
The exact target aggregate is `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`.
The build5 probe is `eee66c9aaefa1b01dc696c551f8b98e7e89515b9389f4d53324c2302ccd3fa11`,
with original native source `aafe2069bcdeadef9250530eb511c598649c0355` and wrapper
`b5166c413e72f871ff8ebe17493b4628a8f0479e9eba376b0090eb65e3db29a1`.
This pair does not validate the subsequently banked useful-tail planner `a932d38`.

| Single paired observation | Cache off | SSD enabled |
|---|---:|---:|
| First-request TTFT, both misses | 1.932974167s | 1.369186917s |
| Repeat TTFT | 1.285671833s | 0.434607416s |
| First-request terminal tail | 0.000127375s | 0.074767250s |
| Repeat terminal tail | 0.000208208s | 0.000133541s |

The repeat and primed cancellation restore 4,096 prompt tokens. First-request
terminal tails include checkpoint work but are not isolated capture timers.
Ordered single observations do not establish decode, contiguous-versus-paged,
throughput or repeated latency gains.

All 20 idle observations report ready on the first attempt; the longest observation
is 52.208μs. The [bounded observation harness](2026-09-05-coherent-idle-harness.md)
keeps those waits outside request timing. Root independently rechecked all 50
frozen payloads and reran the current strict evaluator: zero errors.
The [original failed Qwen3.6 snapshots](2026-09-05-final-cache-evidence.md) remain unchanged.

The [manifest](evidence/qwen36-coherent-paged-pair-2026-09-05/manifest.json) and
[archive](evidence/qwen36-coherent-paged-pair-2026-09-05/payloads.tar.gz) retain 52 payloads
(2,048,459 bytes), including the original freeze manifest and independent review.
Manifest SHA-256: `6c23f30ccbe818a0ee54478f219682ea188da79956343d6d25f8f29efc44971c`.
Archive SHA-256: `4b9ffed2dd25520de4594fa25b7f2b67c73f7024183c30ba1b615c5ac54f5b9d`.

Normal Qwen3.5 parity, repeated B1/B2/B4 measurements, contiguous controls,
long-context capacity, connected HTTP, eviction, persistent restart and rollback
remain separate release gates. Production defaults and deferred 0.9.1 work are unchanged.
