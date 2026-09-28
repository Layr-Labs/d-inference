# Recorded Qwen prefill services

> Last updated: 2026-09-14 · commit `e4df336bc`

This CPU adapter extracts per-chunk stage services from saved registered Qwen
9B rank reports and phase traces. It joins them to native candidate metadata or
creates an explicitly assumed two-device cost profile. It performs no model
load, SSH, network configuration or execution admission.

## Extract recorded services

From the repository root with Python 3.9 or newer:

```sh
PYTHONPATH=experiments/cluster python3 -B -m planning.measurements /path/to/packet.json
python3 -B -m unittest discover -s experiments/cluster -p 'test_planning*.py'
```

The packet is a closed JSON object with these fields:

| Field | Value |
|---|---|
| `schema` | `cluster_qwen_prefill_measurement_packet_v1` |
| `stage_cut` | `null` for the recorded default, or the separately admitted selected cut |
| `files` | Exactly `prompt`, `rank0_stdout`, `rank1_stdout`, `rank0_trace`, `rank1_trace`; each is an object containing `path` and lower-case raw `sha256` |
| `provenance` | Exactly `native_sha256`, `runtime_source_sha256`, `numerical_audit_sha256`, `runtime_audit_sha256` and `devices` |
| `provenance.devices` | Two objects, each containing a compact `id` and `hardware_sha256`; this loopback adapter requires the same declared device for both ranks |

Relative paths resolve against the packet directory. Keep packets and results
outside the repository: caller-supplied device labels can be private. Output
retains file hashes and byte counts, without file paths or raw prompt token IDs.
The packet and prompt are each capped at 64 KiB, each stdout at 16 MiB and each
phase trace at 512 KiB. Inputs must be distinct nonempty regular files. The
reader rejects symlinks, duplicate inodes, changed snapshots and wrong byte
pins; stdout must contain exactly two LF-terminated JSON records. JSON parsing
rejects duplicate fields and non-finite values.

[packet.py](packet.py) reuses the public
[rank contract](../../runtime/stage_checks/long_rank_contract.py) and
[selected-cut admission](../../runtime/stage_checks/long_stage_cut.py). The
current workload is batch-one, uncached, 8,192 prompt tokens in 512-token chunks.
Default plans admit serial and one-chunk lookahead observations; selected-cut
admission retains its existing restrictions. This adapter does not broaden them.

[qwen_rank_phase.py](qwen_rank_phase.py) checks source-derived action order,
chunk/context frontiers, trace identities, closed timing fields and local clock
arithmetic. Producer service spans preparation through its committed boundary;
consumer service spans consumption through validation, with vocabulary projection
and first-token selection included in the last frame. Each rank keeps its own
clock origin. Adjacent serial producer pre-header spans remain separately named
local observations. None of these waits becomes a Thunderbolt measurement.

The `cluster_prefill_services_v1` result records exact artifact, configuration,
plan, stage, storage, arithmetic and prompt identities. Optional reported active
tensor inventories are reduced to source/local name mappings and opaque loader
hashes. An absent or null inventory means missing evidence; an empty or duplicate
inventory is rejected. Shapes, dtypes, hash recipes and tensor values are outside
this mapping check.

Raw input pins and local phase arithmetic are replayed. Hardware identity,
numerical/runtime audit references and native provenance remain caller assertions;
their verification flags remain false. Use the separate loader, numerical and
runtime audits to establish those claims. Coherently invented reports cannot
prove that native execution occurred.

## Associate native candidates

First use the [Foundation exporter](../../inference/Tools/LayerStageCandidates/README.md)
with exact configuration bytes and already canonical parameter names. Then:

```sh
PYTHONPATH=experiments/cluster python3 -B -m planning.measurements /path/to/packet.json \
  --catalog /path/to/native-catalog.json --catalog-sha256 CATALOG_RAW_SHA256
```

The catalog is bounded at 32 MiB, pinned before parsing and checked again after
extraction. [catalog.py](../catalog.py) checks its closed DTO and internal range,
count, state-index and name-coverage consistency. It neither enumerates legal
cuts nor recomputes native fingerprints. Exported name/configuration hashes are
metadata assertions; a raw file pin does not authenticate an exporter.

[candidates.py](../candidates.py) requires exact source configuration, Plan,
ordered stage and construction-configuration identities. Every present reported
parameter inventory must match its native source/local mappings. Missing peer
ownership withholds a complete match; contradictory evidence fails even if the
other stage is missing. Only the matching candidate can receive
`observed_metadata_match`. Other cuts remain `unmeasured`, with no inherited
costs. A metadata match establishes neither checkpoint contents nor eligibility.

The association identifies the services by their semantic SHA-256 and preserves
the catalog's raw and semantic hashes separately. It emits no throughput ranking.
Actual retained 9B runs at 16/16 and 12/20 matched all 927 active mappings against
the native catalog; the 15 exported 27B candidates have no service observations.

## Model an explicit assumption

```sh
PYTHONPATH=experiments/cluster python3 -B -m planning.measurements /path/to/packet.json \
  --assume-independent-devices hypothetical-a hypothetical-b \
  --policy prompt_lookahead_one_v1
```

This output uses the [offline cost schema](../README.md). One observed service
duration supplies each low/typical/high compute entry; copying that duration to
independent devices is an assumption, not a measured range or concurrency proof.
All transport, startup, completion, returned-token and target memory quantities
remain null. The planner can show a zero-overhead compute scenario, but cannot
rank it or produce a complete TTFT estimate until the missing costs and memory
data are supplied. Catalog association and assumed projection are separate CLI
outputs. Neither mode supplies M3 Ultra or 27B throughput evidence.
