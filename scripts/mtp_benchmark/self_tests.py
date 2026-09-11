"""CPU-only output-safety and artifact-provenance probes."""
from __future__ import annotations

import os
from pathlib import Path
import secrets
import tempfile

from .artifacts import artifact_facts, resolve_model_snapshot
from .constants import DEFAULT_ASSISTANT_ID
from .run_directory import SecureRunDirectory

def self_test_output_safety() -> int:
    requested = Path(tempfile.gettempdir()) / f"mtp-self-test-{secrets.token_hex(8)}.json"
    run = SecureRunDirectory.create(requested)
    held = run.path.with_name(run.path.name + ".held")
    outside = run.path.with_name(run.path.name + ".outside")
    try:
        outside.mkdir(mode=0o700)
        victim = outside / "victim.json"
        victim.write_bytes(b"sentinel")
        os.symlink(victim, "probe.json", dir_fd=run.directory_fd)
        run.path.rename(held)
        run.path.symlink_to(outside, target_is_directory=True)
        run.atomic_write("probe.json", b"{}\n")
        if (
            not (held / "probe.json").is_file()
            or (outside / "probe.json").exists()
            or victim.read_bytes() != b"sentinel"
        ):
            raise RuntimeError("descriptor-relative write escaped after symlink replacement")
        print("secure output symlink-replacement self-test passed")
        return 0
    finally:
        run.close()
        try:
            run.path.unlink()
        except OSError:
            # Self-test teardown is best-effort; a failed unlink must not
            # mask the assertion result above.
            pass
        for path in (held, outside):
            try:
                for child in path.iterdir():
                    child.unlink()
                path.rmdir()
            except OSError:
                # Best-effort teardown: the directory may be non-empty or
                # already gone after the checks above.
                pass


def self_test_artifact_provenance() -> int:
    with tempfile.TemporaryDirectory(prefix="mtp-artifact-self-test-") as value:
        root = Path(value)
        repository = root / "models--example--assistant"
        snapshot = repository / "snapshots" / ("a" * 40)
        blobs = repository / "blobs"
        snapshot.mkdir(parents=True)
        blobs.mkdir()
        (snapshot / "config.json").write_text('{"model_type":"gemma4_assistant"}')
        first_oid = "b" * 64
        second_oid = "c" * 64
        (blobs / first_oid).write_bytes(b"first")
        (blobs / second_oid).write_bytes(b"other")
        weight = snapshot / "model.safetensors"
        weight.symlink_to(blobs / first_oid)
        model_id, resolved = resolve_model_snapshot(
            None, snapshot, DEFAULT_ASSISTANT_ID, "assistant"
        )
        before = artifact_facts(model_id, resolved)
        if (
            model_id != "example/assistant"
            or before["weightFiles"][0]["identityKind"] != "hf_blob_sha256"
            or before["weightFiles"][0]["contentIdentity"] != first_oid
        ):
            raise RuntimeError("Hugging Face blob provenance was not captured")
        try:
            resolve_model_snapshot(
                "wrong/assistant", snapshot, DEFAULT_ASSISTANT_ID, "assistant"
            )
        except SystemExit:
            pass
        else:
            raise RuntimeError("explicit model/path mismatch was accepted")
        weight.unlink()
        weight.symlink_to(blobs / second_oid)
        if artifact_facts(model_id, resolved) == before:
            raise RuntimeError("weight symlink drift was not detected")
    print("artifact provenance symlink self-test passed")
    return 0


