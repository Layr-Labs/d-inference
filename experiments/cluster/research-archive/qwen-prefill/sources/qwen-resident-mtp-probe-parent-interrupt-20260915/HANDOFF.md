# Interrupted-wait ownership correction

Use this new local parent in place of the prior cleanup parent. The prior package
and manifest `5ee1b39452459995210eb0b56abfa01066cf53e7ec3da6e11729a3203903610a`
remain frozen. All deployed native/owner/configuration/resource files remain
unchanged; no remote/model/compiler action was performed for this correction.

Installed Python's `Popen.wait()` catches `KeyboardInterrupt`, waits briefly again,
and then rethrows. That internal wait can reap the child and set `returncode`.
The previous unconditional SIGKILL on the numeric process group could therefore
outlive unreaped ownership. `parent_cleanup.invoke_controller` now checks the
existing `child.returncode is None` before a destructive group signal, without a
poll or reap before that decision. If already reaped, it records the return code
and skips destructive signaling and another wait. It always rethrows the original
exception. The final signal0 observation remains read-only and cannot grant success
when interruption was recorded.

The remote process/journal observation,420-second cleanup window and alias ordering
are byte-identical to the previous correction. The parent still records interrupted
failure and requires both native process lists absent, empty canonical journals,
local reaping/group proof, authenticated controller cleanup/lease ACK evidence,
exit0, stable pins and restored alias before success. A time bound never clears a
journal or manufactures cleanup proof.

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-probe-parent-interrupt-20260915
/usr/bin/python3 -B run_physical.py
```

The root must review before running. The exact frozen controller configuration is
copied in `configuration/controller.json`; the actual controller/dylibs still come
from the original frozen qualification package. The root's copy-only deployment
receipts remain applicable; no new deployment is required.

`tests.json` records13 passing CPU methods and three real local Python children.
The new fabricated Popen sets returncode0 before raising KeyboardInterrupt, traps
poll/kill/second-wait, and accepts only the final non-destructive signal0 query.
It verifies the original exception and failure record survive. Existing actual
sleeping-child timeout still verifies destructive fencing before reaping, while
normal/nonzero exits and delayed/missing/sticky remote-proof simulations stay intact.
`python-wait-source.txt` and provenance bind the installed interpreter semantics.
