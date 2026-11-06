# Registered Qwen local TP progress — 2026-09-13

Goal remains active: at least 800 uncached prefill TPS (1,000 stretch), batch
one / 8,192 prompt tokens, exact registered Qwen3.8 27B 4-bit on two M3 Ultra
256 GB machines with their GPU counts recorded. This checkpoint establishes
bounded actual 9B partition execution and reproducible numerical failures.
It does not qualify model quality, distributed performance or product readiness.

Repository: `/Users/developer/DarkbloomDev/d-inference`, branch
`feat/cluster-inference`, base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`.
Canonical goal: `docs/design/distributed-inference-goal.md`.
Public record: `experiments/cluster/inference/REAL_QWEN_TP_VALIDATION.md`.
Previous frozen checkpoint: `progress-qwen-output-precision-20260913.md`.

## Implemented and executed

- Explicit `local_correctness: true` / `--local-correctness` admits one-shot
  real dense Qwen loopback TP with an expected aggregate pin, complete logit
  capture, prompt 1–128, chunk 1–32, outputs 1–4, one repetition, no warmup,
  and native deadline at most 180 seconds. Multiple outputs require exact
  teacher history. Workers reject this opt-in before staging or execution.
  Existing defaults still reject real-model loopback.
- Native preflight retains bounded actual configuration bytes and parsed
  prompt/teacher IDs. Before selected tensor reads, verify aggregate/file
  hashes and descriptor-derived limits: artifact payload 8 GiB, canonical
  text 6 GiB, selected storage 4 GiB per rank / 8 GiB per pair, largest
  selected host tensor 512 MiB. These are not hard process-memory bounds.
- Python additionally checks complete captured row count, vocabulary width,
  finite values and reported argmax. Loopback is always correctness-only,
  with invalid hardware throughput. Report schema remains 9, protocol 5.
- Release build passes. 187 CPU tests pass with all 37 Python sources stable.
  Native CPU admission rejects 47 fixtures; storage accepts five and rejects
  18 with no selected tensor reads. Existing protocol accepts 4,112 and rejects
  97. Admission JSONL has six total records, including prior storage/Gemma checks.
- M4 Max 36 GiB / 14 CPU / 32 GPU: four bounded native/both-wide × solo/full
  logical runs complete. FFN-only is excluded by its headroom estimate; full
  TP is admitted. Six rank reports contain 5,959,680 captured values. All
  peer logits agree; both matched solo/TP comparisons fail all eight rows.
- M4 Pro 24 GiB / 14 CPU / 20 GPU: the same frozen package executes six
  native/both-wide × solo/FFN/full runs, isolated from its provider checkout.
  Ten rank reports contain 9,932,800 captured values. Both rank plans fit;
  all memory samples show normal pressure and zero swap. Every matching
  solo/full capture is byte-identical to the M4 Max result. These are two
  separate same-host experiments, not inference between the Macs.
- Worst matched relative RMS: native FFN .01586730664, native full
  .01633654258, both-wide FFN .01572166050, both-wide full .01375166936.
  All 16 second-machine comparison rows fail the unchanged strict gate.
  Both-wide reduces worst RMS by only .918% for FFN / 15.82% for full.
  Native argmax remains [4087,13,271,1206]; both wider TP plans change the
  first selection to 10926. Subsequent teacher inputs stay [4087,13,271],
  so later matching outputs do not establish free-running continuation.
- Independent CPU replays reconstruct full FFN and full-TP storage commitments
  from actual artifact headers, verify all raw captures and source/bundle
  snapshots, and retain policy departures separately from same-policy errors.
  Source/bundle integrity is not reproducible-build attestation.

## Identities, evidence and memory

Executable SHA256:
`26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770`.
Tested source manifest (146 entries):
`4788d2f80f6c8fbfa419dc5a9ea0877c64b21d736557dcb2d9dec2bbc9bfe64a`.
Registered 9B aggregate (12 files / 6,113,952,230 bytes):
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
Configuration:
`c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
Remote portable package manifest (164 files):
`49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76`.
Complete retrieved archive (569,425,201 bytes):
`901dc501d596dd238f67d24693ca9b01af8245019337a4e62dd4610d6b112fa4`.

Run directories: `runs/qwen9-local-tp-full-20260913` and
`runs/qwen9-peer24-20260913/run`. Each retains receipt, raw rank files,
source/bundle copies and independent CPU audit. The latter also binds portable
wrapper identity and its original frozen drivers. The remote isolated stage
remains under `cluster-research/qwen9-peer24-stage-20260913`; its original
package and results are preserved. No copied model weights were required.

