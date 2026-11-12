#!/usr/bin/env python3
"""Small inverse-delta and unchanged-gate check; no Swift execution."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / "proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
for name, addition in [
    ("QwenResidentSource.swift", "    let resources = try QwenDenseRegisteredResourceProfile(specification: admission.specification)\n"),
    ("QwenResidentAdmission.swift", "        let resources = try QwenDenseRegisteredResourceProfile(specification: spec)\n"),
    ("QwenResidentRequestResources.swift", "        let resources = try QwenDenseRegisteredResourceProfile(profile: profile)\n"),
]:
    text = (RUNTIME / name).read_text()
    assert text.count(addition) == 1
    restored = text.replace(addition, "")
    if name == "QwenResidentSource.swift":
        assert restored.count("resources.maximumManifestPayloadBytes") == 1
        restored = restored.replace("resources.maximumManifestPayloadBytes", "LocalCorrectnessStorage.maximumManifestPayloadBytes")
    else:
        assert restored.count("resources.namedTensorByteCeiling") == 1
        restored = restored.replace("resources.namedTensorByteCeiling", "QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling")
    assert restored.encode() == (ROOT / "originals" / name).read_bytes(), name

pins = json.loads((ROOT / "compatibility-pins.json").read_text())
for item in pins["members"]:
    data = (ROOT / "compatibility" / item["path"]).read_bytes()
    assert len(data) == item["bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"]
    assert not (ROOT / "proposed" / item["path"]).exists()

new = (RUNTIME / "QwenDenseRegisteredResourceProfile.swift").read_text()
assert "maximumManifestPayloadBytes = 8 * 1024 * 1024 * 1024" in new
assert "namedTensorByteCeiling = QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling" in new
assert "runtimeExecutionAuthorized = false" in new
assert "actualPayloadVerificationEstablished = false" in new
assert "model == .qwen35NineB || cut == 32" in (ROOT / "baseline/QwenRegisteredDenseModelProfile.swift").read_text()
assert "identity.modelID == QwenRegisteredDenseModel.qwen35NineB.rawValue" in (RUNTIME / "QwenResidentAdmission.swift").read_text()
assert "profile.model == .qwen35NineB" in (RUNTIME / "QwenResidentRequestResources.swift").read_text()
assert "guard profile.model == .qwen35NineB" in (RUNTIME / "QwenResidentSource.swift").read_text()
print(json.dumps({"inverseRuntimeDeltas": 3, "unchangedCompatibilityFiles": len(pins["members"]),
                  "oldPlanningAndExecutionGatesPreserved": True, "swiftExecuted": False}, sort_keys=True))
