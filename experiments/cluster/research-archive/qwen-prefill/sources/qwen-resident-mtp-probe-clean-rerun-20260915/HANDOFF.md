# Fresh registered 9B MTP proposal rerun

This private package repeats P32/C16/O2, cut4, serial prefill and one **unaccepted** depth1 proposal. It uses the unchanged native `34fcd255f3bab741586476867da26035cfd0ee0f2ba6ee708551c07d0bdbcba1` with its matched resources. It replaces the owner/controller control binaries and their four libraries with one coherent, freshly built set. Root owns deployment, preflight and execution. No new model or remote operation has run from this package.

The prior run remains failed: its two ordinary target tokens and proposal did not provide both authenticated owner release acknowledgments. Reviewed administrative journal recovery is separate. This package never clears a journal outside the owner's ordinary, proven release path.

The new identities are:

- Request: `1c85b39a-1ad9-4833-9184-e166fd73fd12`
- Membership epoch: `f95f3229-8cac-4b87-a592-2613369f42e8`
- Controller configuration SHA256: `8f52f572d290f1a7cb3b33fc072d8de1d84348db44d3953d50c8d99eb1c6ae1e`
- Expected agreement fingerprint: `557246687227e6ae56158480e7d5784b7cc516296f303f64d382eac43286d4ab`
- Prospective validator policy SHA256: `77bbad4a137148a26f526bddbd4e73d0dd4016807deb33fd89bfcdbc6932587e`

`request.json` differs from the earlier request only in UUID. Expected tokens remain unspecified. The ready templates retain zero placeholder epochs; the controller's authenticated open supplies the fresh epoch to each owner's identity factory. Pinned model, artifact, configuration, Plan, arithmetic and opaque storage commitment remain unchanged. No candidate values were used to prepare these new identities.

## Coherent controls and canonical exclusion

`controls/bundle.json` SHA256 is `9dfda2faebdf63293ab5126d9c6ee63aecd5fe6b09cd5952a6cae538500d5bd7`. Use its complete six-file set:

| Artifact | SHA256 |
|---|---|
| Owner | `5aa5450c2a9bef4dad2caa06d437aa4a80710b4ad737b773a5b97a16abc7c62d` |
| Controller | `13311eeac86a019a7c187249fbe7393471e9e158821f5eaa8d5637f392851a74` |
| Protocol | `357fe913bb6889f53439359a74952935fa99d088fcea4754f0f3588c58f6f1cb` |
| Bootstrap | `54d306268868669ac13f32fd11dee04fd1f0622114fbdb53fb29dbfac703e555` |
| Process | `5ca5cbd4dffdcc907c389f3e3b5ed91f8366bc43160f508ca0d448eb2981351d` |
| Remote | `d7f29a4878504481534a9c631be83dce83445324826082be57a9ae43dc309ef1` |

Build manifest `5cfbce678c37fda7af42fc34500192a9765c306baf9df3951ab49c51140b03c9` binds the 36 module sources and unchanged owner/controller entry sources. Its author reports compilation/linkage PASS in 4.367 seconds; this is not a new physical release test. The reviewed Service delta consumes a valid shutdown as drain when the native child is already fenced/terminal. It does not synthesize shutdown completion, terminal observations or release ACKs.

The actual new `ClusterDeviceLease` wraps the shared `ClusterDeviceExclusion`: same canonical `/Users/developer/.darkbloom/cluster-device/native-device.lease`, exclusive flock, empty-journal admission, recorded-byte/path/inode checks and same-owned-journal resolution. These source files and the owner fix review are retained under `lineage/`. A nonempty journal remains a refusal.

## Root deployment and preflight

The NEW owner directory on each host is `/Users/developer/DarkbloomDev/owner-native-mtp-probe-clean-20260915`. Native remains at the previously installed `/Users/developer/DarkbloomDev/qwen-mtp-registered-probe-runtime-20260915`. Existing installed defaults, old owners, failed evidence and native bytes stay unchanged.

From this directory, root may run the reviewed copy-only helper:

```sh
/usr/bin/python3 -B deploy_copy_only.py
```

It refuses an existing destination, uses the unchanged private identity path and exact pinned known-hosts bytes, creates only the new owner tree, and fully rehashes its 12 declared members. It also observes an empty canonical journal without modifying it. Deployment receipts go to sibling `qwen-resident-mtp-probe-clean-rerun-deployment-20260915`. No model or owner is launched by that helper.

Before launch, root must independently verify `deployment-rank0.json`/`deployment-rank1.json` against both actual new trees, all four entries of `native-runtime-reference.json` against the existing native tree, and empty owner evidence directories. `preflight-plan.json` records those exact roots and gates. Require no owner/native/provider/reference process, empty safe canonical journals, AC, zero reported swap, acceptable pressure and at least 6 GiB actual free on both hosts using the unchanged `reference_resources` sampler. Copy-time journal observations are not launch-time proof.

## Root launch and collection

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-probe-clean-rerun-20260915
/usr/bin/python3 -B run_physical.py
```

Output is exclusive `physical-1/`. Parent/monitor/resource/alias algorithms are unchanged. The corrected parent retains the alias while it observes both remote process/journal states, including after a local controller timeout or interruption. The controller remains bounded by 300-second owner lifetime, 90-second startup, 120-second request, 305-second hard alarm and 315-second parent timeout. Remote observation can continue through the existing 420-second bound; alias ownership has its existing 600-second bound. Swift creates all transmitted same-Mac uptime deadlines; Python clocks are local observations only.

Root must retain both evidence sidecars named `1c85b39a-1ad9-4833-9184-e166fd73fd12.json`, controller started/result records, raw resources, local reaping/group-fence observations, both remote process/journal postflights and alias restoration. Success requires target2 completion, assistant retirement, both real native-cleanup observations and authenticated lease ACKs, exit0, unchanged pins, empty journals and no remaining owner/native processes.

After collection, use the unchanged prospective validator:

```sh
/usr/bin/python3 -B validate_probe.py --rank0 /absolute/rank0.json --rank1 /absolute/rank1.json --controller /absolute/controller.stdout.jsonl --output /absolute/fresh-comparison.json
```

It requires three frames/frontier33, assistant history31→32, two matching cross-rank target IDs and exactly one unaccepted proposal; either proposal match or mismatch is valid. It checks controller cleanup claims but does not independently attest physical cleanup/resources, reconstruct token chains, establish target numerical correctness, or qualify accepted-prefix generation, throughput or TTFT.

`assembly-checks.json` records seven pure metadata/fabricated-value groups, including stale epoch/agreement/config and missing cleanup-ACK rejection. No subprocess, native, model or network execution occurred in those checks. Unchanged broad behavioral suites were not rerun for constant changes. Source/body inverse checks preserve prior algorithms. The first assembly's overly strict AST assertion included the expected copy-output-directory constant; its failure and partial assembly are retained separately, and the corrected inverse check restores that constant before comparison.
