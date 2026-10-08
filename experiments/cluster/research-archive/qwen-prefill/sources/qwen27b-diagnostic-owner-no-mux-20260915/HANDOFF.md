# No-mux invocation of the frozen v2 installer

`prepare_peer_no_mux.py` points to the exact frozen v2 parent `68bb635a…10e75`. It uses that parent's deployment, run pins, private SSH trust, preflight and retained-descriptor installer. The only functional invocation changes are adding SSH `-S none` and using fresh `install-no-mux-1/rank0` or `rank1` output. Source/import locations are adjusted to keep all operational inputs in the original v2 package. The inverse patch restores the frozen original exactly.

Run the rank 0 and rank 1 argv arrays in `commands.json`, sequentially. Root has confirmed that the prior rank 0 mux failure left the expected old owner installed, no diagnostic backup/temp files, and the canonical journal empty. The failed `install-1/rank0` receipt is preserved. The same old-tree preflight, guarded replacement, and new-tree preflight remain mandatory.

Source checks verified the inverse, Python 3.9 syntax and import resolution without invoking `main`, SSH or the installer. No runtime, frozen package, native binary, controller, request, epoch, agreement or remote file was changed by this handoff. The existing v2 parent and collector remain the physical/numerical bindings; only installation invocation uses this helper.
