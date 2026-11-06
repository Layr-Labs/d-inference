# Cluster goal progress — Qwen MoE runtime and routing

The goal remains active. This turn made real implementation and diagnostic
progress; it did not achieve real-model qualification, RDMA, M3 Ultra throughput,
or product integration. Canonical goal:
`/Users/developer/DarkbloomDev/d-inference/docs/design/distributed-inference-goal.md`.

## Implemented

- Whole synthetic Qwen MoE models through FFN/full partition plans, actual Qwen
  blocks, replicated routing and shared gates, rank-local expert intermediates.
- Direct split checkpoint gate/up composition after local range reads; actual
  35B metadata matches. Saved fixture accounting includes source/canonical counts
  and separates replicated router bytes from sharded FFN bytes.
- Bounded native router capture and deliberately overridden baseline-router
  replay, with strict identities, original byte hashes, call coverage and explicit
  exclusion from ordinary benchmark reports. No provider/production changes.
- Native composition CPU oracle and malformed pair checks; actual BF16 Qwen and
  Gemma boundary diagnostics. Full Gemma model integration remains undone.

## Evidence

- `runs/qwen-moe-integration-20260913/receipt.json`: whole-model F32 MoE, realistic
  dense head profiles, loader fixtures; BF16 observations. Supplemental FFN
  control added and its original executable hash verified.
- `runs/qwen-moe-routing-20260913/analysis.json`: six trace cases and exact
  uninstrumented controls. F32 has no expert-set changes. BF16 FFN has one tied
  prompt-position change; full has ten changes and peak row relative RMS 0.245065.
  Both ranks' router inputs/logits/routes and final logits are byte-identical.
- `runs/qwen-moe-routing-replay-20260913/receipt.json`: fixing router logits to the
  baseline reproduces the baseline exactly and reduces full TP maximum row RMS
  to 0.014910. This is causal evidence of routing amplification, not a serving fix
  or numerical quality pass. Prompt identity and logit-hash corruptions rejected.
- Final binary `a7d01167ba5c0cdc30ecce91aebf47e05f6b9899faf503333d9fa2ac7a44526e`;
  final operator suite passes. 91 Python tests pass; docs-check 280 files passes.
  Final experiment source archive/manifest and dependency revisions are bound in
  the replay receipt. Builds and GPU runs are complete; no rank processes remain
  from these supervised runs.
- Repo record: `experiments/cluster/inference/MOE_RUNTIME_VALIDATION.md`.

## Next work

1. Preserve the BF16 full-MoE divergence as a regression; do not widen a broad
   logit tolerance or use token agreement alone. Exact tiny BF16 attention/GDN
   operator controls with original fixture weights can separate output projection
   rounding from other differences. K256-to-K128 changes QMV dispatch, while
   BF16 split-K plus rank sums add rounding stages. A controlled wider-arithmetic
   output projection must retain wider partials until the final cast; converting
   only the collective input cannot recover already-rounded local outputs.
2. The actual 35B specialized H2048/E256/top8 router is outside the tiny stock
   router fixture. Actual model quality and long-context budgets remain required.
   Direct loading memory needs actual-artifact MLX peak/RSS, including coexistence
   of local gate/up pieces and their fused array.
3. Continue the primary dense 27B and reusable framework work, including phase
   plans, qualification, failure handling and eventual opt-in integration. The
   diagnostic replay changes model behavior and must never be a production plan.
4. The 48 GB development peer remains offline in the final read-only Tailscale
   check. No further interface mutations or sustained real-model benchmarks were
   performed. If it returns, inspect uptime/panic/network state first. Actual
   successful two-machine RDMA and the two-M3-Ultra 800/1000 TPS target remain
   unmeasured.

All code stays in the experimental directory on the feature branch; no commit, push,
deployment, provider start, catalog mutation or submodule modification occurred.
