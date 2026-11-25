The exact P128 numerical gate remains failed. All four requests reproduce the same mismatch; this diagnostic does not qualify MTP.

| Evidence | Result |
|---|---|
| Final rows | 4 complete Float32 rows, 262,144 values / 1,048,576 native bytes each |
| Different values per row | 259,344 / 262,144 |
| Maximum absolute / RMS error | 2.410064697 / 0.6319189083 |
| Relative RMS error | 11.180286% against reference RMS |
| Final argmax / nonfinites | Both 4194; zero nonfinite values |
| Greedy tokens | All 16 per request match (64 total) |
| State components | 240 K/V components differ; all 120 position components match |
| State bytes checked | 128,860,640 per arm; four complete 90-component snapshots |

Every prompt position 0–127 and the width-one priming position 128 matches bit-for-bit in all 30 layers. The earliest temporal difference is layer 1 `kv.values` at position 129, the first rectangular verification window. Layer 0 has only five differing K/V elements, first at position 130; its maximum absolute error is 0.00048828125. Differences grow through later layers, reaching state maximum absolute error 4.625 at layer 14. The first component in canonical file order that differs is layer 0 `kv.keys`, whose first affected position is 135; that is not the earliest temporal divergence.

The prompt and priming equality localizes onset to the rectangular path. Small early BF16 differences and later amplification are consistent with shape-dependent arithmetic, but final snapshots cannot establish that cause or exclude a mask/cache/reconciliation error. The next isolation must use the same forced target input tokens, fresh identical prompt state, and no assistant, comparing ordinary width-one decode, width-one verification, width-three full retention, and width-three prefix rollback. No tolerance should be widened.

All K/V components are BF16. The 25 sliding layers have each key/value shape `[1,8,143,256]` (585,728 bytes); the five full layers 5/11/17/23/29 have `[1,2,143,512]` (292,864 bytes). Each position component is Int32 `[1]` (4 bytes), exactly 143. Complete per-component errors, shapes, byte counts, SHA pairs, and differing-position counts are in [findings.json](findings.json).

The original exact helper files were imported unchanged and pinned. Every one of the 728 sidecars was hash/size/shape/fingerprint validated. Metrics were calculated once per distinct native SHA pair (62 calculations), then reused only after all four copies validated. Float64 `math.fsum` accumulates squared errors; no numerical tolerance or pass substitution exists. The diagnostic also replays the original physical terminal, process, journal and raw resource joins. The executable itself was not rehashed: build/package identities are the retained root authority, not a new binary qualification.

The owned diagnostic child 69929 exited naturally with code 0 in 8.20846 seconds under a 180-second bound; it was reaped, its group was absent, stderr was empty, and no kill was needed. [Receipt](receipt.json) SHA `a618ca66527b1bc0888223956c1bbd48aef21b68cdb59cb7c2f1091d614bc783`. The original failing comparator receipt and stderr remain unchanged.

Compact machine-readable results: [summary.json](summary.json). Full findings SHA `4aa548e3a94a8876eddc12fe427e30b91c6f82337ce6df624521ace42b278fa9`.
