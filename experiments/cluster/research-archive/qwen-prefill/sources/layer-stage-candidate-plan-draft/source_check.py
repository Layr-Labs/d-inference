#!/usr/bin/env python3
"""CPU source checks and retained-metadata preview; does not execute Swift."""
from pathlib import Path
import hashlib
import json
import math
import re

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
REPO = RESEARCH.parent / "d-inference"
SOURCES = REPO / "experiments/cluster/inference/Sources/ClusterInference"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def pin(path):
    data = path.read_bytes()
    return {"path": str(path), "byteCount": len(data), "sha256": digest(data)}


def validate_core(text):
    checks = {
        "foundation_only": re.findall(r"^import (\w+)$", text, re.M) == ["Foundation"],
        "no_native_file_environment_or_clock_calls": not any(s in text for s in [
            "ProcessInfo", "DispatchTime", "MLXArray", "loadModel(", "Data(contentsOf:",
            "FileManager", "FileHandle", "Process(", "Thread(", "eval(", "synchronize("]),
        "bounded_structural_inputs": "(1...128).contains(layerCount)" in text
            and "(2...128).contains(fullAttentionInterval)" in text,
        "both_stages_at_least_one_interval": "let lastCut = layerCount - fullAttentionInterval" in text
            and "guard lastCut >= fullAttentionInterval else { return [] }" in text,
        "ascending_aligned_cuts": "stride(from: fullAttentionInterval, through: lastCut, by: fullAttentionInterval)" in text,
        "no_end_alignment_or_halving": "layerCount %" not in text and "layers / 2" not in text,
        "bounded_full_configuration": "configuration.count <= 1_048_576" in text,
        "inactive_mtp_required": "guard !activeMTP," in text,
        "empty_candidate_set_rejects_full_admission": "guard !cuts.isEmpty else" in text,
        "exact_existing_plan_per_cut": "let plan = try QwenLayerStagePlan(configuration: configuration," in text
            and "ranges: [0..<cut, cut..<layers], activeMTP: activeMTP)" in text,
        "exact_existing_canonical_name_validation": "let parameters = try plan.parameters(canonicalSourceNames: canonicalSourceNames)" in text,
        "never_skip_invalid_candidates": "return try cuts.map { cut in" in text
            and "try?" not in text and "catch" not in text and "compactMap" not in text,
        "reuse_existing_layer_map": "let state = try stage.layers.map { layer -> StateOwnership in" in text
            and "StateOwnership(layer: layer, components: components)" in text,
        "state_kinds_closed": 'case "linear_attention": components = [.convolution, .ssm]' in text
            and 'case "full_attention": components = [.keys, .values, .offsets]' in text
            and 'default: throw ProbeError("Candidate state ownership has an unsupported layer kind")' in text,
        "known_exclusions_from_validated_mappings": "canonicalSourceNames.filter { !retainedNames.contains($0) }.sorted()" in text,
        "costs_explicitly_unknown": "enum ComputeCostStatus: String { case unknown }" in text
            and text.count("let computeCostStatus = ComputeCostStatus.unknown") == 2,
    }
    failed = [name for name, value in checks.items() if not value]
    if failed:
        raise ValueError("Source invariants differ: " + ", ".join(failed))
    return list(checks)


def structural_cuts(layers, interval):
    # Independent predicate over all interior integers, not the Swift stride.
    return [cut for cut in range(1, layers)
            if cut >= interval and layers - cut >= interval and cut % interval == 0]