Text source: 927 tensors / 5,038,041,600 stored bytes. FFN-only stores
3,679,087,104 per rank; full TP stores 3,091,423,488. Largest selected host
tensor: 508,559,360 bytes. M4 Pro per-rank execution MLX peaks are about
3.916 / 4.133 GB for native/wider FFN and 3.254 / 3.414 GB for full. Separate
startup MLX records are retained. RSS, cache and OS memory are not MLX active
memory. M4 Max runs had pressure level 2 and some system-wide swap growth;
M4 Pro samples had level 1 and zero swap. No global memory guarantee follows.

Final build log: `real-local-correctness-build-final-20260913.log`.
CPU test receipt: `real-local-correctness-python-20260913.json`.
Native CPU records: `real-local-correctness-admission-20260913.jsonl` and
`real-local-correctness-protocol-20260913.json`.
Final docs log: `real-local-correctness-docs-check-final-20260913.log`.
Final read-only process receipt:
`real-local-correctness-process-cleanup-final-20260913.json`.
Remote final CPU replay completion:
`qwen9-peer24-independent-audit-completion-20260913.json`, session 10960 exit 0.
It binds script `307f09f57e31141c18fac2d4010d0ad607fc6d61887600a746d57e2241f1c260`
and final audit `f57ee10ed772b9c2a46691cf3b4838e4ecb20bf860d4b106c1a329dfaa57282d`.
The strengthened replay verifies all 358 archive entries / 295 files. Its first
archive-layout pass rejected the legitimate top-level staging receipt; the
corrected pass validates that exact name and all staging fields. The rejected
pass and initial successful pre-extraction audit are preserved separately.
This was an audit correction; no execution or numerical evidence changed.

Final checkpoint verification passes:
`real-local-correctness-final-verification-20260913.json`, SHA
`0243e7a540cf51cb1210f32c4cc8c2379fb393a951d80eb23d3feaa05ecd4edc`.
Current public source manifest:
`real-local-correctness-final-source-manifest-20260913.json`, SHA
`5ea6e58b779826efa4b8a37ad79b5804818acd9ca9ade2c6cb1ed540d6553a1d`.
The verifier checks 146 tested entries, 144 current public files, matching
bundles and all 37 CPU-test source hashes. Only the inference README differs
among tested source entries; additions outside that snapshot are docs and two
ignore files. Pinned dependencies remain clean, 280 docs pass, no private
identifiers or new credentials enter public files, and no native jobs remain.
One unchanged public base-image namespace is explicitly checked against Git
HEAD before accepting the existing scanner exception. No native reruns were
needed after documentation-only changes.

## Next work

1. Isolate input-projection arithmetic on the same evaluated actual input.
   The source-only review `qwen-tp-arithmetic-and-layer-pipeline-20260913.md`
   predicts width-dependent split-K changes for 9B gate/up, fused GDN and
   attention input projections at M32. Partial accumulators have input dtype;
   output-only widening cannot fix earlier rounding. Preserve exact stored
   fused [qkv,z,b,a] geometry and compare selected components before conv/SSM.
   These dispatch predictions are hypotheses, not captured traces or a proven
   unique cause. Do not grow synthetic matrices without a causal question.
   The follow-up source review `qwen-local-correctness-source-review-20260913.md`
   (SHA `9099182df863c2e79cb5f645f9832139a0328ac378ac40a64458e0dd71b97a51`)
   confirms a minimal RMSNorm-output capture that preserves input projection
   concrete types and fusion. Keep captured arrays outside Module parameter
   reflection and evaluate only after normal CBv2 state roots/commit. The
   public API can reconstruct the fused projection, not trace its private output.
2. Prototype whole-layer prefill stages as an alternative: tiny hybrid 4+4
   first, then verified 9B 16+16. Public Qwen CBv2 hidden/embedding APIs can
   preserve projection geometry without modifying pinned dependencies. They
   require a new stage-aware verified loader, explicit inactive parameter
   handling, source-to-local layer mapping, local KV/conv/SSM state, ordered
   commits and bounded activation transfer. Start sequential and compare
   same-chunk logits/state before overlap or physical transport. Decode for
   one request remains sequential across stages; no speedup is established.
3. Registered 27B weights remain absent: 11 files / 16,320,199,553 bytes.
   Other cached 27B artifacts cannot substitute. Its source-derived split-K
   behavior differs from 9B, so do not extrapolate the ranking of causes.
4. Latest 48 GiB SSH check times out. Latest 24 GiB Thunderbolt inventory
   enumerates no external devices; en1/en2/en3 are inactive. The cause remains
   unknown. Preserve management connectivity and use read-only rechecks;
   no network/interface, reboot or service mutations were made this turn.
5. Physical RDMA inference, state handoff, production scheduler integration,
   target M3 Ultra performance, additional MoEs and opt-in setup/trust/rollback
   remain open. The goal stays active because useful local work remains.

Root is the sole native/GPU orchestrator; agents perform CPU/source reviews,
driver preparation and independent evidence audits. All launched native jobs
are terminal and final local/24 GiB process inventories are empty. No commits,
pushes, deployments or provider/watchdog restarts occurred.
