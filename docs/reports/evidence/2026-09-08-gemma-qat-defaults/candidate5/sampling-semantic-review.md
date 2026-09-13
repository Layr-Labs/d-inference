# Candidate 5 sampled adaptive/off pair

> Last updated: 2026-09-08 · commit `4ae34f033`

All six adaptive outputs were read against the synthetic source, matched sampled-off answers and prior greedy controls. Both reports use the same candidate5 binary and identical per-row prompt token IDs. Every on/off row records identical `sampling` values: temperature 0.699999988079071, top-p 0.8999999761581421, top-k 40, seed 4242, with zero frequency/presence penalties, repetition penalty 1 and empty logit bias. These are the requested 0.7/0.9 values represented as Float32. Nonzero-temperature MTP is actually exercised, not merely enabled in configuration.

## Generated content

**Code-first and code-repeat both pass the completed-prefix source-isolation probe.** The same event ID under station-01 and station-02 is accepted twice, with valid aggregate 20. Neither reproduces the global-ID rejection defect seen in three greedy adaptive outputs. Both preserve frozen Event semantics, reject identical/conflicting same-source retries without overwriting, and compute valid-reading aggregates. Both still accept naive datetimes despite the timezone-aware task requirement, as do their sampled-off controls.

Adaptive code-first sorts by sequence; adaptive code-repeat preserves insertion order, matching the respective sampled-off variants' observed behavior. The task does not explicitly name a sort key, so this is retained as a distinction rather than inventing a stronger sequence-sort requirement. Adaptive code-repeat documents ValueError for malformed data but a missing source raises KeyError; the malformed record is still rejected. This exception-contract weakness is retained in the executable evidence. Invalid timestamps are rejected in both variants. Generated test sections are cap-truncated; their missing later tests are not treated as an engine failure.

Both adaptive prose outputs remain coherent and preserve the five districts' priorities, access/maintenance tradeoffs, proposed pilot measures, published review and absence of approved funding. No invented survey counts or existing funding commitments were found. Adaptive prose-first adds an unprovided “high concentration of educational staff” in Orchard; interviewing teachers does not establish that district demographic. Its author and September 15 memo date are also generated rather than source facts. Adaptive prose-repeat adds minor attributed rationale about school commutes and generic planning claims not explicitly supplied in the notes. These are factual/attribution weaknesses, comparable in kind to sampled-off's unsupported mobility-corridor/high-traffic descriptions; they are not marked exact semantic equivalence. Proposed feasibility work, evaluation methods and timelines remain recommendations.

All four sampled extraction outputs are text-identical, also matching the greedy controls. Eight complete project objects P001–P008 match all 72 fields/types, including requested-versus-approved funding. The Markdown JSON fence remains an instruction defect and P009 is cap-truncated. A complete valid JSON response is not claimed.

The sampled code answers add useful contrasting trajectories but do not erase the repeated source-isolation defect in greedy adaptive evidence. These few cases cover one coding prompt, one prose prompt and one extraction prompt; they do not establish a broad quality rate or prove sampling-distribution equivalence.

## Exposure and measured speed

| Case | MTP rounds | Accepted / proposed | Depth0 / depth1 selections | Adaptive speed change |
|---|---:|---:|---:|---:|
| code-first | 396 | 345 / 396 | 272 / 406 | +6.35% |
| code-repeat | 502 | 439 / 502 | 77 / 508 | +9.47% |
| prose-first | 104 | 61 / 104 | 851 / 112 | −1.80% |
| prose-repeat | 144 | 90 / 144 | 782 / 152 | −1.30% |
| extraction-first | 511 | 506 / 511 | 5 / 512 | +16.79% |
| extraction-repeat | 511 | 506 / 511 | 5 / 512 | +17.55% |

All rounds are rectangular, zero serial. Counters are per-row before/after deltas; depth selections include seed/tail planning and do not equal completed rounds. All off rows have zero MTP rounds. Gains were independently recomputed from report decode TPS. Code/prose compare matched inputs with different generated trajectories; extraction provides identical-output comparison. Only one sampled paired run was measured; reverse-order repetition was performed for the separate greedy pairs.

All 12 sampled rows finish `length` at 1024 with matching token-ID counts. Adaptive prose-first happens to end with a coherent closing phrase, but its recorded termination is still the cap, not EOS. No raw special-token marker was found in reviewed text; these runs do not certify natural-stop stripping. Repeated SSD hits restore 8192/4096/6144 tokens for code/prose/extraction with zero replay. Parent reports both structural harness verdicts passed with zero errors.

Evidence: `candidate5-sampling-pair1-semantic-evidence.json` and baseline `candidate5-b1-sampling-off1-semantic-evidence.json`. Reproduction: `review_candidate5_sampling_pair.py`, executing only manually inspected complete generated implementation prefixes. Scope is one M5, synthetic tasks, raw engine events and local assistant bytes; this is not an HTTP fleet-scale or public-download validation.