def metadata_preview():
    config_paths = [RESEARCH.parent / "models/Qwen3.5-9B/config.json",
                    RESEARCH.parent / "models/Qwen3.8-27B/config.json"]
    inventory_path = RESEARCH / "local-registered-model-inventory-20260913.json"
    expected_path = RESEARCH / "qwen-layer-stage-real9b-expected-20260913.json"
    paths = [*config_paths, inventory_path, expected_path,
             SOURCES / "QwenLayerStagePlan.swift", SOURCES / "QwenLayerStageMetadata.swift",
             SOURCES / "QwenLayerStagePlanCheck.swift", SOURCES / "QwenLayerStageRecordedEvidence.swift",
             SOURCES / "QwenLayerStageComparisonAdmission.swift", SOURCES / "QwenLongPrefillReferenceAdmission.swift",
             SOURCES / "PreparedQwenLayerSource.swift", SOURCES / "QwenLayerStageProfiledComputeAdmission.swift",
             SOURCES / "QwenLayerStageProfiledStateDigest.swift", SOURCES / "QwenRegistered9BLongPrefillAdmission.swift"]
    before = [pin(p) for p in paths]
    known_text = (SOURCES / "QwenLayerStageMetadata.swift").read_text()
    block = known_text.split("let knownKeys: Set<String> = [", 1)[1].split("]", 1)[0]
    known_keys = set(re.findall(r'"([^"\n]+)"', block))
    models = []
    configs = [json.loads(p.read_bytes()) for p in config_paths]
    for label, config, path in zip(["Qwen3.5-9B", "EigenLabs/Qwen3.8-27B-4bit-mtp"], configs, config_paths):
        text = config["text_config"]
        layers, interval = text["num_hidden_layers"], text["full_attention_interval"]
        models.append({"model": label, "configurationSHA256": digest(path.read_bytes()),
            "layers": layers, "fullAttentionInterval": interval,
            "structuralCuts": structural_cuts(layers, interval),
            "unknownTextKeysAgainstPinnedPlanner": sorted(set(text) - known_keys),
            "fullConfigurationCandidateAdmissionExecuted": False,
            "executionAdmissionOrCapabilityEstablished": False, "computeCostStatus": "unknown"})
    assert models[0]["unknownTextKeysAgainstPinnedPlanner"] == []
    assert models[1]["unknownTextKeysAgainstPinnedPlanner"] == ["output_gate_type"]
    assert configs[1]["text_config"]["output_gate_type"] == "swish"
    expected = json.loads(expected_path.read_bytes())
    assert expected["configurationSHA256"] == models[0]["configurationSHA256"]
    tensors = expected["fullCanonicalTensors"]
    assert len(tensors) == 927 and len({t["sourceName"] for t in tensors}) == 927
    sizes = {"uint32": 4, "bfloat16": 2, "float32": 4}
    for tensor in tensors:
        assert tensor["byteCount"] == math.prod(tensor["shape"]) * sizes[tensor["loadedDType"]]
        assert tensor["loadedDType"] == tensor["sourceDType"]  # This saved artifact has no F16 conversions.
    total = sum(t["byteCount"] for t in tensors)
    assert total == expected["sourceModelTensorBytes"] == 5038041600
    prefix = "language_model.model.layers."
    summaries = []
    for cut in models[0]["structuralCuts"]:
        owned = [[], []]
        for tensor in tensors:
            name = tensor["sourceName"]
            if name.startswith(prefix):
                layer, suffix = name[len(prefix):].split(".", 1)
                assert str(int(layer)) == layer and 0 <= int(layer) < 32
                stage = int(int(layer) >= cut)
                local_name = prefix + str(int(layer) - (cut if stage else 0)) + "." + suffix
            elif name.startswith("language_model.model.embed_tokens."):
                stage, local_name = 0, name
            elif name.startswith("language_model.lm_head.") or name == "language_model.model.norm.weight":
                stage, local_name = 1, name
            else:
                raise ValueError("Unexpected canonical text namespace: " + name)
            owned[stage].append(dict(tensor, localName=local_name))
        rows = []
        for stage, (begin, end) in enumerate([(0, cut), (cut, 32)]):
            state = []
            for layer in range(begin, end):
                components = ["kv.keys", "kv.values", "kv.position_offsets"] if (layer + 1) % 4 == 0 else ["conv", "ssm"]
                state += [{"globalLayerIndex": layer, "localLayerIndex": layer - begin, "component": c} for c in components]
            rows.append({"stageIndex": stage, "sourceRange": [begin, end],
                "canonicalTensorCount": len(owned[stage]),
                "declaredSourceTensorBytes": sum(t["byteCount"] for t in owned[stage]),
                "retainedDescriptorMappingSHA256": digest(canonical(owned[stage])),
                "stateComponentCount": len(state), "stateOwnershipSHA256": digest(canonical(state)),
                "computeCostStatus": "unknown"})
        assert sum(x["canonicalTensorCount"] for x in rows) == 927
        assert sum(x["declaredSourceTensorBytes"] for x in rows) == total
        assert sum(x["stateComponentCount"] for x in rows) == 72
        summaries.append({"cut": cut, "stages": rows})
    assert before == [pin(p) for p in paths]
    return {"schemaVersion": 1, "kind": "qwen_layer_stage_candidate_metadata_preview",
        "sourceInputs": before, "models": models, "nineBDeclaredOwnership": summaries,
        "mappingHashEncoding": "SHA256 of sorted-key compact Python JSON, distinct from native plan fingerprints",
        "limitations": ["No Swift candidate constructor was executed; source review establishes the present 27B unknown-key refusal.",
            "9B tensors are copied from a previously frozen header-derived descriptor record. No current headers or payload bytes were read.",
            "Descriptor byte sums are not allocator, activation, workspace, RSS, admission or execution proofs.",
            "State ownership names are metadata only; no values, state byte sizes or active native roots were checked.",
            "Existing runtime half-split and registered9B 16+16 admission limits remain unchanged.",
            "No compute estimate, per-layer cost, ranking, predicted TPS or 27B execution capability is inferred."],
        "swiftExecuted": False, "modelConstructed": False, "modelPayloadBytesRead": 0,
        "inputPinsUnchanged": True}


