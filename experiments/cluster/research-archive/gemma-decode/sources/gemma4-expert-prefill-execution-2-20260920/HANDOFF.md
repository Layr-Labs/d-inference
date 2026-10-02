# Actual source-package metadata correction

This successor preserves43ce7619 unchanged. The actual applied source receipt1dd0bfaf uses optional manifestSHA256 on its C128 and description source-package records. The binder now accepts exactly the two original fields or those two plus that named field, requires unique package names, and checks the optional value against the frozen expected manifest and its exact integration member. Final source-row equality and every compiler/binary/resource check remain unchanged. No new binary identities are supplied. Run the four new `test_build_packages` controls with the original26 controls under root scheduling. The local source namespace is gemma4-expert-prefill-execution-2-20260920; the unused fresh remote namespace remains gemma4-expert-prefill-execution-20260920 and its create-only installer still refuses an existing installation.

# Expert C64/C128 qualification harness successor

This source-only successor reuses the frozen `gemma4-expert-projection-execution-20260920` harness (manifest `869c635cb18a1d750f2a3805e6d9f58a3dd4c58b47bc6de01ced59a89638d956`) in a new local and remote namespace, `gemma4-expert-prefill-execution-20260920`. It has no actual binary binding, deployment, jobs, or results. All changed paths and retained source pins are listed in `source-changes.json`; prior installations, builds, and observations are untouched.

## Exact source and build gate

`bind_build.py` requires actual successful Axis and RDMA compiler receipts plus their same applied-source receipt. It checks the final source union from these three packages, with later overlays replacing only their named paths:

- Projection policy: integration `e9245b99cb55496bb097014b9bf253ae483cc909d45305a4fb4e0df041693b87`.
- C128 envelope: manifest `96b09205616dc075d0efb09c6962a630f7e88ba14ee8a7b76e6613fe34b44a06`, integration `13b9d67c161a84c58dda2472d4a61b6019376d132aebac7bae6d47b517d4bc6e`.
- Description correction: manifest `ed9ee5cfa7e0357d6f003c9553204425d40c6ac8fabaf5656dcdda0ede13748e`, integration `59115464bb9906de761210243baf9dfa044a2104daf3528eafcf61966132490c`.

The applied receipt must contain each exact `sourcePackages` name/integration pair and every final override hash/size. Both actual build receipts must report natural successful compilation, reaped compiler, no GPU execution, the same source receipt, the correct product, actual byte count/hash, and the existing macOS26.2 target path. The binder creates `artifact-bindings.json` exclusively. It never reads large binary payloads. The unchanged deployer verifies actual executable/resource hashes before and after copying. Missing receipts, old source rows, old binaries, or absent bindings cannot activate deployment or jobs; no fallback identity is supplied.

Run the read-only source check before the builds:

```sh
python3 -B check_source.py
```

It reports pending actual bindings honestly. Root can then bind real receipts, using their observed paths and hashes:

```sh
python3 -B bind_build.py --axis-receipt ACTUAL_AXIS_JSON --axis-sha256 ACTUAL_SHA \
  --rdma-receipt ACTUAL_RDMA_JSON --rdma-sha256 ACTUAL_SHA \
  --sources-receipt ACTUAL_APPLIED_JSON --sources-sha256 ACTUAL_SHA
python3 -B check_source.py --require-build
```

The uppercase arguments are required late-bound actual evidence, not runnable placeholder identities. Do not run the historical binder against newly built products or copy the old artifact binding into this namespace.

## Catalog, bounds and numerical acceptance

The default RDMA job contains all seven exact token counts `[1,7,8,9,33,64,128]`. Unknown34/129, duplicate/out-of-order counts, and malformed identity/role jobs are refused. Synthetic E16 retains60 cases over the original five sizes. Real E128 geometry requires42 cases; checkpoint replay requires14. Both ownership maps remain `contiguous48_80` and `strided43_85`.

The parser independently reconstructs the unchanged sorted-RHS policy and its original-slot assignment count, with a1024-assignment maximum for E128 and the old264 bound for E16. C64/C128 must pass byte-exact raw expert output, unchanged weightedExpertSum, and checkpoint post-norm comparisons; no tolerance is added. Padding remains local and cannot appear in transmitted rows or weighted slots. Bilateral input/output bytes, route digests, case identities and comparison-result hashes must agree.

The native source reserves32MiB each for additional host/native wire staging and admits at most5,767,168 payload bytes under an8MiB wire limit. The parent report/stdout limit stays2MiB, native Axis final bound1MiB and RDMA bound2MiB. Expanded bounded metadata fits those unchanged caps; actual output still has to pass them. Native300s, parent315s, collection64MiB, control32KiB/128-record bounds, 6GiB free floor, AC/pressure1/zeroSwap, original group ownership, canonical journal/flock, peer cancellation, alias restoration, and natural retirement validation are unchanged. Larger cases may fail the existing deadline or resource gates; that is a retained refusal, not grounds for an automatic limit increase.

The live numerical checker remains authoritative after process retirement. Complete failing output with natural exit2 is retained and then rejected; stderr, partial/trailing output, stale jobs, timeouts, missing cleanup, or alias failures still fail. The seven core ownership/resource helpers and the retirement helper are byte-exact to the predecessor.

## Root qualification sequence

Six new parser controls are staged alongside the13 original parser controls and seven actual-child retirement controls. None was executed by the author:

```sh
python3 -B -m unittest -v test_contracts test_prefill_contracts test_retirement
```

After root builds the actual products, run the original Axis argument controls, RDMA `--check-local`, and both `--describe`/`--check-arguments` metadata paths with a real job bound to the new RDMA hash. Require1024 assignments,8MiB tensor limit,32MiB host/native staging, and the exact original job scope. The optional pure parser below checks saved outputs without launching anything; its receipt explicitly does not prove who executed those bytes:

```sh
python3 -B validate_description.py ABSOLUTE_NATIVE_JOB_JSON ABSOLUTE_ACTUAL_STDOUT_JSON
```

Only after root reviews actual CPU/build/metadata receipts and grants the physical slot:

```sh
python3 -B deploy.py prepare
python3 -B deploy.py install --host darkbloom-48
python3 -B deploy.py install --host darkbloom-24
python3 -B run_case.py prepare --name small-prefill-1 --kind synthetic-small
python3 -B run_case.py solo --name small-prefill-1
python3 -B run_case.py prepare --name geometry-prefill-1 --kind synthetic-gemma
python3 -B run_case.py solo --name geometry-prefill-1
python3 -B run_case.py prepare --name checkpoint-prefill-1 --kind checkpoint --layer 0
python3 -B run_case.py solo --name checkpoint-prefill-1
python3 -B run_case.py prepare --name rdma-prefill-contiguous-1 --kind rdma --layer 0 --ownership contiguous48_80
python3 -B run_case.py pair --name rdma-prefill-contiguous-1
python3 -B run_case.py prepare --name rdma-prefill-strided-1 --kind rdma --layer 0 --ownership strided43_85
python3 -B run_case.py pair --name rdma-prefill-strided-1
```

Stop after any failure, retain the evidence, and validate each returned `cases/NAME/solo` or `cases/NAME/pair` directory with `validate_returned.py` before advancing. Existing strict SSH/host-key configuration is unchanged. A PASS would qualify only this bounded one-layer numerical fixture and original process/lease retirement. It would not establish full-model EP, device-only routing, encrypted transport, serving eligibility, or throughput.
