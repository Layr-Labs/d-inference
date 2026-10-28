# Private 48 GiB selected-MTP loading check

This package supervises one installed `MTPSelectedLoadCheck load` process on the
48 GiB Mac. It checks the registered Qwen3.5 9B final stage at cut4 plus the31
inline MTP head tensors and3 explicitly replicated embedding tensors. It does
not initialize a collective, run a forward pass, create request history, or
enable MTP generation. Root owns deployment and the physical invocation.

The native binary is frozen at `acabd7237c8f244db1fe30878f796ec6e4496b43ad82b1df1a0505aea72ea7bf`.
The separate native bundle manifest is `bf09d61315aadb2e7688d02fe27e9c294831a68080938d782f676ef4194a75ef`;
its source-manifest reference is `e6b6126fc28258843e3ba7e85ccb12857e005ecde6c8e2f49d95dc6b8334e37d`.
The source reference is provenance, not an independent source-to-binary proof.
Copy the complete existing native `handoff/bundle` directory, including its
matched `mlx.metallib` and nested `mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal`.
Do not put supervisor output or extra files in that native bundle directory.

## Root-run procedure

Copy every member of this package's `manifest.json`, plus the manifest itself,
into a fresh directory. No local research path is needed at runtime. The runtime
closure includes `stage_checks/{__init__,common,long_profile}.py`, all four
`inputs/*.json` controls, and the scripts named in `check_closure.py`.
Python3.9 and the existing macOS `sysctl`, `vm_stat`, and `pmset` commands are
required. The model directory must already contain the pinned config/manifest
and artifact payloads. The parent hashes only model metadata; native verified
descriptors and checksum verification authorize payload loading.

Create a fresh canonical job from `example-job.json`, replacing its UUID and
absolute deployment/model/run paths. Keep the fixed hashes,300s native lifetime
and315s parent lifetime. The run directory must not exist. Its existing parent
must resolve without symlinks; run output may not overlap inputs or the canonical
device gate. Hash the exact canonical UTF-8 job bytes, including final LF.
The existing `~/.darkbloom/cluster-device/native-device.lease` must be private,
owned, empty and unlockable. This supervisor neither creates nor clears it.

```sh
/usr/bin/python3 -B /absolute/supervisor/check_closure.py
/usr/bin/python3 -B /absolute/supervisor/run_mtp_load.py \
  --job /absolute/job.json --job-sha256 JOB_SHA256 \
  --launcher-sha256 SUPERVISOR_MANIFEST_SHA256
```

The parent first runs the exact installed binary's pure `clock` command in an
owned process bounded to at most5s. Swift `DispatchTime` supplies the absolute
native deadline; Python's clock is used only for intervals within this process.
The300s native deadline is never calculated from Python3.9 `monotonic_ns()`.
Preflight/clock time counts against the parent lifetime; the model process's
independent group watchdog receives the integer floor of the remaining315s.
Root should retain its external bound through final local evidence publication.

The exact arithmetic environment is shipped in `inputs/arithmetic.json`.
JACCL rank1, the shipped two-rank `rdma_en1` matrix, and loopback coordinator
`127.0.0.1:43198` are admission metadata only: no socket, RDMA transfer, alias,
bridge or interface change occurs. The two peer labels/build pins describe this
local load configuration; they do not attest a second installed or loaded peer.

## Required evidence

Success requires exactly `admitted` then `report`, complete EOF, exit0, reaped
native leader, owned-group fence, unchanged source/input pins, acceptable
postflight resources, and the same empty canonical journal inode after exit.
The unchanged resource gate retains every refused observation and requires at
least6GiB actual free, zero swap, pressure0...2 and AC power. Native OS DTO
arithmetic is checked separately. The250ms parent throttle is not proof of a
maximum observation gap while a system command/native operation is blocked.

The complete809-tensor target semantic receipt must equal the retained cut4
rank1 MTP-off control:3,979,190,464 selected bytes and8,192 inert bytes. Only
`selectedPayloadReadAccounting` varies operationally; its bounds are validated
before hashing the complete new target receipt for the MTP association.
All34 additive names/shapes/dtypes/bytes must match:136,881,152 head bytes plus
572,129,280 replica bytes =709,010,432 bytes, before allocator rounding. The
receipt must assert weak target/assistant/checkpoint-owner retirement and an
empty freed-buffer cache. Released active MLX bytes are retained, not assumed0.

`terminal.json`, both owned-process stream directories, `owner.json`,
`clock-owner.json`, `clock-terminal.json`, resource samples, journal pre/post
observations and the predeclared admission are retained on success or failure.
A sticky journal or unknown cleanup result fails; no automatic journal reset
is performed. Successful SIGKILL is an accepted group fence, not independent
proof that every descendant was reaped. Parent/operator errors remain failures.

## Preparation checks and limits

`checks-3/receipt.json`:9 methods passed under system Python3.9.6, using17
fabricated Python worker/clock children and3 isolated import processes. Cases
cover corrupt target/additional metadata and accounting, incorrect resource
arithmetic/cache/retirement, changed inputs, extra output, nonzero exit, expiry,
invalid clocks, live/sticky/replaced journals, and missing code/resource closure.
The first two temporary-path fixture failures remain in `checks-1`; production
path checks were unchanged. `source-equality.json` proves nine helper copies
byte-identical and five input helpers AST-identical to reviewed predecessors.

These CPU results do not establish actual selected payload loading. Even after
a physical pass, tensor values, pairwise buffer addresses, numerical parity,
history/accepted-prefix transactions, distributed MTP, provider eligibility,
performance and physical transfer remain outside this loading-only check.
Native buffer uniqueness means the checked MLX donatability/layout/bounds,
not an independently enumerated address graph. No main source is changed.
