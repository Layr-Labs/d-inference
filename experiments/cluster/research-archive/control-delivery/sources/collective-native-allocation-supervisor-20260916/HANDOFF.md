# Native allocation physical supervisor — source-only handoff

This prepares the exact 35-case allocation experiment for the 24 GiB M4 Pro at `developer@192.0.2.250`. The build passed, but no allocation case, GPU operation, remote action, local payload copy or new serving profile has run from this package. Four Python report-contract methods are staged and unexecuted; source AST, helper equivalence, case/command binding and small metadata checks have been performed.

The actual four-file native bundle is `collective-native-allocation-build-20260916/runtime-bundle-1`, manifest `e3ff82761600ab47921f78a43ee5416fb521bbcffcdd1bcaf446b75d7d16f7d2`. Its 44,782,072-byte `CollectiveAllocationCheck` is `4f4149c7330d8268ac7294ef7b225db25078d2fb853cb06af1d02e73ae66b26c`; build receipt `7dda3ec17f122faf31e38d93152f3283a645d0444c920644421655f6a5e2566a`, source snapshot `593c899a259ce7d189cbee0d21f928e6079dc8b0a3f6ce25cfd61ac7d45c9f50`, and compiled 35-case list `ccb7012177101b0f871fc5e085ac9e3d129a857ca5584aea13ab499dc5c8eb06` are bound. The unchanged metallib and paged resource pins are in `artifact-inputs.json`. Only small metadata was read here; the payload has not been copied or rehashed by this preparation.

The runtime measures both codec endpoints plus actual native byte export/import and compact array materialization in one process. Ciphertext delivery is an in-memory mailbox. This is not RDMA, a model/group run, production membership/key establishment, throughput evidence or permission to enable a protected serving policy. Every report and qualification keeps those claims false.

`PROBE-SCHEDULE.json` is copied byte-exact from the native proposal. Each case invocation starts one fresh native process. The reused-session cases intentionally prime only their own new process. User-provided sizes, repetitions and model paths are unavailable. The native budget remains 55 seconds with its 60-second alarm; the inherited parent remains 90 seconds and outer SSH 135 seconds. All source/package verification, preflight and cleanup share the original parent budget. Expiry fails the attempt and never extends it.

The supervisor reuses the Gemma/standalone PipeWorkers ownership implementation, immutable file snapshots, canonical journal observer and resource sampler. Seven core helpers are byte-exact, including all native child kill/reap/fence semantics. Changes are limited to dispatch/report binding, fixed paths, the allocation executable in the prohibited-process family, accurate observation labels and smaller output limits. Worker framing is capped at 65,536 bytes per line and 1 MiB aggregate (the inherited rejection text still names its old larger generic limits). Unexpected stderr, extra lines, partial EOF, nonzero exit or unresolved group cleanup fail. Native cleanup stays independent of report arrival.

Every invocation requires the actual 24 GiB Apple M4 Pro, 16 KiB pages, at least 6 GiB actual free memory, AC power, exactly pressure level 1 and zero swap. Resource observations are retained before refusal. Preflight acquires/releases a nonblocking exclusive observation lock on the existing canonical device journal and requires no prohibited owner/native processes. The native entry then takes its ordinary `ClusterDeviceExclusion` itself. Postflight requires the same journal inode and directory identity, empty bytes, obtainable lock, native leader reaped, owned group absent and no remaining prohibited processes. The standalone gate does not produce a protocol owner-release ACK; the receipt keeps that distinction explicit. Nothing clears or repairs a journal.

`allocation_result.py` independently reconstructs expected geometry, exact plaintext/input/frame lengths, codec counters, priming/publication/refusal counts, failure-side poisoning and fixture plaintext digests. It checks actual Metal allocation bounds for the pinned 16 KiB policy, zero native cache, exact final active baseline, observed native peak within +256 MiB, and process lifetime maximum within baseline current footprint +512 MiB. Native elapsed time must remain below 55 seconds. Unknown or duplicate report fields, different case/host/OS, false scope claims and unauthenticated publication fail.

`validate_returned.py` additionally requires one complete JSONL stdout record, empty stdin/stderr, exact report retention in the terminal, real owned PID/PGID and argv, natural exit zero, no cleanup/watchdog/postflight error, exact retained-stream hashes, same empty canonical journal, clear pre/post process inventory and complete raw OS resource observations. Raw vm_stat/sysctl/pmset values are parsed again; no remote clock is subtracted from a local clock. Collection saves raw files and its receipt before validation, preserving every failure.

After source review and a separate local materialization grant, run `bind_package.py --source-sha256 PIN --output /Users/developer/DarkbloomDev/cluster-research/collective-native-allocation-bound-supervisor-20260916`, with the exact source-manifest pin supplied in the handoff message. This verifies and copies the actual four-file native bundle into a create-only local package, rechecks every source, and produces pinned package/deployment manifests and exact root commands. It performs no remote operation or GPU work. The approximately 227 MB payload copy must be scheduled outside competing physical/compiler work.

After root reviews that binding and grants the physical slot, from the new bound directory:

```sh
/usr/bin/python3 -B run_physical.py copy
/usr/bin/python3 -B run_physical.py run --fixture fresh-u32-4 --attempt 1
/usr/bin/python3 -B run_physical.py collect --fixture fresh-u32-4 --attempt 1
```

Run and collect each subsequent case in the exact schedule order, stopping on any failure. Every case has an exclusive run directory; attempts are bounded 1…9 and never overwrite evidence. The new remote root is `/Users/developer/DarkbloomDev/collective-native-allocation-check-20260916`. Copy creates only that root and never replaces an existing installation. SSH uses `-S none`, the existing pinned development known-hosts file and dedicated identity; no trust weakening or interface changes. Each successful collection produces `qualification.json`; no aggregate profile is inferred automatically.

Optional model-free report controls after root grants CPU execution:

```sh
/usr/bin/python3 -B -m unittest -v test_allocation_result
```

The four source-staged methods cover independently assembled scalar/session/post-open reports and negative cases for counts, frame lengths, digest, scope, publication, memory/deadline/cache, host/page identity, duplicate/unknown fields and false cleanup. They do not replace the required 35 actual fresh-process runs. Physical qualification, conservative measured resource profile construction and admission integration remain pending.
