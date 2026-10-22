# Owner release EOF correction for MAIN

This one-file candidate removes the endpoint's post-frame process-liveness shortcut. A process may exit while its valid release ACK is still buffered. `ClusterOwnerPipe.read` already drains pending frames and throws on actual EOF; the endpoint should let that existing path decide completion.

Target: `libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift`.

| Identity | SHA-256 |
| --- | --- |
| Exact current MAIN preimage | `a551c2f317b48b9e4e35656d03337f5f4b770da2b45821100e34ca791d2aa9ab` |
| Proposed postimage | `cb0e73b6fc308ae6e3bd6ec359875b28f48bc0c971cf42c5a57d2b853162f77a` |
| Qualified private source manifest | `60417b284854105963be1ad2c5d4d85ea658a5f16eb9ee1ce26796cdf4812045` |
| Actual private helper/case receipt | `9af71c63a19c43118361bc77c50cc9db12c5a8929c76f92df1e21a979f9b91e9` |

The entire MAIN `readLoop` before the edit is byte-identical to the private correction's original function; the entire proposed function is byte-identical to its qualified successor. The existing two-second grace, diagnostic drain, native terminal, current owner/lease/incarnation/sequence validation and successful exit requirement remain unchanged. No API, package dependency, resource allowance, admission gate, signing path or native profile changes. No test-only callback is added.

The private actual-owner fixture reproduced lost buffered ACK on the old code. Its valid successor accepts the actual ACK; missing/wrong ACK and abnormal exit still refuse release. Those four deterministic cases used the qualified private composition and its native-key relay scheduling callback. They are provenance for this identical function, not a claim that the new MAIN composition has run them. Their source and result pins are retained in `integration.json`; no private dependency is imported.

## Applicable instructions and focused context

The pinned repository `AGENTS.md` says “Keep the codebase modular, never monolithic” and prefers “small, single-responsibility files.” This patch stays in the existing endpoint and adds no framework. The same instructions prohibit committing binaries; this candidate contains only text/source. Existing unrelated MAIN work and frozen artifacts remain untouched.

`main-context.json` pins 51 small files: the actual Protocol, Process, Bootstrap and Remote Swift source closure; package metadata; applicable AGENTS; the existing SSHChecks runner/fixtures; and ConfiguredOwner source. Remote already depends only on those three control modules. The focused runner compiles them directly with Swift 6 warnings as errors, macOS 14 target and at most two jobs. It does not build MLX or load model/remote code.

## Review and qualification sequence

From this candidate directory, the read-only preflight is:

```sh
python3 -B check_sources.py --main-state before
```

After root review, check/apply `runtime.patch` from MAIN using the exact preimage; then run `check_sources.py --main-state after`. The existing required test command, from MAIN, is:

```sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
```

Root should retain regular stdout/stderr and use its existing bounded owned-process wrapper. The runner preserves all 13 owner/transport/bootstrap groups, six retirement/shutdown cases and five diagnostic-drain cases, then compiles ConfiguredOwner. Relevant controls distinguish transport loss/wrong incarnation from native cleanup, keep release usable after retirement, retain journals on EOF without release, capture post-ACK diagnostics, reject abnormal exit and fence a hung owner within the existing grace. No test assertion or timeout is changed. No full Provider or native product rebuild is required for this private Foundation-only source qualification.

The author has only checked source pins, the exact one-hunk inverse and function equivalence. MAIN is not modified and the new MAIN composition is not compiled or tested. Root schedules the above checks after the current physical runs; actual check results remain required before treating this composition as qualified.
