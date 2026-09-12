# Gemma QAT4bit native KV observations and initial paged SSD pairs

> Last updated: 2026-09-05 · commit `12e941bb1`

The exact production `gemma-4-26b-qat-4bit` artifact passes its target KV observer
and two normal-MTP paged B1 cache-off/SSD comparisons on M5 Max, 128 GiB.
The unchanged strict evaluator accepts exact same-budget outputs, tenant isolation,
restored cancellation, recovery and idle/shutdown retirement at output caps 32 and 128.

## Exact artifact and runtime

Target aggregate: `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`.
This is distinct from the earlier [8-bit `gemma-4-26b` observations](2026-09-05-five-model-native-kv-probes.md)
for aggregate `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6`.
The QAT prompt contract is `b6bf2b40c2a734956584814dc13d6530d8895ad51de8031e77d37fb1d35ebb67`;
its pinned template and exact ten-file target manifest remain in the evidence.

Normal MTP uses `mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit`, aggregate
`d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34`.
Its flat config and weight files match both the external manifest and loaded
assistant identity; postflight checks preserve exact target, assistant and runtime hashes.
Build6 probe: `1b0df2f9ba18bf6738ae529adaf4e1ad9d7dc43f20dba54c244de71f517cbba3`.
Native source: `a932d38cee0beca41ca1a0e71c1e867913a65353`.
Metallib: `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.
This probe does not establish acceptance of a serving CLI.

## Measured observations

The target-only observer records 60 incoming K/V writes across 30 owners, all
BF16: 25 owners have eight KV heads of width 256; five have two heads of width 512.
`RecordingRow.update` observes two incoming prefill positions and one incoming
decode position, not accumulated cache lengths. K/V shapes agree in each phase.
This mode creates no serving backend, MTP assistant or SSD store and records no query dtype.

Both serving pairs use the same 5,418-token prompt, production single-slot grants,
normal rectangular MTP with zero serial rounds, fresh process roots, ephemeral
encryption keys and no resident prefix bank. Restores are direct, with zero replay tokens.

| Output cap | Actual output | Repeat TTFT, cache off | Repeat TTFT, SSD | Restored tokens |
|---|---|---:|---:|---:|
| 32 | 32, length stop | 1.0994165s | 0.44426175s | 4,096 |
| 128 | 38, natural stop | 1.098444584s | 0.396376s | 4,096 |

The first 32 generated IDs also agree across these two budgets. This is an observed
prefix agreement, not a general budget-invariance guarantee. Repeat TTFT savings
are 0.655s and 0.702s in these initial samples; no repeated-performance or decode
speedup claim follows. SSD repeat staging takes 83.528417ms and 83.69475ms.
First-miss terminal tails are 0.000233583s/0.131587291s (off/SSD) at cap 32 and
0.000321959s/0.134350333s at cap 128, including terminal checkpoint work.

## Evidence and remaining gates

Root verified all 252 frozen source payloads and independently reran the current
strict comparator on both pairs: both pass without errors. Its separate observer
review explicitly corrects an initial accumulated-shape assumption; no source or
runtime change was needed. The original five-model fixtures remain unchanged.
Contiguous/paged equality, repeated B1/B2/B4 performance, context/capacity, tools,
vision, connected HTTP, persistent-key restart and default promotion remain separate gates.

The [manifest](evidence/gemma-qat4-initial-pairs-2026-09-05/manifest.json) and
[archive](evidence/gemma-qat4-initial-pairs-2026-09-05/payloads.tar.gz) retain 256 payloads
(5,181,943 bytes): raw runs, commands, comparisons, exact manifests, source plans,
runtime provenance and root reviews. Compiled/model binaries and two unexercised
vision-asset copies are excluded; their identities remain pinned. Every archive member was verified.
Manifest SHA-256: `58dce02dbc0db10fce9cd8b5c37a184f4facbd9389ca94128c6ecd27643628ca`.
Archive SHA-256: `eda7c6738e64f3be8aaa7004be034d7ef4990cfe58638556f5e2d92203db1ef2`.
