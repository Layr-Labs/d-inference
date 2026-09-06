# Qwen3.5 normal speculative decoding and SSD cache pairs

> Last updated: 2026-09-05 · commit `6cae0b866`

Qwen3.5 35B passes two fresh paged B1 cache-off/SSD comparisons after the
[useful-output-budget policy](2026-09-05-mtp-output-budget.md). The unchanged
strict evaluator accepts exact outputs within each budget, tenant isolation,
authenticated restored cancellation, recovery and idle/shutdown retirement.
These are initial correctness pairs, with separate output caps of 32 and 128.

Both pairs use normal adaptive rectangular MTP, with zero serial rounds,
production-derived single-slot KV grants, ephemeral keys, fresh owned roots,
no resident prefix bank and the same approximately 5,500-token input prompt.
Target aggregate: `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c`.
Native source: `a932d38cee0beca41ca1a0e71c1e867913a65353`.
Build6 probe: `1b0df2f9ba18bf6738ae529adaf4e1ad9d7dc43f20dba54c244de71f517cbba3`.
The release probe compiled in 246.949 seconds; its build/source/resource proof is
retained. The existing serving CLI is a different artifact and is not validated here.

| Output cap | Actual output | Repeat TTFT, cache off | Repeat TTFT, SSD | Restored tokens |
|---|---|---:|---:|---:|
| 32 | 32, length stop | 1.285783417s | 0.420315084s | 4,096 |
| 128 | 74, natural stop | 1.284885333s | 0.421934834s | 4,096 |

At the 32-token cap, repeated cold and restored outputs consistently end in token
944. At the 128-token cap, token 32 is consistently 19549 in cold and restored
outputs. This establishes same-budget cache parity; it does not establish
invariance when the output budget changes or identify the numerical cause of
that difference. The longer test moves the earlier mismatch position into the
interior of the output instead of only checking a shortened final boundary.

First-miss terminal tails are 0.000189458s/0.073704208s for cache off/SSD at cap32,
and 0.000166167s/0.075115458s at cap128. These include terminal checkpoint work;
they are not isolated capture timers. Natural stop remains authoritative. Neither
pair is a 128-token decode measurement or repeated throughput evidence.

Root verified all 62 frozen payloads for each pair and independently reran the
current strict evaluator on both sets of frozen reports: both pass with no errors.
The [previous normal and SERIAL diagnostic failures](2026-09-05-mtp-output-budget.md)
remain preserved. Broader same-runtime B1/B2/B4, contiguous controls, context and
capacity, connected HTTP, durable restart and default rollout gates remain open.

The [manifest](evidence/qwen35-useful-tail-pairs-2026-09-05/manifest.json) and
[archive](evidence/qwen35-useful-tail-pairs-2026-09-05/payloads.tar.gz) retain
154 payloads (5241482 bytes), including build6 provenance and root review.
Compiled model/runtime binaries are excluded; their identities remain pinned.
Manifest SHA-256: `847be03caa5bf78c4fb300e64cf83cdfeebeac2ff8a11a70b1684fbad3491d1b`.
Archive SHA-256: `37f0666942f31057dee6da5d8ab94479ee0fbeb6ab0023488525c7f83b88ffeb`.
