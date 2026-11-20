# Expert projection physical successor

This fresh source and remote namespace preserves the old expert harness, installation, and failed synthetic result. It binds the actual two successful projection-policy builds from the shared workspace, both to source receipt `6fc4df5254a255cf9ff943b01b4a45aabf326467834acbbf575b18e21b9afcbe`:

- `GemmaExpertAxisCheck` build 3: `5e82a28d03beb715aa821bfb44389c43a96689d4ddfc57d299f6f7f7f1588943`, 46,916,824 bytes.
- `GemmaExpertRDMACheck` build 2: `0df9ab04f65f305c25c732b9cc4e3572c9587e0de71de2bbcb7ca89add744ef0`, 46,916,840 bytes.

`artifact-bindings.json` was produced by `bind_build.py` from the actual successful receipts. The binder checks their matching applied-source identity and every projection override. It does not read the payloads; the existing deployer performs the full actual binary/resource hash checks before and after copying. The original metallib, Metal resource, and matrix pins are retained. No guessed binary identity or executable fallback exists.

`package/expert_results.py` now requires the seven actual per-rank projection policy fields and independently reconstructs the full-bank sort/density/tile decision. The numerical result still must be byte exact. Returned assignments and expert output value counts use only the original top-k slots, and both RDMA tensor directions are checked against those original counts. A follower's acknowledgment is joined to the full comparison digest, which now includes both policy records. Padding never increases the 264-assignment wire bound. This is one-layer numerical qualification; no throughput, whole-model quality, device-only routing, encrypted RDMA, or serving claim follows.

`package/expert_retirement.py` uses the existing `PipeWorkers` bounded collect, EOF/poll, wait, and group-fence path. Only the zero-exit/numerical decision moves after complete retirement. A full failing report and natural exit 2 are retained, then rejected. Partial output, trailing events, stderr, cancellation, absolute expiry, unresolved cleanup, or any nonzero exit still fail. The old worker helper is byte-exact. The original 300-second native and 315-second parent lifetimes, 6 GiB floor, process ownership, journal checks, peer cancellation, and alias restoration are preserved. `validate_returned.py` additionally requires the new retirement-before-validation observation.

Source author performed metadata binding and AST/source checks only. The 13 parser controls and seven actual-child CPU controls are staged, unexecuted. Root's native builds and 13 Swift projection controls are external results, not author execution. Root should run these Python controls before deployment, in a granted quiet slot:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/gemma4-expert-projection-execution-20260920
python3 -B check_source.py
python3 -B -m unittest -v test_contracts test_retirement
```

Then, under root's physical/bulk slot, prepare/install once into the fresh remote root `/Users/developer/DarkbloomDev/gemma4-expert-projection-execution-20260920`:

```sh
python3 -B deploy.py prepare
python3 -B deploy.py install --host darkbloom-48
python3 -B deploy.py install --host darkbloom-24
```

Begin with the strict synthetic-small regression. Stop on failure, retain all evidence, and do not continue to later cases until root reviews the actual result:

```sh
python3 -B run_case.py prepare --name small-projection-1 --kind synthetic-small
python3 -B run_case.py solo --name small-projection-1
python3 -B validate_returned.py /Users/developer/DarkbloomDev/cluster-research/gemma4-expert-projection-execution-20260920/cases/small-projection-1/solo
```

After that gate, the corresponding mandatory real-checkpoint and two-rank commands use the existing model and exact full five-case token catalog:

```sh
python3 -B run_case.py prepare --name checkpoint-projection-1 --kind checkpoint --layer 0
python3 -B run_case.py solo --name checkpoint-projection-1
python3 -B validate_returned.py /Users/developer/DarkbloomDev/cluster-research/gemma4-expert-projection-execution-20260920/cases/checkpoint-projection-1/solo
python3 -B run_case.py prepare --name rdma-projection-1 --kind rdma --layer 0 --ownership contiguous48_80
python3 -B run_case.py pair --name rdma-projection-1
python3 -B validate_returned.py /Users/developer/DarkbloomDev/cluster-research/gemma4-expert-projection-execution-20260920/cases/rdma-projection-1/pair
```

The second unequal, noncontiguous ownership is the same three commands with a fresh name and `--ownership strided43_85`. Every run writes create-only jobs/output directories. No request to rerun old failed cases or overwrite an installation is included.