def main():
    core = (HERE / "QwenLayerStageCandidates.swift").read_text()
    checks = validate_core(core)
    mutations = [
        ("import Foundation", "import MLX"),
        ("lastCut >= fullAttentionInterval", "lastCut >= 1"),
        ("stride(from: fullAttentionInterval", "stride(from: 1"),
        ("return Array(stride", "let x = layers / 2\n        return Array(stride"),
        ("configuration.count <= 1_048_576", "configuration.count <= Int.max"),
        ("guard !activeMTP,", "guard true,"),
        ("guard !cuts.isEmpty else", "guard true else"),
        ("let plan = try QwenLayerStagePlan", "let plan = try? QwenLayerStagePlan"),
        ("ranges: [0..<cut, cut..<layers]", "ranges: [0..<16, 16..<32]"),
        ("let parameters = try plan.parameters", "let parameters = try? plan.parameters"),
        ("return try cuts.map", "return try cuts.compactMap"),
        ("StateOwnership(layer: layer,", "StateOwnership(layer: modifiedLayer,"),
        ("components = [.convolution, .ssm]", "components = [.ssm]"),
        ("case unknown }", "case unknown, estimated }"),
    ]
    for old, new in mutations:
        assert old in core
        try:
            validate_core(core.replace(old, new, 1))
        except ValueError:
            pass
        else:
            raise AssertionError("Source check accepted mutation: " + old)
    preview = metadata_preview()
    preview_path = HERE / "metadata-preview.json"
    preview_path.write_text(json.dumps(preview, sort_keys=True, indent=2) + "\n")
    receipt = {"schemaVersion": 1, "status": "passed", "scope": "CPU source invariants and pinned retained metadata only",
        "sourceChecksPassed": len(checks), "sourceMutationRejections": len(mutations), "checks": checks,
        "swiftFixtureExecuted": False, "nativeOrModelWork": False, "candidateTimingInputsRead": False,
        "files": [pin(HERE / n) for n in ["QwenLayerStageCandidates.swift", "QwenLayerStageCandidatesCheck.swift", "source_check.py", "metadata-preview.json"]]}
    (HERE / "source-check-receipt.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": "passed", "sourceChecks": len(checks), "sourceMutationsRejected": len(mutations),
        "nineBCuts": preview["models"][0]["structuralCuts"], "twentySevenBStructuralCuts": len(preview["models"][1]["structuralCuts"]),
        "twentySevenBUnknownKeys": preview["models"][1]["unknownTextKeysAgainstPinnedPlanner"]}, sort_keys=True))


if __name__ == "__main__":
    main()
