This private comparator checks the registered Gemma cut10 P32/C16/O2 numerical result. No fixture, model, compiler, remote operation, or actual candidate/reference read has been performed while preparing it. It does not change any Qwen validator or native source.

`recorded_math.py` and `snapshot.py` are byte-identical copies from the frozen registered-generation numerical audit. The new files bind the Gemma report schema, explicit prospective identity, actual attention layout, and chronological state snapshots. `source-lineage.json` pins the native DTO/assembly/fingerprint sources used.

Before any native execution, retain the exact `GemmaShortCorrectnessCheck --describe JOB` output and its SHA256, and the exact 32-token prompt file and SHA256. The expected description is metadata-only. Its plan/stage/mapping and three parameter-layout identities must come from the parent-reviewed metadata constructor. The comparator rederives its profile, request, token, and scope hashes, but does not reconstruct a model or rehash the 15 GB artifact. Full and staged jobs must use the same expected description, membership epoch, build identity, request UUID, residual dtype, and prompt. The description includes all three targets so the modes themselves do not change it.

After all three complete reports and their sidecars have been collected and hash-bound, make one JSON packet with exactly these fields:

```json
{
  "schema": "gemma4_short_comparison_packet_v1",
  "expected": {"path": "/absolute/expected.json", "sha256": "EXPECTED_SHA256"},
  "prompt": {"path": "/absolute/prompt.ids.json", "sha256": "PROMPT_SHA256"},
  "results": {
    "full": {"report": {"path": "/absolute/full.stdout", "sha256": "FULL_SHA256"}, "sidecarsDirectory": "/absolute/full-sidecars"},
    "stage0": {"report": {"path": "/absolute/stage0.stdout", "sha256": "STAGE0_SHA256"}, "sidecarsDirectory": "/absolute/stage0-sidecars"},
    "stage1": {"report": {"path": "/absolute/stage1.stdout", "sha256": "STAGE1_SHA256"}, "sidecarsDirectory": "/absolute/stage1-sidecars"}
  }
}
```

Each sidecar directory contains only that native execution's declared sidecars, not stdout or supervisor files. The reports and packet are separately hash-pinned. No path is executed. The expected description and full report are validated before staged report paths are opened. A failed comparison writes no successful output. A successful output is create-only.

Root-only prospective commands, from this directory:

```sh
/usr/bin/python3 -B Tests/test_compare.py
/usr/bin/python3 -B compare.py --packet /absolute/packet.json --packet-sha256 PACKET_SHA256 --output /absolute/new-comparison.json
```

Run the 18 fabricated CPU tests through the existing root-owned process runner with a 120-second bound before actual numerical qualification. No compiler/native/GPU is required. Tests use temporary ordinary files and exact full vocabulary/short state dimensions. They are deliberately not physical execution evidence. The fixtures' selected-byte/resource metadata are fabricated, even though their fixed profile and artifact identifiers are the actual closed schema.

The comparison requires two exact 262,144-element rows and first-maximum/tie agreement; both accepted IDs; all three peer boundary hashes; and the exact disjoint union of 30/60 state entries matching all 90 full-reference entries. Full attention is global layers 5/11/17/23/29 with two heads of dimension 512. Other layers have eight heads of dimension 256 and 1024-slot windows. All logical snapshots end at frontier 33, with actual position-offset bytes `[33]`, and capacity 34. Actual native dtype and each logical byte must match; there is no tolerance or widening fallback. Layout/snapshot fingerprints are reconstructed separately for each ownership interval.

Resource receipt identity, completion, named sums, F32 state ceiling, host-evidence reserve, and conservative flags are checked for internal consistency. Actual allocator per-leaf bounds, whole process resource behavior, model/build integrity, native exit/EOF/reaping, process absence, and canonical journal/owner retirement remain independent parent requirements. The success result explicitly leaves those physical claims false. It also leaves serving, throughput, and encrypted RDMA claims false. The selected parameter counts do not sum to the full count because stage selections include their own required shared leaves; the explicit metadata layouts remain authoritative.

File bounds preserve the native 1 MiB final report plus optional stdout LF, 16 MiB per sidecar, 32 MiB and 128 sidecars per execution, and 256 KiB for the comparison output. The comparator only holds CPU copies. It performs no cross-host clock calculations and does not interpret durations as throughput.
