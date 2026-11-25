# Next registered short-parity execution

Current update, 2026-09-15 05:04 UTC: the registered 9B short-parity run has completed on the 48 GB M4 Pro, and both independent numerical and execution-binding audits passed. The 24 GB refusal below remains unchanged historical evidence.

The 48 GB checkpoint now has all 12 files verified against aggregate `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`. Its new isolated checkout is `/Users/developer/DarkbloomDev/c079-runtime-20260915/repo`, with `bundle`, `launcher`, `inputs` and `short-parity-9b` siblings. Six actual Git bundles reconstructed the pinned repository and dependency checkouts; the unchanged source helper matched all 403 original source-file entries. Native c079 and bundle50c581 remain unchanged. Root reviewed the fresh-only installer, verified its 27 members on both ends and completed installation; `peer48-c079-install-ssh-20260915.json` records the result. The inherited 19 parent tests also passed on the peer.

See [retained run summary](returned-short-parity-9b-peer48-20260915/retrieval-summary.json), [numerical result](returned-short-parity-9b-peer48-20260915/numerical-audit.json), and [execution bindings](returned-short-parity-9b-peer48-20260915/execution-binding.json). Parent completed/native0, empty stderr and clean owned-group retirement. All403 archived sources rehashed. Independent checker reconstructed four BF16 vocabulary rows and compared both pairs exactly, with72 state entries at frontiers2/3/4. Binding checker replayed the numerical result and joined source/bundle/runtime/input evidence. Raw state payloads remain opaque; this is synthetic3+1 short correctness on one machine, not physical model inference or throughput. Minimum sampled free memory22,371,024,896B, pressure1 and zero swap; sampled RSS maximum5,836,505,088B is not a peak guarantee.

A separate [physical RDMA host smoke](rdma-host-smoke-20260915/review.json) passed on both Macs for all five fixed sizes through20MiB using JACCL, one repetition and no warmup. A temporary47/32 alias on peer48en1 supplied the missing mapped GID; the bounded lease removed it afterward and confirmed stable bridge membership/flags and management route. [Lease receipt](rdma-alias-smoke-execution-20260915.json) preserves before/add/remove observations. This validates a narrow CPU-buffer collective, not sustained bandwidth, GPU staging or model TPS. The default interface state again lacks that temporary alias; the next physical run needs the same scoped setup or a separately reviewed persistent configuration.

Next work: qualify the new resident worker and real numerical/resource callbacks on9B; calibrate GPU-inclusive RDMA; run a source-matched long-prefill comparison; and obtain27B short-parity evidence. The M3 Ultra target and opt-in product integration remain incomplete. See [resident worker handoff](RESIDENT_WORKER_NEXT.md).


Earlier return update, 2026-09-15 03:07 UTC: both development peers have returned on AC. They are M4 Pro machines with 24 GB and 48 GB. Both report RDMA enabled and active Thunderbolt RDMA ports. These inventory observations do not qualify physical inference.

The corrected private credential-table parser authenticated successfully on peer24, and an authorized cache purge completed. The earlier return-time authentication failure had passed an SSH configuration path as the password; it did not test the saved credential. No local administrator password is needed to use the returned peers.

Preserved c079 tiny regression now ran: native exit 0, 13 records; unchanged numerical oracle passed and all 403 archived sources rehashed. The original parent remains failed solely for its empty-stderr rule and the known BF16 conversion diagnostic. See [retained tiny oracle execution](returned-tiny-c079-peer24-20260915/oracle-execution.json).

The registered 9B short-parity command then reached native resource admission but refused with `Short full-reference exceeds current actual-free or allocator limits`. Native exit 1, zero stdout, clean process-group retirement, zero swap and pressure 1. Parent samples showed 9,353,773,056–9,558,294,528 free bytes; these samples do not expose the native decision's exact terms. No numerical forward result exists. See [retained refusal](returned-short-parity-9b-peer24-20260915/retrieval-summary.json). Preserve the failure; do not lower the resource policy to make this run pass.

Source arithmetic now explains the refusal: even before MLX allocation rounding, the initial 9B full-reference free-memory requirement is at least 11,223,954,984 bytes (10.453123 GiB). Its terms are resident source bytes 5,038,041,600 + twice the largest host tensor 508,559,360 + short forward reserve floor 873,827,368 + 4 GiB headroom. The allocator separately needs current active/cache plus at least 8,567,911,976 bytes. Exact rounded allocations and live native counters were not emitted by the failed run. The 24 GB peer's observed free memory cannot satisfy even that lower bound.

Next: complete the 48 GB peer's interrupted 9B checkpoint and install a source-matched isolated runtime there before trying the original checks with more memory. Its existing first weight shard is a `.part` file (2,659,790,848 of 5,349,771,222 bytes), and the expected development repository path is absent. Recheck resources, artifact hashes and source/bundle identity before execution. The separate new resident worker remains a private prototype; see [current worker handoff](RESIDENT_WORKER_NEXT.md).

Earlier records and the original command follow; they describe their original dates.

Native c0795468, source403 and public overlay560 are installed on peer24. Parent5b6ce0b9 is installed with all19 CPU fake tests passing locally and under the peer Python3.9. Frozen independent checker10f8c421 is local;15 fabricated numerical tests pass. The whole-checker independent source review passed with no blocker: registered-dense-short-parity-audit-review-draft/source-review.json SHA04df17544bc60cd82e30bd8b121e34d0865f2919b9fa63001f3e42c7de981d88. No actual c079 candidate output exists yet.

