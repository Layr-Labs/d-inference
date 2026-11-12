#!/usr/bin/env python3
"""Prepare reviewed source copies/patches only; never modify repository inputs."""
from pathlib import Path
import difflib
import hashlib
import json

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
REPO = RESEARCH.parent / "d-inference"
RELATIVE = "experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageMetadata.swift"
SOURCE = REPO / RELATIVE
FROZEN_FIXTURE = RESEARCH / "layer-stage-candidate-plan-draft/QwenLayerStageCandidatesCheck.swift"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    original = SOURCE.read_bytes()
    text = original.decode()
    old_key = '"layer_types", "mlp_only_layers", "hidden_act", "attn_output_gate", "attention_dropout",'
    new_key = old_key + '\n            "output_gate_type",'
    marker = '        func boolean(_ value: Any?, expected: Bool) -> Bool {'
    addition = '''        // The current Qwen35 decoder ignores this optional key; its GDN
        // RMSNorm gate already applies SiLU. Admit only compatible declarations.
        // Validate without normalizing/removing the original source spelling.
        // This selects no new operator and grants no execution capability.
        if let outputGate = text["output_gate_type"] {
            guard let value = outputGate as? String, ["swish", "silu"].contains(value) else {
                throw ProbeError("Unsupported GDN output gate; layer stages require swish or silu")
            }
        }
'''
    assert text.count(old_key) == 1 and text.count(marker) == 1
    assert '"output_gate_type"' not in text
    proposed = text.replace(old_key, new_key, 1).replace(marker, addition + marker, 1)
    assert proposed.replace(new_key, old_key, 1).replace(addition, "", 1) == text
    (HERE / "original-QwenLayerStageMetadata.swift").write_bytes(original)
    (HERE / "QwenLayerStageMetadata.swift").write_text(proposed)
    patch = "".join(difflib.unified_diff(text.splitlines(keepends=True), proposed.splitlines(keepends=True),
        fromfile="a/" + RELATIVE, tofile="b/" + RELATIVE))
    (HERE / "metadata.patch").write_text(patch)
    fixture_bytes = FROZEN_FIXTURE.read_bytes()
    fixture = fixture_bytes.decode()
    old = 'text["output_gate_type"] = "swish"; root["text_config"] = text'
    new = 'text["output_gate_type"] = "sigmoid"; root["text_config"] = text'
    assert fixture.count(old) == 1
    changed_fixture = fixture.replace(old, new, 1)
    (HERE / "QwenLayerStageCandidatesCheck.swift").write_text(changed_fixture)
    (HERE / "candidate-fixture.patch").write_text("".join(difflib.unified_diff(
        fixture.splitlines(keepends=True), changed_fixture.splitlines(keepends=True),
        fromfile="a/QwenLayerStageCandidatesCheck.swift", tofile="b/QwenLayerStageCandidatesCheck.swift")))
    assert SOURCE.read_bytes() == original and FROZEN_FIXTURE.read_bytes() == fixture_bytes
    receipt = {"schemaVersion": 1, "status": "passed", "scope": "Exact source patch preparation only",
        "originalMetadata": {"path": str(SOURCE), "byteCount": len(original), "sha256": sha(original)},
        "frozenOriginalCandidateFixture": {"path": str(FROZEN_FIXTURE), "byteCount": len(fixture_bytes), "sha256": sha(fixture_bytes)},
        "proposedMetadataSHA256": sha(proposed.encode()), "metadataPatchSHA256": sha(patch.encode()),
        "changesOutsideKnownKeyAndLocalGuard": False,
        "repositoryAndFrozenInputBytesUnchanged": True, "swiftCompiledOrExecuted": False,
        "modelLibraryProviderOrRuntimeGateChanged": False}
    (HERE / "source-preparation-receipt.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": "passed", "metadataPatchSHA256": receipt["metadataPatchSHA256"],
        "proposedMetadataSHA256": receipt["proposedMetadataSHA256"], "repositoryModified": False}, sort_keys=True))


if __name__ == "__main__":
    main()
