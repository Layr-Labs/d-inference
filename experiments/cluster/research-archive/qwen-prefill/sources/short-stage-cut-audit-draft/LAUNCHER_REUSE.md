# Short 12+20 comparison: guarded launcher reuse

Source review only; no launcher, model, compiler, or SSH execution.

The qualified `qwen-layer-stage-compare` 65/32/4 run in
`QWEN_LAYER_STAGE_REAL_VALIDATION.md` was local on the 36 GiB M4 Max.
Its root driver is `cluster-research/validate-qwen-layer-stage-real.py`.
The earlier peer24 one-process driver, `remote-prefill-launcher-draft`, instead
runs `qwen-layer-stage-prefill-check` 65/32/1 with no teacher. Appending
`--stage-cut 12` to that command would select the wrong mode and must fail.

The smallest remote adaptation should reuse the newer frozen
`remote-long-solo-launcher-draft` ownership/provenance framework. Its
supervisor retains primary and cleanup failures separately, checks the deadline
after the memory observation, and requires actual local SSH reaping. Its client
requires absolute zero reported swap. No phase/owner sidecar adaptation is
needed for this correctness comparison.

Keep the existing exclusive UUID run paths, narrow host/path admission and
quoted SSH argv, archived runtime and full source/bundle checks, remote full
artifact verification before and after, pinned control bootstrap, initial
actual-free >=6 GiB screen, post-hash reclaimable >=8 GiB/disk/descriptor
screens, pressure <=2 and absolute zero reported swap. Keep the owned cancel
file, remote worker's native process-group cleanup, bounded parent deadline,
local SSH reaping, separate remote PID postflight, partial records and failed
receipts. Source archives compare the live tree again after a run: included
source/document edits during execution must still fail that cohort.

Only the mode-specific entry/config/input/outer-record surfaces need change:

1. Admit only the registered 9B artifact and this fixed 65/32/4 experiment.
   The proposed native argv is the original short comparison argv plus
   `--stage-cut 12`; include `--teacher-tokens-file @rank/teacher.json`.
   Keep native timeout <=180 seconds, seed7, one repeat, zero warmups and
   native CBv2 precision. Do not carry the long profile, 8192/512/1, 300-second
   native timeout, timing labels or solo-forward receipt claims into this run.
2. Reuse the pinned 65-token natural-text prefix and three original teacher
   tokens from `runs/qwen9-output-boundaries-20260913`. Archive the original
   receipt, source text, prefix and teacher provenance. Stage prompt and teacher
   raw files with `input_files={}` so the worker does not reserialize them;
   extend the fixed remote before/after input checks and retrieval to both
   paths, sizes and SHA256 values. Keep the existing rank-configuration pin.
3. Replace the two-record outer contract with the existing baseline checkpoint
   followed by `qwen_layer_stage_comparison_report`. Validate the actual
   65/32/4 request/teacher history and selected plan identities. The nested
   comparison remains the independent CPU oracle's responsibility. Retain the
   bounded duplicate-key/nonfinite-rejecting parser and signed-zero handling.
4. Invoke the new prospectively frozen cut12 audit only after native completion.
   A native/outer pass alone must leave the independent numerical-audit claim
   false. Preserve failures and run the same postflight/provenance controls.

The current frozen recorded oracle cannot admit 12+20 unchanged. Its
`stage_inventory` hardcodes counts463/464, `layer // (layers // 2)` ownership,
`layer % (layers // 2)` local indices, and the retained 16+16 expected inventory.
The old expected deriver also hardcodes state owners `//16`/`%16` and equal
state halves. Relabeling records, suppressing plan checks, or merely substituting
a new expected JSON file would be incorrect.

The separate cut12 variant retains the old numerical comparison algorithm and
changes only explicit inventory/plan admission. Expected counts are348/579;
active bytes2032294848/3005746752; inert bytes16384/8192; state component
owners27/45. The union remains927 tensors,5038041600 active bytes and72
global state components at each frontier32/64/65/66/67/68. These are metadata
expectations, not evidence that a new cut has executed. The unchanged whole
model named-state/boundary admission bound,165740576 bytes, is independent of the cut; it is
not a process-memory guarantee.

The fresh same-run full baseline is primary. Its source identity must contain
the new plan and its rows/state must agree with that run's staged candidate.
The old 16+16 baseline is only an optional unchanged-input numerical control:
compare numerical rows and global state entries explicitly, not its old plan,
whole baseline fingerprint or request UUID. A newly compiled omitted-cut
16+16 control would additionally test default-path preservation, but is a
separate root-owned execution decision.

Prospective CPU fixtures should accept an explicitly bound 12+20 record and
reject stale16+16 plan/config hashes, wrong layer11/12 ownership and local
indices, duplicate/missing canonical tensors, incorrect retained927 count,
inert and storage accounting changes, a coherent state-shape mutation, and a
candidate raw-logit/negative-zero byte mutation. Root will first provide the
metadata-only Swift Plan control for exact construction bytes and hashes.
The original helper and historical receipts remain frozen.
