# Short execution evidence binding

This private CPU tool joins a completed registered dense-Qwen short-parity run
with the original native output, a fresh replay of the frozen numerical oracle,
and explicitly supplied retained source and bundle bytes. It supports the
registered Qwen3.5 9B and Qwen3.8 27B short profiles. It neither launches native
code nor grants permission to execute a model.

The immediate purpose is to record the existing actual-device Metal arithmetic
profile before trying the registered 27B artifact on additional hardware. No
new operator, artifact rewrite, native runtime DTO or c079 rebuild is involved.
The development checks use fabricated native records and payloads. No actual
c079 short-parity result or M3 Ultra result has been checked yet.

## Run

Use Python 3.9 or newer and a new output file in an existing private directory:

```sh
python3 -B audit_short_execution_binding.py packet.json --output binding.json
```

The command exits zero on a successful consistency check, or one with a failed
receipt when an input/check fails. An existing output is never overwritten.
Receipts are written with mode 0600. The output may contain historical private
paths and must remain outside the public repository.

The packet has exactly these keys:

```json
{
  "schema": "private_short_execution_binding_packet_v1",
  "profile": "registered_qwen35_9b",
  "files": {
    "stdout": {"path": "stdout.jsonl", "sha256": "RAW_SHA256"},
    "stderr": {"path": "stderr.log", "sha256": "RAW_SHA256"},
    "prompt": {"path": "prompt.json", "sha256": "RAW_SHA256"},
    "teacher": {"path": "teacher.json", "sha256": "RAW_SHA256"},
    "parent": {"path": "receipt.json", "sha256": "RAW_SHA256"},
    "numerical": {"path": "numerical-audit.json", "sha256": "RAW_SHA256"},
    "source_manifest": {"path": "source-manifest.json", "sha256": "RAW_SHA256"},
    "bundle_manifest": {"path": "retained-bundle/bundle.json", "sha256": "RAW_SHA256"},
    "retained_metadata": {"path": "retained-inputs.json", "sha256": "RAW_SHA256"}
  },
  "source_files": [{"member": "MANIFEST_RELATIVE_PATH", "path": "RETAINED_FILE"}],
  "bundle_files": [{"member": "MANIFEST_RELATIVE_PATH", "path": "RETAINED_FILE"}],
  "private_files": [{"member": "PARENT_MODULE_NAME", "path": "RETAINED_FILE"}]
}
```

Replace every placeholder. Each member list must cover exactly its manifest;
the private list covers the six files in `binding_pins.PRIVATE_SOURCES`.
Paths refer to current supplied files, either absolute or relative to the
packet. Preserve the original bytes of all JSON, JSONL, tokens and manifests.
Use a retained bundle location explicitly; a historical parent path is a label
and is never followed. The parent and numerical receipts must describe the same
complete native output. Both supported profiles use three prompt tokens and
one teacher token; this is a correctness workload, not a TPS benchmark.

## What a pass means

The checker validates the frozen completed-parent schema, raw input pins,
native PID and executable/bundle path consistency, both native runtime DTOs,
registered metadata and the recorded arithmetic environment. It replays the
recorded resource/power policy statements and independently reruns the frozen
numerical checker on the original stdout bytes. The full saved numerical result
must equal that fresh result. Explicit retained source, bundle, executable,
Metal library and private-parent members are hashed and checked against their
manifests. All supplied files are rechecked before return.

`recordedRuntimeProfileSHA256` identifies the recorded artifact/plan/arithmetic,
runtime architecture/OS/limits and semantic source/bundle identities. Request
tokens, PID, historical paths and raw manifest formatting are excluded from
that reusable profile identity. `executionEvidenceSHA256` separately binds the
packet, original file bytes, request identities, PID, runtime observations and
frozen checker sources. Neither hash is a signature or device attestation.

A pass establishes consistency of the supplied evidence. It does not establish
that the historical process ran, that a source tree produced an executable, or
which Metal library/kernels that process loaded. Raw OS reports, entire process
environment, source-tree completeness, directory ownership and whole-process
memory peaks are not independently proved. NAX availability remains unknown;
the registered production M5/NAX eligibility rule is not changed. Hardware,
two-machine execution, numerical behavior on an untested device, 8K admission,
provider eligibility and throughput remain unqualified.

## Implementation and validation

The entry point only orchestrates bounded input snapshots, manifest/parent joins,
runtime validation, numerical replay and result publication. The four numerical
modules under `oracle/` are byte-identical to the frozen independent checker.
Their pinned captured bytes execute in isolated owned copies; candidate source
archives and parent launchers are never imported or run. This is an ordinary
local Python process, not a sandbox against a hostile same-user process.

Run the CPU regressions with:

```sh
python3 -B -m unittest -v test_binding_pipeline test_runtime_binding \
  test_binding_inputs test_binding_oracle
```

Composite fixtures cover both models, fresh and reused bundles, changed
artifacts/results/runtime identity, stale numerical receipts, source-impossible
parent observations and publication behavior. Their model outputs, runtime
identity, resource observations and executable/Metal payloads are fabricated.
The tests must never be reported as model execution or target-hardware evidence.
