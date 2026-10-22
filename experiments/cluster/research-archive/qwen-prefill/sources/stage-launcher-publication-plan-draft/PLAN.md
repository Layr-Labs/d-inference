# One public launcher on the execution Mac

2026-09-14. Source-only proposal; no implementation, model access, compiler,
process launch, SSH or candidate replay. The pending public cut12 addition was
reviewed separately and must retain its own integration/qualification status.

Use `experiments/cluster/run_stage_checks.py` as the single user entry on the Mac
that executes the model. The nearest reproducible delivery is a pinned recursive
repository checkout plus the matching inference release resources and a build
receipt. Users can build through the existing inference `build.sh`, or obtain
those exact release files together. Model weights and raw inputs remain separate,
caller-pinned local files. This needs no new host launcher or workload-plan file.

The existing public command already owns local resource admission, source and
bundle snapshots, model/input verification, fresh rank directories, the native
process groups, deadline/cancellation, output bounds and receipts. Running that
entry on the execution Mac puts those checks on the correct host. Any external
login used to reach the Mac is operational access; it is not a second supervisor
or a substitute for the local launcher’s receipt.

## Smallest publication and qualification step

1. Finish the reviewed public cut12 integration and its CPU checks. Preserve
   existing omission/default semantics. Keep cut12 serial eligibility in the
   existing registered selection descriptor, using the common stage-range
   helper and native Plan fingerprints; do not add preset benchmark plans.
2. Document one execution-Mac setup and command family in the public launcher
   README: checkout/dependency identity, build or exact release/resources,
   caller input/artifact/build pins, fresh output, and current command limits.
   The same entry exposes P2P, short ranks, v3 prefill, and registered long
   ranks/solo. Optional flags stay in their existing command scope.
3. Root qualifies that actual public entry on the execution Mac with a no-model
   P2P run, then the selected long-rank model case in a new output directory.
   Reuse the existing independent same-cut reference and CPU oracle through
   separately pinned inputs. Preserve the earlier private receipts unchanged.
   Public-entry execution and its independent numerical audit need their own
   receipts; fabricated tests and saved-output acceptance do not establish it.

Example shape after integration (placeholders denote caller-owned local paths
and independently obtained pins, not a new parser or runnable preset):

```sh
python3 REPOSITORY/experiments/cluster/run_stage_checks.py long-prefill-ranks \
  --runtime REPOSITORY/experiments/cluster/runtime --release RELEASE \
  --expected-binary-sha256 BINARY_SHA256 --output NEW_OUTPUT \
  --model-dir REGISTERED_MODEL --artifact-aggregate-sha256 ARTIFACT_SHA256 \
  --tokens-file PROMPT_JSON --tokens-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file ORIGIN_JSON --prompt-origin-sha256 ORIGIN_SHA256 \
  --stage-cut 12 --stage-prefill-policy serial_v1 --stage-logits-dtype bfloat16 \
  --parent-timeout-seconds 330
```

An initial 6 GiB actual-free screen occurs before hashing, followed by at least
8 GiB estimated reclaimable and the existing pressure/absolute-zero-swap checks.
No package should skip these checks or hash the model first in a convenience
wrapper. The actual-free screen does not promise that amount remains after
hashing. One execution Mac and loopback remain the declared transport scope.

## What must travel with the executable

`runtime/bundle.py:10–33` already defines the one immutable per-run resource
bundle: `cluster-inference`, `mlx.metallib`, the MLXLMCommon SwiftPM resource
bundle, and the pinned `rank_worker.py`/`artifacts.py`. Keep this implementation
as the only runtime bundle builder. Keep the publisher’s source/dependency,
compiler/build and source-matched metallib provenance with the release. The
caller’s executable pin plus independently captured sources is an association,
not a reproducible-build proof. `inference/build.sh:5–30` enables the existing
ring overlay, checks real backends and calls capability; use that build path.

The current public archive requires more than the native bundle:

| Current seam | Requirement and consequence |
| --- | --- |
| `stage_checks/archive.py:44–59` | Exact checkout-relative runtime location, Swift sources, package/build files and dependency manifests. A copied Python directory alone fails. |
| `archive.py:26–41,76–78,113–120` | Live Git repository/submodule identity is captured and checked again. A source tarball without Git metadata is not currently interchangeable. |
| `archive.py:82–110,125–128` | Launcher source and its copy are pinned; bundle/artifact/configuration/process modules load from the per-run source snapshot. Live launcher files are also rechecked. |
| `runtime/processes.py:57–93`, `rank_worker.py:24–89` | Existing local owner start, cancel and process-group cleanup remain reusable. No SSH adapter is needed for local execution. |

## If a standalone download becomes necessary

Make one additive package-source adapter at `archive_sources`/`verify_archive`,
selected by an explicit pinned package manifest; leave native argument building,
model/input admission, resources, records and supervision unchanged. The package
would contain the same release resources, public Python runtime/entry, exact
source snapshot and recorded build/dependency identity. Verify an externally
supplied package pin, closed regular-file inventory, safe relative paths and
all file hashes before imports or execution; recheck package and per-run copies
afterward. A manifest inside the same unpinned download is not an independent
trust anchor. The receipt must distinguish recorded build-source identity from
live execution-host Git identity; never manufacture a Git checkout or silently
weaken the current source guard. Relocation and fail-closed missing/changed
resource tests would qualify that seam before an execution-Mac run.

This adapter is optional later work, not needed for the first public execution.
Do not ship another private remote wrapper, configuration scheduler, or separate
cut12 benchmark script as a prerequisite. Independent numerical/action/timing
and sidecar audits remain separate qualification tools. The existing public
phase option requests local sidecars but does not verify them; selected-owner
forwarding/collection should be integrated explicitly if later desired, not
implied by this packaging proposal. No hardware throughput, physical link,
cross-process clock alignment, or target-Mac performance claim follows.
