# 004 — Karpathy autoresearch, adapted

Status: kept

Upstream: https://github.com/karpathy/autoresearch

What we steal:

1. **One metric.** Theirs: `val_bpb`. Ours: B=4 8K aggregate
   prefill tok/s, plus a no-silent-regression clause on B=1.
2. **Fixed budget.** Theirs: 5 minutes. Ours: a defined harness
   (3-iter median, listed lengths, listed B). Comparable runs.
3. **Git as memory.** Keep commits are the only surviving code.
   `results.tsv` stores wins *and* misses.
4. **`program.md` is the org.** Humans (and agents) program the
   markdown, not a pile of tribal knowledge.
5. **Ratchet.** The tree cannot get slower.

What we cannot steal blindly:

- We do not own a single `train.py`. The mutable surface is
  `mlx-swift-lm` + thin provider wiring. A bad Metal kernel can
  `fatalError` the process. Rollback must be instant.
- Correctness is a second metric with veto power. Their loop can
  accept a better loss that slightly changes the model. Ours
  cannot accept a better tok/s that changes tokens.
- Power posture and GPU contention void runs. Training loops
  usually sit on a dedicated GPU already.

Operational translation: `GOAL.md` + `program.md` + `JOURNAL.md` +
`results.tsv` + `notes/` **are** the research org. Subagents are
roles (explorer / executor / synthesizer / optimizer / reviewer),
not a swarm that edits the same file unsynchronized.

The synthesizer is the only writer of `MINDMAP.md` ranked-bets.
The executor is the only writer of Mac result rows.
The reviewer is the only one who can mark `keep=yes`.
