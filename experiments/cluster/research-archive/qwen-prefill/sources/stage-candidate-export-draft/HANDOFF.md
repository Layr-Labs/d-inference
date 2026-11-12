# Candidate export handoff

2026-09-14. Source-only out-of-tree prototype. No Swift compiler, runner, model,
native process or SSH was used by the author. Root owns compilation and execution.

The proposal adds eleven files under `experiments/cluster/inference`: six tool Swift
files, a tool runner/README, and a fixture/check entry/runner. It changes no native
runtime source or `Main` mode. `source-list.json` supplies exact ordered tool and
fixture inputs and the unchanged shared retained metadata. Tool compilation uses
twelve files; fixture compilation uses fourteen. Prospective counts are 23 accepted
and 39 rejected checks, not executed results.

To test the out-of-tree fixture against current production dependencies:

```sh
bash proposed/experiments/cluster/inference/Tests/LayerStageCandidateExport/run.sh \
  /path/to/d-inference/experiments/cluster/inference/Sources/ClusterInference
```

For the out-of-tree CLI, set `CLUSTER_INFERENCE_SOURCE_DIR` to that same source
directory, then call the proposed tool's `run.sh` with its four required path/hash
pairs. The public defaults and shared fixture references are relative; there are
no private host/path literals in proposed files and no duplicated metadata.

`CandidateExportJSON.swift` validates generic JSON numeric tokens and substitutes
zero only in a temporary scanning buffer. Existing `validateWorkerJSON` then owns
duplicate-key, depth, string and structural validation. Original configuration
bytes and native Plan numeric/model rules are unchanged. This addresses ordinary
configuration floats without relaxing the integer-only wire scanner.

The exporter-owned input reader uses no-follow/nonblocking descriptors and rejects
nonregular files before reading. It checks a positive capped size and stable
device/inode/mode/size/mtime/ctime around the snapshot. Actual temporary regular,
symlink, FIFO, oversized, empty and directory cases exercise it; a CLI case proves
that a captured snapshot still must match its raw pin. Shared input code is unchanged.

Raw config/name pins are checked before parsing. Names are limited to 2 MiB,
8,192 unique strings and 512 bytes each; config to 1 MiB. Output contains complete
ownership and is limited to 32 MiB including newline before its single write.
The output cap is not a process-memory promise. Artifact/checkpoint identity is
deliberately absent because this tool reads no verified checkpoint or descriptors.

The native enumerator is the only cut/metadata/name-mapping authority. The new
JSON encoding only serializes an export DTO and the sorted name set; native
Plan/stage/config fingerprints are copied or hashed from their actual native
bytes. The exporter does not reconstruct their identity recipes.

Tests use the existing retained 9B/27B configuration/name metadata and all three
public synthetic wrapper forms. They check complete inverse parameter ownership,
state coverage, unaligned final end, deterministic bytes, name-order versus raw
identity, raw config formatting affecting native Plan identity, explicit excluded
components, input caps/pins, duplicate escaped keys, float grammar/depth, native
refusals and publication bounds. They test neither tensor descriptors nor payloads.

See `JOIN.md` for the measurement adapter seam. Catalog metadata candidates must
not be relabeled as registered loader/request eligibility; in particular the
existing registered 27B planning role remains closed to its admitted default split.
