# Same-binary M4 Pro CPU checks — root-only proposed operations

This is a small remote wrapper for the exact optimized binary that passed the local M4 Max benchmark. It launches no model, MLX work, inference transport, or RDMA test. SSH is used only to copy the tiny CPU executable/helper and return CPU timing JSON. **No remote operation has been executed by this package at freeze.** Root review and a quiet-slot grant are required; current 27B model work takes precedence.

Binary: `3a2fb41e1374099700e19118458395828d262461e60e5daea060f155701602d8`, 207,408 bytes. It is copied from `cluster-authenticated-record-cpu-benchmark-run-1-20260915/authenticated-record-benchmark`, whose actual local result is `f1ebc356dd07e4a405b744ea0485a092dccd195e18435e4350e1b27213f35c9f`. Frozen source is benchmark V2 manifest `2ddd4694908c772ac375ba4bc02d1d6bed6a60ee291418b92b136de35550112f`; codec source remains exact c206, already eight-group correctness tested. There is no relink or runtime modification.

The exact existing SSH settings/known-hosts path and dev identity are retained from the reviewed 27B control parent; `-S none` disables multiplexing. The known-hosts file is pinned to `89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed`. No private key bytes are read by these scripts. Only `darkbloom-24` and `darkbloom-48` are accepted target arguments.

Each command creates `/Users/developer/DarkbloomDev/cluster-record-cpu-benchmark-20260915` on its target, mode 0700, and refuses any existing destination. It opens the existing canonical `~/.darkbloom/cluster-device/native-device.lease` with no-follow/no-create, takes a nonblocking exclusive flock, requires exact owned regular 0600/single-link/empty identity, and retains the same FD until the CPU child and postflight finish. It never creates, truncates, resolves or replaces the journal. Directory/file identity and empty journal are rechecked around the child. Existing native/owner/provider process families cause refusal. No existing process is signalled.

Binary and helper writes are exclusive, fsynced and read back from retained descriptors; their bytes and named-file identities are checked immediately before and after the CPU child. The remote benchmark verifies its plaintext outside the measured codec calls and reports actual `Apple M4 Pro`; any other CPU is refused by the remote validator. `remote_result.py` is the exact local result validator function/shape table with one changed required observed host string. It does not relabel local data. The local frozen runner stays unchanged.

Owned process supervision is byte-exact from `qwen27b-owner-load-operands-rerun-20260915/copy_owned.py` (SHA `20ee93481bf65e4e0e8a34dd4ccb32835527a9955024a2c2898955a2e19fcebe`). The remote CPU child has a 30-second bound; outer SSH has 75 seconds for copy, preflight, child/reap and postflight. Only that newly created child's owned group may be killed on timeout/interruption. Natural exit zero, actual reap/group absence, empty stderr and unchanged gate/binary are mandatory. Output is capped/validated after completion; child fixture output is fixed and small. Partial create-only trees are retained on error, not automatically deleted or reused.

Raw CPU stdout/stderr and `execution.json` stay in the new remote tree. The local output stores exact returned JSON, stderr, payload, argv and receipt/summary. All eight cases/160 samples/24 warmups are validated by the same predicate used locally except for actual M4 Pro identity. This is per-host CPU codec cost, not encrypted cross-host RDMA or end-to-end TTFT. No GPU staging, RDMA buffer copies or coordinator key-establishment work is measured.

Root commands, sequentially, only after the active model run has retired and the quiet slot is granted:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-remote-cpu-20260915/run_peer.py --peer darkbloom-24 --output /Users/developer/DarkbloomDev/cluster-research/cluster-record-cpu-remote24-1-20260915
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-remote-cpu-20260915/run_peer.py --peer darkbloom-48 --output /Users/developer/DarkbloomDev/cluster-research/cluster-record-cpu-remote48-1-20260915
```

Python source/closure checks only at freeze. No new compiler or fixture matrix is needed: root source review followed by the two actual CPU runs is the intended next gate. Shared codec/benchmark behavior remains covered by existing actual local checks; no remote pass is claimed in advance.
