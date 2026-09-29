"""Synthetic raw files for verifier tests only; never release evidence/catalog data."""
import atexit
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from .matrix import CHECKS
from .qualification_build import encode_build_record
from .test_qualification_build import fixture_build_record

_TEMP = tempfile.TemporaryDirectory(prefix="qualification-check-fixtures-")
atexit.register(_TEMP.cleanup)
ROOT = Path(_TEMP.name)


def build():
    return {"configuration": "release", "dirty": False, "debug_condition": False,
            "debug_assertions_enabled": False, "build_identity_version": 1,
            "source_commit": "a" * 40, "sdk_commit": "b" * 40,
            "source_tree_sha256": "c" * 64, "test_binary_sha256": "d" * 64,
            "metallib_sha256": "e" * 64}


def write(path, value):
    data = json.dumps(value, sort_keys=True).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def references(identity, candidate_build, root=ROOT):
    prefix = uuid.uuid4().hex
    log_path = f"{prefix}/sdk-test.log"
    log = ('Executed 3 tests, with 0 failures (0 unexpected) in 1.0 seconds.\n'
           '✔ Test "finished request id reuse rebuilds fresh constraint state" passed after 0.01 seconds.\n'
           '✔ Test "auxiliary accounting includes hidden/token history and isolates requests" passed after 0.01 seconds.\n'
           '✔ Suite "CBv2 row-local token constraints" passed after 0.1 seconds.\n'
           '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.\n').encode()
    (root / log_path).parent.mkdir(parents=True, exist_ok=True)
    (root / log_path).write_bytes(log)
    raw_sdk = {"schema_version": 1, "kind": "deterministic_regression",
               "scopes": ["constraints", "isolation"], "sdk_commit": candidate_build["sdk_commit"],
               "exit_code": 0, "xctest_passed": 3, "swift_testing_passed": 2, "log_path": log_path, "log_sha256": hashlib.sha256(log).hexdigest()}
    runtime = {key: identity[key] for key in ("configured_context_tokens", "effective_max_concurrency",
        "prefill_chunk_size", "max_concurrent_partial_prefills", "solo_prefill_stripe_tokens", "mixed_prefill_token_cap") if key in identity}
    runtime.setdefault("configured_context_tokens", identity.get("context_tokens_max"))
    raw_live = {"kind": "serving_lifecycle", "schemaVersion": 1,
                "modelID": identity["model_id"], "artifactSHA256": identity["artifact_sha256"],
                "providerVersion": identity["provider_version"], "runtimeRevision": identity["runtime_revision"],
                "actualKVBackend": identity["kv_backend"], "mtp": identity.get("mtp"), "runtime": runtime,
                "buildIdentity": {"version": 1, "debugCompilationCondition": False,
                    "debugAssertionsEnabled": False, "binarySHA256": candidate_build["test_binary_sha256"]},
                "passed": True, "checks": [{"phase": phase, "reached": True, "cancelled": True,
                    "engineFinishReason": "cancelled",
                    "retired": True, "followupParity": True, "serviceFractionAtCancel": 1 / 24,
                    "confirmedTokens": 2, "generatedTokensAccounted": 2, "generationRetirements": 1}
                    for phase in ("prefill", "after_mtp_content" if identity.get("mtp") else "after_content")]}
    provenance = {"source": {"head": candidate_build["source_commit"], "dependency_head": candidate_build["sdk_commit"],
                      "source_tree_sha256": candidate_build["source_tree_sha256"], "dirty": False},
                  "return_code": 0, "build_configuration": "release", "artifact_unchanged": True,
                  "source_unchanged": True, "binary_unchanged": True,
                  "power_posture_before": {"source": "ac", "mode": "automatic", "raw_mode": 0},
                  "power_posture_after": {"source": "ac", "mode": "automatic", "raw_mode": 0},
                  "test_binaries_sha256": {"fixture.xctest": candidate_build["test_binary_sha256"]},
                  "metallibs_sha256": {"mlx.metallib": candidate_build["metallib_sha256"]}}
    provenance["build_record"] = fixture_build_record(provenance["source"], "release",
        provenance["test_binaries_sha256"], provenance["metallibs_sha256"])
    provenance["build_record_sha256"] = hashlib.sha256(encode_build_record(provenance["build_record"])).hexdigest()
    sdk_path, live_path, source_path = (f"{prefix}/{name}.json" for name in ("sdk", "lifecycle", "provenance"))
    sdk_hash = write(root / sdk_path, raw_sdk)
    live_hash = write(root / live_path, raw_live)
    source_hash = write(root / source_path, provenance)
    return {check: ({"receipt_path": sdk_path, "receipt_sha256": sdk_hash} if check in ("constraints", "isolation")
                   else {"receipt_path": live_path, "receipt_sha256": live_hash,
                         "provenance_path": source_path, "provenance_sha256": source_hash}) for check in CHECKS}
