# Dedicated-worker cache0 and cut4 overlay

The separately assembled package is:

`/Users/developer/DarkbloomDev/cluster-research/resident-native-worker-policy-build-20260915/workspace/libs/darkbloom-cluster`

Apply the seven files under `proposed/` on top of frozen cut8 overlay c1816b65a2320cc93a4d91328026e8a1e2f577b365c1ae9d97fe1678a868b068. The original facade4cce/worker2d13 and cut8 source packages are unchanged. Replaced cut8 workspace sources are also archived under the first test receipt. `runtime-and-tests.patch` contains the entire new delta.

The dedicated worker explicitly chooses `disableFreedBufferCache`; `QwenResidentLoadConfiguration` defaults to `unchanged`. The setter runs after typed/source/JACCL/arithmetic admission and initial actual resource checks, under an error scope, before collective/model load. The common bilateral load fingerprint includes the policy identifier while excluding local rank, paths and uptime deadlines. No provider default, Ready DTO or general cache-size option changes.

After the actual stage load, GPU/CPU streams synchronize; the existing native-error/deadline/native-error callback runs before and after synchronization and after clearing. Actual snapshots must show zero cached bytes, unchanged active and peak bytes, and valid nonnegative storage. These checks run before maximum request allowance admission and bilateral loaded Ready. The existing native error takes precedence over a secondary Swift failure; existing failed-load retirement remains unchanged. No active allocation limit,6GiB floor,request geometry,model arithmetic or tensor loading policy changes. No synthetic warmup is added.

The facade and worker now explicitly allow only cuts4/8/12/16. Actual native Plan construction remains unchanged. Full metadata fixtures assert both4/28 and8/24 complete source/phase partitions. Cut4 has118/809 active tensors,1,058,851,136/3,979,190,464 logical bytes and3/21 F32 tensors. These sums are not live residency/peak-memory guarantees. Unselected interval cuts20/28 and noninterval/malformed inputs still refuse at admission.

Validation passed on the first attempt:

- Cut8 phase:17 tests,107.234s including the relocated dependency build. Receipt: `tests-1/execution.json`, SHA57ccf1fda39666ead2cd8fcbeeb745d92c4b18a35a8f1cbafe061dbffc6f1a3f.
- Final cache0/cut4 phase:21 tests (12 facade,9 worker),10.159s including incremental build;96 package/source/test pins unchanged. The exact receipt SHA is in `checks.json`.
- Cases exercise actual registered metadata admission and Plan partition, default no-op versus explicit setter0, synchronization/check/snapshot ordering, active/cache/peak invalid states, original callback failure and stopped progression, common policy binding versus rank-local labels, and all prior fake native-owner/real local-pipe lifecycle cases.

These CPU tests never call the real allocator setter/clear, load a model, execute GPU work, initialize JACCL, or run a native worker candidate. The linked macOS14 executable remains a JACCL-stub typecheck artifact. No physical memory improvement, numerical parity or TTFT is claimed. Root owns the actual26.2 build, matched metallib, deployment and model execution.

Use the unchanged frozen `resident-native-worker-draft-20260915/build-native-worker.sh` with this package path and the explicit matched metallib path/SHA. The script's Swift and C++ target is26.2; normal ProviderCore remains macOS14 and depends on pure Protocol/Process targets. The package manifest here is staging guidance; root owns the main manifest merge. No diagnostic generation sink is included.

The pure Ready DTO has no allocator observations. Parent visibility is source/native policy correlation; it is not independent allocator attestation. Startup has no pipe control reader during native load, and a bounded output write can delay reader cancellation. The existing hard worker lifetime and independent parent fencing remain required. Cache0 only governs returned/freed MLX buffers; active model/state/fusion allocations and later all-sample memory limits still apply.
