# Private configured cluster owner

This developer tool builds the shared SSH owner service for two-host qualification.
It does not install or enable the provider's public cluster commands.

From the repository root, choose a new output directory:

```sh
bash libs/darkbloom-cluster/Tools/ConfiguredOwner/build.sh /absolute/new/owner-bundle
```

The bundle contains `darkbloom-owner-qualification` and four portable Swift
dylibs. Its sole invocation is `cluster worker-owner --stdio`; paths and native
environment come from the owned, bounded `owner.json` beside the executable.
The configured SSH endpoint can select this executable for qualification.
It requires the private bootstrap attachment and the closed two-member mesh
relay; it starts no unauthenticated native bootstrap fallback.

The settings use exactly these fields:

| Field | Value |
| --- | --- |
| `schema` | `darkbloom_configured_worker_owner_v1` |
| `clusterID` | Expected configured cluster identity. |
| `workerExecutable` | Absolute native worker path. |
| `modelDirectory` | Absolute model directory. |
| `leaseDirectory` | Private local device-journal directory. |
| `stageCut` | Current Qwen stage cut: `4`, `8`, `12` or `16`. |
| `maximumLifetimeSeconds` | Integer from `1` through `300`. |
| `workerEnvironment` | Explicit native environment from the local configuration. |
| `readyTemplateBase64` | Encoded worker ready event with an all-zero placeholder membership epoch. |

The template specifies expected model, build, profile, rank and plan identity;
its capacity is a validation placeholder. Actual readiness and available capacity
come from the native child. The authenticated open supplies the fresh epoch, and
the owner reconstructs deadlines on its own clock.

Use [the control checks](../../README.md) before target-host qualification.
Successful compilation does not prove SSH authentication, native numerical
correctness, RDMA execution, memory safety or performance. Unresolved device
journals refuse another launch; this tool provides no automatic orphan recovery.
