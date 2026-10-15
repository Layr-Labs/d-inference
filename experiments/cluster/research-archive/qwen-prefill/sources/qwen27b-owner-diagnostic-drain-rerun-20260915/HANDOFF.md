# 27B diagnostic rerun with a drained local controller

This package is ready for root's sequential read-only preflights and one physical
diagnostic request. No remote action or model execution was performed while
preparing it. Both remote owners, their four old libraries, native binaries,
resources, model paths, owner configurations and private SSH trust are unchanged.
There is no installer or transfer step.

Only the local controller bundle changes. The local Endpoint now drains stderr
emitted after the release ACK and before actual transport exit; the controller
waits for that bounded drain before reporting it. The five new local child/pipe
groups, six existing retirement cases and13SSH groups passed. The old Endpoint
reproduced the exact lost-diagnostic ordering. The frozen build/review is
`cluster-owner-diagnostic-drain-draft-20260915`, manifest
`ebccbc7e4f216af0313c0f1ce36711f06dd570dafe92a136ce1a673ca4536615`.
Its local five-file bundle is
`e650ebc820b42e7b57cf105b81b60c01320d22f40cfe1e1de70c52a13440fdaa`;
controller `862f7a391afd8f490233db793034c1ec8648c52fd908ba39abbefbf46e899d78`.

The new membership epoch is `f45537d3-314d-4cf2-9157-570cde16a58d`.
ClusterID stays `qwen27b-native-validation-1c7b2bc6-744b-41c1-b621-ddef0e9eb31e`,
and requestID stays `20801ced-ca29-4faf-b71a-9ebbe1886a14`. Registered27B,
P32/C16/O128, cut32, serial, empty stops and MTP-off remain exact. Compact outer
JSONL framing is preserved. The corrected existing preparer produced prospective
agreement `8aeecca0aa0539e5c0f194dfa51a9a4e36e023d94365e87512db3472c34b0fa7`;
membership epoch is its only semantic difference. No new reference/candidate
output was read. The successful prior reference65c39fab…53a36e remains available.

`run_physical.py` differs from the frozen V2 parent only in its local CONTROLLER
path. Its process fencing, authenticated lifecycle observations, alias ordering,
remote postflight and resource monitors are exact. `deployment.json` has identical
rank trees; only local controller/bundle identities change. The old metadata-only
input-provenance epoch and known-host hash were refreshed to the actual current
configuration; original metadata is retained. Historical provenance stays labeled
under `provenance`, with this epoch's agreement receipt replacing the active one.

Root commands, also machine-readable in `commands.json`:

```sh
/usr/bin/python3 -B check_source.py
/usr/bin/python3 -B preflight.py --rank 0
/usr/bin/python3 -B preflight.py --rank 1
/usr/bin/python3 -B run_physical.py
```

Run from this directory, after root excludes other physical/compile work.
Each preflight uses the exact prior remote read-only script:14file hashes/modes,
no owner/native processes, empty evidence directory, canonical empty journal under
nonblocking exclusive flock and unchanged actual resource guards. Output is fresh
under `preflight-1`; physical output is fresh under `physical-1`. SSH explicitly
disables multiplexing for this embedded preflight command and retains private-key
and known-host checking. The wrapper records errors/deadline failures. Private-key
contents and passwords are never read or packaged by preparation.

The prior11.9507s physical failure remains failed: zero tokens, both actual native
cleanup and authenticated owner release ACKs, empty postflight journals, alias
restored, but diagnostics lost locally. Its native cause remains unknown until a
new actual diagnostic arrives. A new EOF/diagnostic observation is never native
cleanup proof; the controller records native cleanup, release ACK, actual owner
termination and diagnostic completeness separately. This is neither a numerical
qualification nor a performance measurement.
