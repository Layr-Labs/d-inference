# 064 — Blind qualitative ranking of approximate prefill profiles

Status: **complete; no ≥2.5× approximate profile is usable**

I scored the 12 fixed 64-token continuations from the E23 baseline and every
available E23–E26 quality report. Scores use only each prompt and generated
`text`; profile labels and throughput were attached afterward. Token-ID or
checksum disagreement is not a quality penalty. The shared 64-token truncation
is an instruction-completion limitation, not corruption.

Scale: 0–4; higher is better for coherence (C), relevance (R), instruction
adherence (I), and factual direction (F). Corruption (X) is reversed: 0 is
clean, 4 is repetition, control-token leakage, or unrelated text throughout.
Speed is the median per-case quality-run ratio to E23.

| Rank | Profile | Speed | C | R | I | F | X | Qualitative verdict |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| ref | `baseline-top8-all-layers` | 1.00× | 4.0 | 4.0 | 2.6 | 3.5 | 0.0 | Clean, relevant reasoning starts; usually truncated before the requested answer. |
| 1 | `topk4-all-layers` | 1.35× | 4.0 | 4.0 | 2.6 | 3.5 | 0.0 | Baseline-like on all 12; the only candidate that clears this small qualitative screen. |
| 2 | `artifact8-topk4` | 2.81× | 3.2 | 2.7 | 1.1 | 1.5 | 1.2 | **Least-bad artifact profile, but unusable.** Several starts remain on-topic, but critical cases drift or fail. |
| 3 | `artifact11-topk1` | 2.99× | 2.8 | 1.9 | 0.8 | 0.8 | 1.8 | Intermittently relevant; wrong prompt reconstruction, fabricated facts, and hard loops remain. |
| 4 | `topk1-all-layers` | 1.84× | 2.3 | 2.2 | 0.5 | 0.9 | 2.3 | A few useful starts do not offset empty fences, role leakage, repetition, and malformed tasks. |
| 5 | `blockpair-topk4` | 2.42× | 3.4 | 0.0 | 0.0 | 0.0 | 3.5 | Locally fluent but wholly unrelated Chinese/Indonesian documentation and code fragments. |
| 6 | `stride2-topk1` | 2.91× | 2.0 | 0.2 | 0.0 | 0.1 | 3.5 | Unrelated reconstructions, control-token leakage, and repetition across essentially every case. |
| 7 | `attn16-topk1` | 3.73× | 0.8 | 0.0 | 0.0 | 0.0 | 4.0 | Near-total collapse into repeated numbers, names, punctuation, and unrelated fragments. |

`artifact8-topk4` is not a close pass: it substitutes an `NSLock` cache for the
requested Swift actor, gives `0.05%` for the screening problem, loses the Python
task to meta-commentary, emits timestamps for the incident, and does not obey
JSON-only output. `artifact11-topk1` is worse, including table/semicolon loops,
a fabricated 12-liter hiking prompt, a false jailbreak diagnosis, and a
fabricated rewrite source.

The ≥2.5× conclusion is therefore **no usable candidate**. The measured B=4×2K
profiles `stride2-topk1` (2.72×), `artifact8-topk4` (2.58×), and
`artifact11-topk1` (2.57×) all fail the semantic gate. `topk4-all-layers`
demonstrates why token mismatch alone is not a veto—it remains baseline-like—
but its quality-run speed is only 1.35× (and its primary B=4×8K result was
1.192×), far below the objective.

Reports: `artifacts/e23-quality-{baseline,candidate}.json`,
`artifacts/e24-quality-{topk4,topk1,attn16,blockpair-topk4}.json`,
`artifacts/e25-quality-artifact8-topk4.json`, and
`artifacts/e26-quality-artifact11-topk1.json`.
