# Gemma4 expert physical qualification harness — 2026-09-20

This source-only successor directly reuses the resident benchmark's owned Python child, canonical inherited flock, resource sampler, strict SSH configuration, bounded JACCL stderr parser and temporary alias lease. It installs two already compiled products in a fresh private root. It does not modify the resident benchmark, MAIN, model files, native sources, canonical journal, or serving policy.

Observed build bindings are in `artifact-bindings.json`. AxisCheck is `0cae8c020b72de5f2b1c63284384eecfeb215609586674742e2d8567e9eff6ea`; RDMACheck is `c5c0a63716c0dc7f75b31f4ea65e013c6fde6a21abd90e3683cb2f21c99f604d`. Both bind actual `applied-experts-2.json`, including the explicit typed Float-loop compile correction and RDMA staging lifetime correction. Source preparation read only their existing small build receipts; it did not rehash/copy binaries. Authorized deployment preparation verifies and APFS-copies the actual binaries plus exact MLX/paged-attention resources, verifying before and after copies. All install/run directories are create-only; failed attempts remain retained.

The primitive runs on darkbloom-48: synthetic-small (60 cases, Float32 and BF16), synthetic-gemma (30 BF16 cases), then actual registered checkpoint layer0 (10 BF16 cases). Cases cover T1/7/8/9/33 and both ownership maps; synthetic cases additionally cover balanced and entirely rank-local routes. The RDMA job uses darkbloom-24 rank0 and darkbloom-48 rank1, a fresh epoch/request UUID per job, exact binary identity, real layer0, T1/7/8/9/33, and explicit contiguous48/80 or strided43/85 ownership.

Each RDMA rank loads only its owned expert bank; rank0 additionally owns the unsplit one-layer reference/router. The fixture permits CPU route readback. Rank1 returns unweighted assignment outputs; rank0 restores original top-k slot order and calls unchanged weightedExpertSum/post-normalization. Acceptance requires exact bytes for all three comparisons, complete native case membership, matching route/result hashes, exact original-slot assignment conservation, and bilateral tensor/control byte accounting. This is a one-layer numerical qualification, not full-decoder EP, device-only dispatch, encrypted RDMA, or throughput measurement. Native resource charges and graph/allocator headroom remain unchanged. Parent and native require AC, pressure1, zero swap, and at least 6 GiB actual free; native admission applies its additional full reference/bank/activation/staging reserves. A resource refusal is retained, never relaxed.

The native alarm is 300 s, the remote owning supervisor is 315 s, and each SSH execution is bounded at 345 s. On one-rank failure the parent publishes the peer's exact job-bound cancellation record. The original supervisor fences and reaps only its owned native group. Parent postflight requires both canonical journals empty/unlocked and no known native owners before explicitly releasing the alias. If cleanup cannot be proven, it fails and waits for the original alias lease's bounded expiry; it does not clear journals or kill unrelated processes. No release ACK is invented: this standalone diagnostic uses an inherited flock and actual process exit, explicitly recorded as `protocolReleaseACK: false`.

Collection is bounded to 64 MiB per rank, 16 MiB per file; native reports are at most 1 MiB primitive / 2 MiB RDMA. `validate_returned.py` separately checks exact native stdout/terminal/job/launch/PID/gate joins, raw resource samples, natural zero exits, drained pipes, absent groups, unchanged journal identities, peer source/scope/numerical/traffic joins, and actual alias restoration. A parent `completed` receipt alone is insufficient numerical acceptance. Captured timings are not TPS evidence.

Root-only commands after source review and an explicit physical/bulk slot (none executed by the author):

```sh
cd /Users/developer/DarkbloomDev/cluster-research/gemma4-expert-execution-20260920
python3 -B -m unittest -v test_contracts.py
python3 -B deploy.py prepare
python3 -B deploy.py install --host darkbloom-24
python3 -B deploy.py install --host darkbloom-48
python3 -B run_case.py prepare --name small-1 --kind synthetic-small
python3 -B run_case.py solo --name small-1
python3 -B validate_returned.py cases/small-1/solo
python3 -B run_case.py prepare --name gemma-1 --kind synthetic-gemma
python3 -B run_case.py solo --name gemma-1
python3 -B validate_returned.py cases/gemma-1/solo
python3 -B run_case.py prepare --name checkpoint-layer0-1 --kind checkpoint --layer 0
python3 -B run_case.py solo --name checkpoint-layer0-1
python3 -B validate_returned.py cases/checkpoint-layer0-1/solo
python3 -B run_case.py prepare --name rdma-48-80-layer0-1 --kind rdma --layer 0 --ownership contiguous48_80
python3 -B run_case.py pair --name rdma-48-80-layer0-1
python3 -B validate_returned.py cases/rdma-48-80-layer0-1/pair
python3 -B run_case.py prepare --name rdma-43-85-layer0-1 --kind rdma --layer 0 --ownership strided43_85
python3 -B run_case.py pair --name rdma-43-85-layer0-1
python3 -B validate_returned.py cases/rdma-43-85-layer0-1/pair
```

Stop the sequence on any failure. Use a new name for any later attempt. Do not label fabricated parser controls or the seven metadata-only native checks as physical qualification. The eight fabricated parser controls are staged; only source AST checks ran during this harness preparation. Keep root controller stdout/stderr in regular retained files and use the existing owned controller wrapper, as for the resident harness.

The applicable repository AGENTS guidance is preserved: use existing lifetime/owner abstractions, trace terminal/cancellation paths, maintain source identities and narrow meaningful checks, and avoid unapproved production operations. These files live only in a new research directory. `predecessor-sources.json` binds the exact nineteen small helper sources initially copied; `source-checks.json` distinguishes unchanged helpers from the expert-specific adaptations. Credentials are never included in the package; the unchanged alias helper reads the existing private credential source only during root-authorized execution and does not log it.
