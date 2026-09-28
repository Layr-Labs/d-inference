# Local dense-policy MTP: exact comparison and bounded timing harness

Source only. This successor preserves the actual memo cohort's supervisor, native300/parent315 deadlines, same-PID inherited lease FD, process/EOF/journal checks, raw AC/pressure1/zero-swap/free6GiB replay, and create-only collection. No compiler, metadata, native, GPU, SSH or sidecar replay was executed by this author. The remote installation namespace is fresh: `/Users/developer/DarkbloomDev/gemma4-local-mtp-dense-20260920-v1`.

The unchanged base execution contract is copied exactly as `package/local_mtp_base_contract.py`. The small new `local_mtp_contract.py` requires the explicit dense operation, exact typed 235-dense/one-head summary, four separate allocation-rounded head rows added to the original reserve, and the policy-bound local/request scopes before invoking all old acceptance/resource/timing/evidence checks. Ordinary uses the original solo validator. All native model/performance/serving qualification flags remain false.

The actual successful dense fixture is a separate parent result: `../harness-target-width-dense-v1/cases/p128-dense-width-controls-1/comparison.json`, SHA `075f4dba32a49c8c5f0dbb1d35361dccae23234ff2685835cc0f14c05f84d398`; 24 rows and 360 state entries exactly equal. This does not substitute for the following actual generation comparisons.

The unused packed-head diagnostic is included in the exact f3c81040 union; these local/remote operations still select the qualified serial-head policy. Actual applied source is `../build/dense-execution-composition-1/sources.json` SHA `c8688c2dca3ef2291ea6b739e1c62cfdb8a4091efc3003f2c9b85b2f605e0b21`.

The native input map in `required-native-sources.template.json` is exact and complete for the 116-file selected composition. `prepare.py` requires an actual successful same-product build receipt, its exact source receipt, native SHA/size and unchanged two Metal resources. The original activation then hashes the actual binary and deployment. No future build/native/source SHA is guessed. `binding-spec.json` pins the source packages and ordered overlay composition.

Before preparation, root may run `python3 prepare.py --check` and the eleven small new metadata controls: `/usr/bin/python3 -B Tests/test_dense_contract.py`. These controls cover local depth1/2, conditioning scope, bool/int substitution, missing/duplicated/underrounded rows, a discarded base reserve, changed policy/request scope and an unselected operation. No actual allocator/model correctness is inferred from them.

After the root-owned native build, prepare source once:

```
python3 prepare.py --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/harness-local-mtp-dense-v1 --build-receipt ACTUAL_BUILD_RECEIPT --sources ACTUAL_APPLIED_SOURCE_RECEIPT
```

Use the new harness's existing bounded `root_run.py` action owner. `deploy-prepare` takes `--binary ACTUAL_NATIVE --build-receipt ACTUAL_BUILD_RECEIPT --sources ACTUAL_APPLIED_SOURCE_RECEIPT`; `install` performs the original bounded48GB install. Then create three fresh P128 capture cases (each one warmup plus three measured requests):

```
python3 root_run.py case-prepare --case p128-solo-capture-1 --prompt 128 --native-operation execute-solo --capture
python3 root_run.py case-prepare --case p128-dense-d1-capture-1 --prompt 128 --depth 1 --native-operation execute-local-mtp-dense --capture
python3 root_run.py case-prepare --case p128-dense-d2-capture-1 --prompt 128 --depth 2 --native-operation execute-local-mtp-dense --capture
```

For each case, run the same `metadata`, then `run`, then `compare` action with `--case CASE`, serially under root's physical slot. A passed `compare` proves the existing physical/execution contract, never numerical equality. Failures remain fresh immutable evidence.

`numerical_compare.py` retains all16 helper definitions from the existing exact P128 comparator byte-for-byte. Only its orchestration adds dense operation/policy/scope validation and the two actual physical comparison receipt joins. `recorded_math.py` and `snapshot.py` are exact pinned copies. Run once for each depth after all physical work retires:

```
python3 numerical_compare.py --ordinary-case ABS_HARNESS/cases/p128-solo-capture-1 --mtp-case ABS_HARNESS/cases/p128-dense-d1-capture-1 --build-receipt ACTUAL_BUILD_RECEIPT --source-receipt ACTUAL_APPLIED_SOURCE_RECEIPT --native-file ABS_HARNESS/deployment/bundle/GemmaResidentBenchmark --package-manifest ABS_HARNESS/deployment/package.json --prompt-file ABS_HARNESS/deployment/prompts/prompt-128.json --output FRESH_ABSOLUTE_D1_COMPARISON_JSON
```

Repeat with the depth2 case and a distinct output. Each comparison independently validates every descriptor/hash/native dtype/shape/frontier, all four complete 262144-value final rows, all 360 KV components and all 64 selected IDs against the fresh same-build ordinary case. There is no tolerance or skipped component. It also verifies actual proposal/accepted-prefix/width counters. Expected exact output has `fullFinalRowsCompared=4`, `stateComponentsCompared=360`, `generatedTokensCompared=64`. The shared source/model/prompt/math and build must match; per-case request UUIDs must be distinct.

Once those actual comparisons pass, the same harness supports fresh P4096/C64/O16 ordinary, depth1 and depth2 timing cases with capture omitted. The physical comparator reports same-process aggregate prefill/decode TPS over three measured requests (45 decode tokens) and every generated ID. Compare IDs and matched workloads across all three arms. This is a local assistant-versus-ordinary timing experiment; it does not claim remote speed, best-solo superiority, external HTTP timing, long-context full-state equality or a production serving grant. The independently staged remote harness owns bilateral execution and must qualify its own target evidence and physical retirement.
