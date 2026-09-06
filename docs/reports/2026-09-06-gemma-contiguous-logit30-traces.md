# Gemma contiguous position-30 logit traces

> Last updated: 2026-09-06 · commit `53f3c3d0c`

The two authorized trace cells completed and passed diagnostic validation. The retained automatic-versus-ordinary correctness result remains **FAILED**: their confirmed output at index 30 differs. Tracing preserved each mode's entire seven-main trajectory, verifier counters, and prefill geometry against its own frozen trace-off control. This evidence removes the earlier teacher-path/prefill-geometry confounder but does not establish equality of the full pre-forward state.

| Observation | Ordinary/off | Automatic |
|---|---:|---:|
| Confirmed argmax | 795 | 735 |
| Score for 795 | 24.93285369873047 | 24.77605438232422 |
| Score for 735 | 24.77605438232422 | 24.854991912841797 |
| Score 795 minus 735 | +0.15679931640625 | -0.07893753051757812 |
| Phase | chained_decode | rectangular_verify |
| Output base / selected column | 30 / 0 | 30 / 0 |
| Verification width | 1 | 2 |
| Accepted drafts / confirmed width | 0 / 1 | 1 / 2 |
| Cache offset / effective position | 5447 / 5447 | 5447 / 5447 |
| Available causal input prefix | [4615] | [4615] |
| Logit dtype | float32 | float32 |

Full KV/hidden-state equality and the entire rectangular target input are **UNOBSERVED**. The selected column's empty draft-prefix record does not identify the rectangular suffix. In particular, this report does not infer the full window `[4615,735]`. An earlier automatic speculative suffix record at the same output index is retained in the analysis and is not substituted for the confirmed column-0 observation.

Both cells used B1, cache off, the production single-slot KV grant, output cap 128, the same model/assistant/input, 5418 prompt tokens and three prefill chunks with maximum 2048 tokens. The seven flags were `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18`, `DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY=1`, `DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK=128`, `DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS=1`, `MLX_COMPILED_DECODE=1`, `MLX_GATHER_QMM_EXPERT_SLICES=trust`, and `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1`. No threshold, oracle or verifier policy changed.

The exact runtime tuple is parent `53f3c3d0c0d0a09f4d89fe4346aa72ebdecbe4e6`, native `de30ef9892cbd247b219cfde891f180ffbf5f47a`, Swift `c06149b4f7defa1b958c1e175f6c9a12c86c8a4f`, core `fab0f39f69140393b454c32d6f4bf7a9b32f9dcc`, and C `d4328f2d8d54d711d5419e07ab9fa2f07b512a48`. All eight frozen runtime files verify locally and remotely. The native executable hash is `c0badb1908b6801273d3a9440174c9ba2b7fc9a269b6d31afa4d2c18eccf914c`.

The first controller attempt failed before any native model launch because the file-only staging archive omitted the empty `runs/` parent required by the owner. That attempt remains in `failed-prelaunch-attempt1`; `prelaunch-recovery.json` records creation of only the missing empty directory. Neither completed native cell was restarted, and runtime, inputs, flags and validators stayed unchanged. Ordinary native PID 48815 and automatic native PID 49103 each exited zero; telemetry PIDs 48814 and 49102 also retired. The final read-only audit released M5 at 2026-09-06T10:18:37.919004+00:00 with no remaining owned processes or remote owners.

Evidence is retained at `/tmp/darkbloom-gemma-contiguous-logit-execution2`: `logit-pair-analysis.json` contains the complete bounded analysis and report hashes; `result-summary.json` contains the numerical table; `execution-results-manifest.json` hashes the complete collected results and evidence; `preservation-check.json` verifies 160 frozen corrected-control files, 76 prepared-execution files, the activated package, runtime and cell manifests; `m5-lane-release.json` is the release receipt. Remote results remain at `/Users/gaj/autoresearch/radix-prefix-cache/090-gemma-contiguous-logit30-plan1`.

The root review hash is `725d3ce796b2e3c6130c5fb10ee7d3173e1bd0159d0206ea7491991e67768cb0`, activated manifest hash `daa0255adb64afa1a1dd223ae01407d1ab28927950d33af877447585df492729`, and binding hash `d84748d0aa2ec873dec51770cd9788308512b78704b83c048ffc45e6e00342bf`. The prepared predecessor remains unchanged. Its 22 unique CPU tests passed in normal Python and `python -O`, including owned-process retirement tests.

The next source milestone must fork one produced pre-forward state with matched causal input and position, then compare ordinary one-token evaluation against rectangular column 0. Layer/operator capture should locate the first divergence. This is a diagnostic follow-up, not a waiver of the original model, B1/B2/B4, cache or MTP correctness coverage.

Banked evidence accompanies this report in [2026-09-06-gemma-contiguous-logit30-traces](2026-09-06-gemma-contiguous-logit30-traces/result-summary.json).
