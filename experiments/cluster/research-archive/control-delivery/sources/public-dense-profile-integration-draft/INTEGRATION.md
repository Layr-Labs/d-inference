# Public dense-profile test and documentation support

> Last updated: 2026-09-14 · commit `e4df336bc`

This package adds public integration support only. Root owns source integration,
Swift compilation and model execution. No repository files were edited by this
author, and the proposed runner has not been executed by this author.

1. Integrate the six unchanged core Swift files from the frozen
   `registered-dense-profile-draft` into the production ClusterInference source
   directory. Their original profile manifest remains unchanged.
2. Copy the five files under `proposed/` to the matching repository paths.
   The harness and retained metadata are exact original copies; the check fixture
   is root's corrected v2 copy. Its sole correction is
   `String(describing: tensor.shape)` in a rejection-case label.
3. Apply `docs.patch`, which adds one README navigation paragraph and one
   developer test command block. Original file hashes are recorded in the
   manifest; reconcile only those insertions if root's docs changed meanwhile.
4. Root can run the new public script and documentation checks after integration.

The runner uses the existing Candidate test support and eight production pure
dependencies, six new core files, the fixture and standalone harness. It uses
the existing temporary-output/EXIT-trap pattern and treats Swift warnings as
errors. It embeds no private location or host and needs no model files.

Root separately reported the v2 standalone compile and CPU execution passing
37 accepted / 53 rejected checks with empty stderr. That validates the exact
copied fixture/core combination; it is not a claim that this new shell runner
has already executed. The frozen v1 compile failure and original fixture remain
preserved outside this integration package.
