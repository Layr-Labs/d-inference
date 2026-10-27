Latest execution, 2026-09-20 21:39 UTC: decode optimization v1 PASS, Gemma pair28.544838 decode /459.768923 prefill; exact v7 bytes and guard cadence. Control-frame v2 native d7859728 built/installed; matched solo is active, pair follows. Root owns physical/compiler slot. Current detailed receipts: gemma4-decode-optimization-20260920 and EXECUTION_20260920.md. Historical live-state claims below are superseded.


# Cluster delivery checkpoint

Updated: 2026-09-20. **Current execution checkpoint is [EXECUTION_20260920.md](EXECUTION_20260920.md); it supersedes historical live-state claims below.** The existing delivery goal is unfinished. Engineering has resumed under the user's authorization.

- Current-master default product candidate passes193 selected tests and builds CLI ff481247…cfdc0e. Qualified source is the isolated cluster-product-master-qualification-20260920/qualification-1/workspace; MAIN stays preserved. Coordinator focused and registry race suites pass. These are software checks, not protected hardware serving.
- Actual full-model Gemma expert parallelism now passes P32/C16/O2 with16/112 experts: both complete262,144-logit rows and all90 state entries match fresh solo bytes on each rank. Both actual native owners retire cleanly and the TB alias is restored. No EP throughput claim yet. Evidence: gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep16-112-v1/comparison.json.
- Accepted long Gemma pipeline remains v4 P4096/C64: solo348.658, serial256.518, overlapped338.808 prefillTPS; decode36.797/8.039/8.010. Newer v7 cut8 pair refused late memory admission. A cut7 matched v7 cohort is running with unchanged limits. Short v6 P128 gives solo392.512/overlap382.477prefill and59.181/24.852decode. All MTPoff/plaintext labRDMA.
- Qwen9B accepted8K solo439.851/pair814.423prefill;27B126.625/pair164.896 (27B onlyone measured sample). No accepted TP speedup, real repeated-MTP acceptance, Gemma8K, or M3Ultra hardware result. Full evidence and limitations: STATUS_20260920_REVIEW.md.
- Generic measured placement planner passes19 synthetic groups. MTP accepted-round controls pass26 Foundation groups; native build/physical comparison next. C128 one-layer expert binaries/metadata are ready for physical qualification. Standalone encrypted RDMA component benchmark source is in progress.
- Genuine signed/provisioned identity and current catalog/attestation inputs are still needed for the protected product pair. Existing configuration-location question is pending; do not repeat it. Lab encryption cannot authorize product membership. Current master supports qualified AppAttest; old MDM-only notes below are historical.
- One compiler/materialization slot/jobs2, no compiler/bulkIO during physical inference. Local36GB Mac offGPU. Preserve failed evidence and existing memory/numerical requirements. The unfinished goal API still reports blocked and offers no resume action; engineering continues under the user's explicit authorization.