At17:07UTC the peer battery was14%; the existing >=15 battery guard refused the tiny shared-finishing regression before parent/native invocation. No tiny or full short-parity native run happened on c079. Do not lower resource/power thresholds or relabel that refusal as a model failure. The ready8-pair short-parity command has not been executed. Full reference and simultaneous pair loading/forward remain unqualified.

The latest read-only observation at17:34UTC found peer24 at13% discharging and peer48 still unreachable; receipt peer-power-connectivity-20260914-1737.json SHAa68aabd76b8ec900c967b97bad8459bb8f376a593e8b2c491bbe35c2d72748ea. No native retry occurred. Local offline planning was added outside the native/runtime source snapshot; see PREFILL_PLANNING_NEXT.md. The local public tree now has568 files while the peer overlay remains560; no new native executable or peer install was needed for this CPU planner.

Before native work, require materially improved power (AC or actual>=15) and the existing6GiB free/zero-swap/pressure limits. The earlier remote disk-cache purge was successful with the existing private user credential; no purge was retried after the latest battery refusal. Do not store the credential here or in commands. If eligible resources need cache reclamation, perform the existing reviewed reversible purge manually before the model run. Recheck power after preparation. No reboot, network, production, provider or arithmetic changes are required.

First run the existing tiny legacy regression with the explicit new bundle/native pins and the previously frozen tiny13-record numerical oracle. The normal BF16 stderr policy remains unchanged; if the parent fails only for that known message, retain its failure and separately report native/oracle outcome. Then run the new registered9B command below with the same source/bundle and a new output directory. Original and archived token pins, source403 and bundle hashes must remain unchanged. Do not edit repository files during either native run.

The prompt/teacher files are synthetic3+1 correctness inputs, not a performance prompt. Native setup creates a fresh internal UUID. Exactly two complete records and a successful original parent are required. Retrieve bounded regular reports/source files excluding external bundle symlinks; independently verify archived source and bundle identities and run the new checker with the complete raw stdout SHA. Preserve every refusal or failed attempt in its original location.

```sh
ssh -T -o BatchMode=yes -o ConnectTimeout=6 darkbloom-24 'python3 -B /Users/developer/DarkbloomDev/cluster-research/registered-dense-short-parity-parent-draft/run_short_parity.py --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime --release /Users/developer/DarkbloomDev/cluster-research/peer24-short-parity-package-20260914/unpacked/bundle --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B --profile registered_qwen35_9b --tokens-file /Users/developer/DarkbloomDev/cluster-research/short-parity-inputs-20260914/prompt.json --tokens-sha256 9c6bc7ac937d2daffe5ecdbe7eb3a59aba4f43e96a58a99f08838d4ce48c92ba --teacher-tokens-file /Users/developer/DarkbloomDev/cluster-research/short-parity-inputs-20260914/teacher.json --teacher-tokens-sha256 9d1f4e3a2170ce5f947bcdfa249a77885875b0d9d7af88ad3fbc7f7cd7a224fa --expected-native-sha256 c07954680b1c2d4582d1f200d6dbf850331849fb61b0209ac919a0784c2ba708 --output /Users/developer/DarkbloomDev/cluster-research/runs/registered-short-parity-9b-peer24-20260914 --reuse-bundle /Users/developer/DarkbloomDev/cluster-research/peer24-short-parity-package-20260914/unpacked/bundle --expected-bundle-manifest-sha256 50c581dc4ec15fd155b921b90a2b1579e6cc3fcbb8c6ec4b6ff577200a915a92'
```


Latest read-only check2026-09-14T18:01:25UTC: peer24 battery12%discharging; peer48SSHtimeout. Receipt peer-power-connectivity-20260914-180125.json 1d832082ddf84ebce18c80d1e5c2da95155d476371612d30d1c1f9b26e35ad2a. No native retry, resource-gate change, purge or peer installation. Public offline service/catalog work is complete as described in PREFILL_PLANNING_NEXT.md; native c079/runtime sources remain unchanged.


At 18:27:59 UTC peer24 was online at 11% battery and peer48 remained unreachable;
see peer-power-connectivity-20260914-182759.json. Existing power/resource gates
continue to defer native execution. No retry or configuration change occurred.

The prospective runtime/evidence join is now ready in
short-execution-binding-draft (manifest a3f427d6b3eb810fa20ece09dab78479cb24fb31430c8a00a8c9f4ad5185cd6d).
After a successful original short-parity parent and its independent numerical
receipt, supply the explicit retained files described in that package's README
and run audit_short_execution_binding.py. The package passed 51 CPU tests on
Python 3.14 and 3.9.6 using fabricated records. It does not replace the tiny
regression, admit a model run, or establish historical execution/hardware/NAX.


Latest check at 18:47:26 UTC: peer24 is online at 10% battery/discharging; peer48 SSH times out. Receipt peer-power-connectivity-20260914-184726.json SHA96c172fa5a141387e839f7b2a7f07c8eaa54b862806b2f7e46d6ae25f877ae32. Native remains deferred by the original gates. The new public CPU benchmark coordinator is described in BENCHMARK_STUDY_NEXT.md and does not change native admission.
