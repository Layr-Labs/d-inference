# GPT-OSS B2 cache divergence — retained failed pilot

> Last updated: 2026-09-06 · commit `5073f696d`

Frozen evidence record for inference reviewers: strict cache parity **fails**;
strict backend comparison **passes only for the retained cache-off arms**.
There is no accepted performance or quality claim, and no restoration fix.

## Scope and verdict

The retained M5 pilot runs `gpt-oss-20b`, one repetition of three arms, MTP off,
explicit backends, SSD cache mode, and a loaded production single-slot KV grant
of 107860842572 bytes (no fixed-grant override). Each arm has `long-first` and
`long-repeat` cohorts with concurrency two: twelve measured rows in total,
each with the same 5472 prompt token IDs and 128 output tokens, finishing by
`length`. These are actual B2 cohorts, not a B1-only experiment.

| Retained arm | First b0 / b1 | Repeat b0 / b1 | Strict result |
|---|---|---|---|
| Contiguous, cache off | A / B | A / B | Baseline |
| Paged, cache off | A / B | A / B | Backend comparison passes all four same-ID rows |
| Paged, cache on | A / B | B / B | Cache comparison fails `long-repeat-b0`: `token_ids` |

A and B denote **complete 128-token vectors**, not prefixes: five rows follow
A and seven follow B. They first differ at zero-based index 3 (`976` versus
`2167`) and differ at 123 positions. Both cache-off arms already have different
b0/b1 trajectories despite identical prompts. Cached repeat b0 matches every
b1 vector, but not its own uncached b0 oracle or cache-on b0 donor. Both repeat
cache hits report 5120 saved tokens; this does not clear the failed parity gate.
The cache-on cell also fails completed-donor/repeat output integrity.

## Observation is not causation

Completed target-decode counters contain widths one **and** two. The five
uncached/cold cohorts each record 20 width-one and 118 width-two calls; cached
repeat records 1 and 127. Chunk timing places b0's token-3 emission before b1's
first emission in those first five cohorts, but after it in cached repeat.
These are emission coordinates and aggregate counts, **not the selecting
forward's width at token 3**, which remains unknown.

[INFERENCE] The cross-row pattern is consistent with a batching/scheduling-
dependent numerical path. The retained source audit identifies conditional
small-M linear routes as candidates, not dynamically observed causes.
Byte-exact restored KV equality and the first divergent kernel remain unproven.
Another row is not a substitute oracle; backend parity does not establish
cross-row determinism, general B2 correctness, or cache restoration correctness.
Timing is retained as diagnostic evidence only, not an accepted speedup.

## Provenance and bounded retention

Historical runtime parent is `682e268ed3ab54f85371d079204f8091f911afd8`, native
source is `ff1aab108da0d575258ba9425d5b763c0045ba66`; exact Plan3 evaluator helpers
are frozen separately from that parent checkout. The initial controller's
pending-comparison stop and its non-rerunning continuation remain in the raw
receipts. The final failed cache gate is unchanged. Proposed causal traces in
the later ROOT review are not results or authorization for another model run.

- [Safe capsule](evidence/gptoss-b2-cache-divergence-2026-09-06/gpt-b2-raw-capsule2.tar.gz): 816609 bytes; 85 inventoried files plus the manifest (86 regular archive members), including 56 byte-exact raw files.
- [Exact capsule manifest](evidence/gptoss-b2-cache-divergence-2026-09-06/capsule-manifest.json): per-file hashes and original raw-file identities.
- [Bank manifest](evidence/gptoss-b2-cache-divergence-2026-09-06/bank-manifest.json): source receipt, independent safety checks, CPU replay results and exclusions.

The capsule retains reports, logs/telemetry, source proofs, frozen evaluators,
full-vector/chunk analysis and ROOT's cross-row audit. Independent checks cover
archive/manifest hashes, exact member inventory, safe regular-file paths,
UTF-8 content, credential patterns and the disjoint 56-included/75-excluded
partition of the original 131-file inventory. Key **provenance labels and
helper source** are not key material. Runtime binaries, weights, cache bodies
(including checkpoint ciphertext), keys and credentials are excluded. The full
1.57 GB archive is not banked; its hash is provenance only.

## CPU validation

The frozen verifier reproduces backend pass/cache failure. Independent replay
matches the retained strict verdicts (the retained cache JSON additionally has
an explanatory `review_note`), and recomputed trajectory JSON and all 1536 token
emissions are byte-identical. No model execution, GPU work, remote staging,
commit, push or publication occurs in this banking task.

To replay locally, verify the pinned archive before extracting into a new
temporary directory; the checked capsule contains only safe regular text files:

```bash
evidence=docs/reports/evidence/gptoss-b2-cache-divergence-2026-09-06
printf '%s  %s\n' 9d29e690659c2101e736a2f79141b4d1a5c16ce140ea500491b7ea71db226e8f "$evidence/gpt-b2-raw-capsule2.tar.gz" | shasum -a 256 -c - && (
  scratch=$(mktemp -d) &&
  tar -xzf "$evidence/gpt-b2-raw-capsule2.tar.gz" -C "$scratch" &&
  python3 -B "$scratch/verify_capsule.py"
)
```
