# Real Gemma short correctness candidate — 2026-09-16

This is private, uncompiled source for real registered Gemma weights: P32/C16/O2, no stops, cut10, all experts in each owned layer, MTP off. Full reference runs on48; stage0 on24 and stage1 on48. No model, preparation, compiler, or remote operation was executed while preparing this handoff.

The composition is explicit in `build/integration.json`: qualified window-state ancestry, five Gemma native stage files, four already reviewed tailV2 files, forward92a7 → resourcea7d2 → dtypec522 → this driver. The 3,096-source ancestor becomes 3,126 sources through35 final overlays. Ancestry/dependency/build identities are in `build/lineage.json`. Existing Qwen Session/Loading bytes remain those of the qualified ancestor, explicitly distinguished from later MAIN; no Qwen eligibility, shared geometry, model math, or serving entry is changed.

The only changes to predecessor Gemma files are an actual CPU metadata getter on `Gemma4OwnedForwardSession`, and the `withRegisteredGemma4ShortCorrectness` body signature `(session, checked)`. Every frame, transport, row/state capture and sidecar write uses that closed resource-owner check. Source inverses verify these two edits; the original a7d2 owner and c522 package remain untouched. The corrected Foundation result456 accepted/169 refusals is retained separately; it does not qualify this new native entry.

`GemmaShortCorrectnessCheck` invokes the real full model or real whole-layer stage over the same window-aware request state. It exchanges actual probe2+1 residuals, starts fresh request state, commits three evaluations, accepts two greedy tokens, captures both full vocabulary rows and final chronological state, then checks request retirement, model/cache release, and collective release separately. Probe receipt means buffer received; frame receipt is sent only after actual state commit. Transport errors poison the operation; no failure-path ACK is attempted. The root-owned supervisor must still fence a failed peer, reap both processes and inspect canonical journals.

Only existing completed JACCL P2P is used. Control messages have capped16KiB lengths, immutable scope/role bindings and strict directional ordinals. Residual receive geometry comes from the local fixed request; hashes verify actual bytes. This is correctness framing, not authenticated/encrypted RDMA or production membership admission. The four tailV2 files are explicit because the qualified generic-state ancestor predates their correction.

Sidecars are fresh0700 directories and exclusive0600 regular files, with same-directory/file identity checks and fsync. Bounds are16MiB/file,32MiB total,128 files. Full/reference produces2 row JSONs+90 raw state files; stage0 produces30 state files; stage1 produces2 rows+60 state files. Full/reference and stages must match actual KV dtype/layout by global index before exact bytes can compare. No same-math result or tolerance is assumed.

The separate prospective comparator is `gemma4-short-correctness-comparator-draft-20260916`, manifest7edf02ebc9325d616e96e8c708396ba1e307edc549346df5ddf6a53fe38ce1da. It reuses the frozen row/snapshot helpers, checks exact full rows and all90 joined state entries, and has18 staged negative CPU methods. Those methods have not run. It leaves source integrity, actual resource admission and physical process/journal review as independent root requirements.

Read-only check now:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-short-correctness-draft-20260916/verify_sources.py
```

After a later root slot grant, execute `build/commands.json` strictly sequentially: source copy, private APFS cache clone, exact snapshot, one900-second/jobs2 native build. The build runs only local protocol/filesystem checks (7 accepted/15 refusals expected) and a metadata-only argument fixture, then binds minos26.2, binary, metallib and paged-attention resource identities. It does not run `--execute` or pass tiny-model fixture defines. All subprocess ownership/cleanup helpers are exact previously qualified copies. Original source-assembly schema mistakes are retained in `assembly-failures.json`; they never created a workspace or ran a compiler.

Before actual weights: root must supply a new authored/tokenizer-backed32-ID packet and exact per-mode jobs, retain `--describe JOB` independently before candidates, bind the actual built binary and resources, and use the reviewed canonical lease/resource/process supervisor with fresh output paths and existing300s maximum lifetime. The checked-in argument fixture has synthetic IDs and an intentionally nonexistent model path; it is not a physical job. Both stages require the root's actual JACCL bootstrap environment and failure fencing. The residual dtype remains an explicit candidate that the real probe may refuse; there is no silent fallback.

Remaining gates are native compilation, local fixture execution, parent source review/binding and actual full+staged weight runs. Whole-process MoE peak is still observed rather than proven; 6/4/2GiB policies and ordinary eligibility remain unchanged. No Gemma numerical, throughput, EP, encrypted-RDMA, or serving qualification is claimed.
