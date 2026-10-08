# Distributed cluster delivery — current handoff

Updated 2026-09-15 20:18 UTC. Goal ACTIVE; plan-first request completed. Execute the reviewed ordered plan in d-inference/docs/design/distributed-cluster-execution-plan.md and distributed-cluster-delivery.md. Full user requirements remain authoritative; no release or performance qualification is complete.

## Repository and resources

Repository /Users/developer/DarkbloomDev/d-inference, feat/cluster-inference, HEAD 605651bb95d71c1da9bb122107925143e9441973. Latest master merged; preserved backup and stash remain. No production push/deploy. Local M4 Max36GB; peers darkbloom-24 (192.0.2.250) and darkbloom-48 (192.0.2.223), both M4 Pro14CPU20GPU with24/48GB. SSH keys/12h control sockets configured. Credential in machines/CREDENTIALS.private.md, password column row2; strip Markdown backticks. Never print secret or put in argv.

Root owns SSH/network/GPU and native benchmark builds. Arithmetic agent was explicitly authorized isolated local shared-library builds with jobs2, now finished. No active remote native worker or temporary alias. Exo GUI and its two exact workers stopped on24 for measurements; leave stopped. No system services stopped. Preserve actual-free6GiB/zero-swap/AC/pressure guards. Do not reset bridges/interfaces or reboot.

## Actual results and completed increments

* Resident solo48 passed one load + warmup +3 fresh8192-token requests at512 chunks/output1/MTP off. Median441.6795 TPS,18.547385417s. All reference comparisons, state retirement and shutdown passed, min actual free8.6383GiB. Diagnostic internal timing only; not external TTFT or representative qualification. Public report docs/reports/2026-09-15-cluster-resident-solo-baseline.md. Evidence returned-resident-solo-aa7d-20260915 and resident-solo-aa7d-summary-20260915.json.
* JACCL native7b4ae5d7 built, CPU checks passed, deployed both.27 source files promoted main. Physical launcher V2 has53 pinned members and17 CPU tests. Cut12/20 serial8192/512/output1/four requests.
* FIVE physical attempts, none reached a request. Attempt1 rejected normal bounded JACCL retry text (fixed in V2); attempts2–5 rank0 actual-free floor during load, rank1 Ready. Both remote native leaders reaped/groups fenced each attempt and all exact48 aliases rolled back with bridge/management checks. Do not claim distributed TPS.
* Attempt5 used new payload-cache native0ae486743782c8942ba3c8aa0fcf2eb61be49522ea64786c46a0ce0207b9e392. Descriptor-local F_NOCACHE and preserved rehash policy, four files promoted main; build303.718s, worker6/adapter42 CPU records passed. Package435 members179c973561c5237744be5b505cb840c516604fd4e58dd992d93805eecc519fd2, bundlef04ba06d77080a7f6f3eca7aa873c89064b67e816d697b6f33f35af194eed0e4, both resident-payload-cache-runtime-20260915. Cache flag ALONE DID NOT fix growth: rank0 free9.089→5.401GiB. See resident-physical-attempt5-cut12-20260915 and alias receipt. Local SSH killpg EPERM retained; remote cleanup confirmed. Zombie-only process group is plausible source explanation, not observed cause.
* Provider Distributed adapter5 files and3 test files promoted main;20 tests passed (169s total) via swift test --jobs2 --disable-automatic-resolution --filter DistributedCBv2. Exact handoff484e4b666919faaebe8d5195e57bebb5df94027661670818d6e68cda2aba645b. No live backend/default factory wiring. Normal finish is false callback, abnormal path calls cancel; resources held until both peer retire/fence.
* External streaming benchmark scripts in main;10 CPU/localHTTP tests pass. Clocks actual SSE text from request send, separates reasoning/content, preserves failure, no inferred token/chunk rates. No real provider API run yet.

## Current memory finding and immediate root work

System footprint on24 found no large user process to stop; kernel footprint ~2.6GB, biggest user RSS ~598MB. No system services stopped. CPU-only1GiB reads with F_NOCACHE filled ~1GiB cache, with or without F_RDAHEAD0. Then aligned probe after fresh purge used ctypes posix_memalign16KiB and3 separated512MiB reads:

