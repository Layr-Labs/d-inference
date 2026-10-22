# Parent cleanup ordering correction for the registered MTP probe

This replaces only the local root-run parent. The frozen package manifest
`b025400b718f0c65ec35ef33c40906ca9d7fe339cc6d53bf8e068122a3f3830f`
and both deployed16-file trees remain unchanged. Native binary34fcd255 and all
owner modules, model/configuration, resource floors, proposal math and validation
policy are unchanged. No remote process or model was launched for this correction.

The earlier parent released its RDMA alias immediately after controller return or
failure, before observing actual owner/native retirement. A controller timeout
could therefore remove the alias while remote ownership remained. Preserve that
historical parent and use this corrected command for root's reviewed physical run:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-probe-parent-cleanup-20260915
/usr/bin/python3 -B run_physical.py
```

`configuration/controller.json` is byte-identical to the frozen configuration.
The controller and its dylibs are loaded from the frozen package's `controller/`.
The exact current HTTP `physical_io.postflight` function is extracted into
`probe_postflight.py`, including canonical journal and actual process observations.
It sends no signals and never clears a journal. The remote monitor and temporary
alias implementation are unchanged.

The parent now launches the controller in its own session. A timeout or interruption
fences that owned local process group before reaping; it retains the failure,
exit/group observations and raw stdout/stderr. This is not remote retirement proof.
It then observes both hosts while retaining the alias, until both actual process
lists are empty or420seconds from controller launch.420covers the existing bounded
startup and300-second native/owner lifetime while staying below the600-second alias
lease. Expiry ends observation but does not fabricate absence or clear a journal.
If processes are absent and a journal remains nonempty, the alias can be restored,
but the run fails and that journal remains sticky. Lost observation also fails.
Operator interruption during the wait is retained and cannot turn into success.

Cleanup observations are retained before alias release. Success additionally
requires both process lists empty, both journals empty, the local controller reaped
and its group absent, controller exit0, restored alias and unchanged input pins.
The prospective sidecar validator still independently requires both authenticated
native cleanup and owner lease-release claims. Time, process absence and journal
emptiness do not substitute for those protocol acknowledgments.

The12 CPU methods include three actual Python child processes: ordinary exit0,
exit7, and a sleeping process that is actually timed out, group-fenced and reaped.
Pure clock cases cover delayed two-host retirement, active ownership through the
full window, unreachable hosts, stale observations, sticky journals, malformed
counts and interruption. No network/model/native execution was performed by these
tests. `tests.json`, `lineage.json`, `correction.patch` and `source-checks.json` retain
the exact evidence and source mapping.
