#!/usr/bin/env python3
"""Source-only preservation checks for the four existing-file deltas."""
import hashlib
import json
import pathlib
import re


root = pathlib.Path(__file__).resolve().parent
proposed = root / "proposed"


def text(name):
    values = list(proposed.rglob(name))
    assert len(values) == 1
    return values[0].read_text()


codec = (root / "originals/ClusterWorkerCodec.swift").read_text()
head, body = codec.split("private struct WorkerObject", 1)
assert text("ClusterWorkerCodec.swift") == head
reader = text("ClusterWorkerObject.swift").split("struct WorkerObject", 1)[1]
reader = re.sub(r'    mutating func bool\(_ key: String\) throws -> Bool \{.*?\n    \}\n', '', reader, count=1, flags=re.S)
assert body == reader
construction = (root / "originals/QwenModelConstruction.swift").read_text()
head, body = construction.split("func sha256", 1)
assert text("QwenModelConstruction.swift") == head.replace("import CryptoKit\n", "", 1)
assert text("ClusterMetadataHashing.swift").split("func sha256", 1)[1] == body
admission = text("QwenResidentAdmission.swift")
admission = admission.replace("static let profileID = QwenResidentAdapterDefinition.profileID", 'static let profileID = "registered_qwen35_9b_greedy_generation_v1"')
admission = admission.replace("static let maximumLifetimeNanoseconds = QwenResidentAdapterDefinition.maximumLifetimeNanoseconds", "static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000")
admission = admission.replace("static let maximumRequests = QwenResidentAdapterDefinition.maximumRequests", "static let maximumRequests = 16")
admission = admission.replace("QwenResidentAdapterDefinition.supportedCuts.contains", "[4, 8, 12, 16].contains")
original_profile = '''profile = try .init(identifier: Self.profileID, vocabularySize: 248_320,
            hiddenSize: spec.hidden, activationDType: "bfloat16", maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)'''
admission = admission.replace("profile = try QwenResidentAdapterDefinition.profile(specification: spec)", original_profile)
assert admission == (root / "originals/QwenResidentAdmission.swift").read_text()
definition = text("QwenResidentAdapterDefinition.swift")
for literal in ['"registered_qwen35_9b_greedy_generation_v1"', "300_000_000_000", "maximumRequests = 16", "supportedCuts = [4, 8, 12, 16]"]:
    assert literal in definition
profile_body = original_profile.replace("profile = try", "return try").replace("Self.profileID", "profileID").replace("spec.hidden", "specification.hidden")
assert profile_body in definition
main = text("WorkerMain.swift")
addition = '''            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--describe-runtime" {
                try WorkerCapabilityCommand.run(arguments: arguments)
                Darwin.exit(0)
            }
'''
assert addition in main
main = main.replace(addition, "", 1).replace("WorkerConfiguration(arguments: arguments, now: now)", "WorkerConfiguration(arguments: Array(CommandLine.arguments.dropFirst()), now: now)")
assert main == (root / "originals/WorkerMain.swift").read_text()
print(json.dumps({"passed": True, "original_codec_body_unchanged": True,
    "original_object_methods_unchanged": True, "original_model_construction_body_unchanged": True,
    "sha256_body_unchanged": True, "admission_only_shared_definition_substitutions": True,
    "default_worker_path_unchanged": True, "files": {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(proposed.rglob("*.swift"))}}, sort_keys=True))