- aligned pointer+offset: file-backed growth35,078,144B;
- pointer+32:530,726,912B;
- offset+8:486,244,352B.

All reads exit0/empty stderr. Receipt peer24-aligned-checkpoint-read-observation-20260915.json; source aligned_checkpoint_read_probe_20260915.py. Initial driver password parser failed because Markdown backticks were retained; fixed locally, failure receipt retained. Credential itself works. This result supports aligned IO; no actual loader memory saving proved yet.

Pipeline agent IMPLEMENTING aligned selected-payload reader in aligned-selected-payload-read-draft-20260915 against frozen payload-cache workspace. One8MiB aligned scratch, aligned windows, only selected intersections copied; no global cache flag. Explicit read/padding/scratch counters and scratch OS admission; cached/reference reads unchanged. CPU file boundary/mutation fixtures. Arithmetic agent will independently review.

Root cloned resident-aligned-read-build-20260915/workspace with APFS clone of payload workspace; NO overlay applied or build yet. Prepared build_aligned_read_worker_20260915.py (expects records/source-snapshot.json and reviewed-overlay.json). Need apply reviewed overlay, pin full source snapshot, remove only cloned relocated ModuleCache, build with matched metallib + JACCL26.2 flags/jobs2, run native CPU checks, package/deploy both, then attempt6 after purge with bounded alias.

Root copied frozen53-file launcher into resident-physical-integration-v3-20260915; NO modifications/freeze/test yet. New sourceLoad.selectedPayloadReadAccounting requires strict DTO validation before comparing receipt with unchanged semantic control. Then retain full validated receipt for sourceLoadReceiptSHA256 used in final capture. Do not silently drop arbitrary fields. Await exact DTO from pipeline. Update only needed validator/tests, freeze and deploy V3. Numerical reference and memory floors unchanged.

## Shared runtime / generation / product protocol parallel work

Arithmetic compiled52-source shared runtime first try94.750s and66-source runtime+generation first try4.468s, no fixes, isolated shared-cluster-runtime-build-20260915/workspace/libs/darkbloom-cluster. macOS14 library build, not real JACCL worker. Final handoff generation-library-handoff.json SHA1baeb52fb6117e2d6b6623306d9d8668182eb16ec61947f2c3eacb04c3a9e520; tested move list21a41bd86ec998e686c39d60d62f1d1b00c0b1528bb6807d3945bdf7e208488d. All symbols internal; no main move yet because experiment test/diagnostic consumers need mapped facades. Cache overlay excluded deliberately.

Generation handoff resident-generation-build-20260915/driver-handoff, manifestf6dec17afe5a6bd1743388150c36ba2bc9859d999299ef04a5c9226cf8e591b6.15 exact runtime files, real MLX driver now typechecked. Foundation fixtures pass. P8192/O128 creates16 prefill+127 decode frames, capacity8320/frontier8319; both commits/token publication/continue-stop/retirement ACKs.16MiB pre-state point-to-point boundary limit enforced. No native worker/provider hookup/actual generation yet.

transport_probe resumed bounded Foundation-only native worker pipe protocol/parser/tests in private overlay; coordinate with arithmetic. Version/epoch/request IDs, bounds, reserve/admit, committed tokens, clean finish vs abnormal cancel, retirement/shutdown. No main mutation/SSH/GPU/heavy builds.

## Remaining delivery

First actual physical9B correctness, continuation and fail/reconnect; live Swift owner/native worker + endpoint; then measured work division/chunks/overlap vs best solo, MTP transactions,27B then Gemma adapters, CLI trust/config/status/doctor/start, qualification and documentation. SLA external request send→first text token10s+1ms/prompt token;8192→18.192s. M3 Ultra800/1000TPS projections only. No M3 hardware required to progress.

See previous handoff backup for reference artifact/config/prompt/native pin details. Frozen old references/workspaces/packages remain unchanged. No actual MTP,27B or Gemma distributed result.
