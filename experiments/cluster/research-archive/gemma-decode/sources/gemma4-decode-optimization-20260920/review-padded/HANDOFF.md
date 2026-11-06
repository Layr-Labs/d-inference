The comparator is ready for root review and execution after all physical owners have retired. Author work is source-only: no test execution, native run, binary hashing, or numerical sidecar replay. The frozen timestamp comparator and accepted cohorts remain unchanged.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-decode-optimization-20260920/review-padded/test_policy.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-decode-optimization-20260920/review-padded/compare.py --output-dir /Users/developer/DarkbloomDev/cluster-research/gemma4-decode-optimization-20260920/review-padded/actual-padded-1
```

The first command has 16 CPU contract methods and reads only three small accepted timestamp native JSON reports. The second reads nine retained roles and their numerical sidecars: v7, timestamp v1, and padded v2, each with solo plus lookahead rank 0/rank 1. It creates only the new result directory. It performs no process, network, native, compiler, or device action. Keep the bulk I/O window exclusive for this replay. No new serial pair is required.

Actual native d7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769 is bound to the successful control-build-1 receipt, its applied-control-frame source receipt, reviewed three-file control overlay, deployment package, both completed installations and three original prospective job files. The actual 47,066,600-byte deployed binary is hashed during the later comparison, before and after numerical replay. No future identity is guessed. Frozen timestamp physical/numerical helpers remain byte-identical and are imported directly.

Every role must pass the original physical launch/terminal/EOF/natural-exit/process-group/canonical-journal/alias/resource-clock checks. Every raw resource sample must retain AC, pressure 1, zero swap and the 6 GiB free floor. Actual frames, commits, clocks, model release and exact prospective jobs remain required. New roles compare all four token sequences, four complete final rows and 360 native state components as solo versus combined stages; each of the two accepted baselines adds eight complete row comparisons and 720 exact same-role state-component comparisons. UUID/build/path differences are explicit; workload, artifact, source selection, state geometry, dtype, prompt bytes and numerical bytes stay exact.

The explicit framing policy validates the following counts, including warmup:

| Scope, per rank | Removed control prefixes | New completed sends / receives |
|---|---:|---:|
| One prefill, 64 frames plus first token agreement | 194 | 129 / 129 |
| One decode, 15 continuation tokens | 75 | 45 / 45 |
| Entire four-request owner | 1,108 | 713 / 713 |

For rank 0, prefill has 65 sent controls and 129 received controls; decode has 30 sent and 45 received controls. Rank 1 reverses those directions. Each rank participates in three bilateral checkpoints per request: begin, ready and request-retired. Two initial probe frames contribute six controls; the final model-released checkpoint contributes two. Thus the global prefix reduction is `4 * (194 + 75 + 6) + 6 + 2 = 1,108`, with rank 0 send/receive reductions 395/713 and rank 1 713/395. Rank 0 also sends 318 residual payloads; rank 1 receives them. These lifecycle counts come from BenchmarkRuntime/Driver checkpoint and probe calls plus WirePayload and Wire control protocols, all bound by the actual source composition.

Each removed send prefix removes eight logical checks in the unchanged completed-send implementation. Each removed receive prefix removes seven checks inside completed-receive and its following prefix check. The exact global reductions are 8,864 logical/owner/OS/native-snapshot calls, 17,728 entry calls, 26,592 environment calls and 70,912 outer-native-fault calls. Every retained guard still has the same 2/1/3/1/1/8 entry/owner/environment/OS/native/outer relationship. Decode logical checks become exactly 65/63 per rank/token. All other phase/frontier/counter changes refuse.

Solo resources and cadence must remain identical. Each stage may add exactly one `paddedControlFrame` logical allocation of 16,384 bytes with its actual native rounded bound, plus exactly 32,768 host bytes. Existing named arrays, bounds, selection terms, lookahead allowance and all floor fields must remain identical. Only the derived 8,864 fewer resource observations are allowed. A smaller existing bound, omitted host charge, changed solo budget or missing probe/retirement reduction refuses.

The JSON and Markdown report show all three versions' aggregate prefill/decode TPS from three measured requests, excluding warmup. They also summarize 45 same-process continuation-token intervals per role: every guard category and call count, graph/staging/evaluation/commit spans, before/after-owner spans and inclusive wire time minus its nested guard. These are not pure GPU or network costs. Categories overlap; the report does not sum them or subtract clocks across hosts. Tests cover exact both-rank/global/per-phase counts, lifecycle omission, wrong direction, off-by-one decode and post-prefix counts, altered commit/frontier, extra OS calls, missing/reduced charges, solo change, truncation, boolean rank, local-clock scope and reversed phase chronology.
