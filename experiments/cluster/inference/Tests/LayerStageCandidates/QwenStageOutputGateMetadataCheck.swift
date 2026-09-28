import Foundation

struct QwenStageOutputGateMetadataCheckResult: Encodable {
    let kind = "qwen_stage_output_gate_metadata_check"
    let cpuMetadataOnly = true
    let modelExecutionValidated = false
    let providerDecoderChanged = false
    let acceptedCases: Int
    let rejectedCases: Int
    let originalFieldSpellingPreserved = true
}

/// Caller supplies a valid dense-Qwen text/wrapper configuration and legal ranges.
/// Invoke with retained 9B and 27B configurations separately if both are desired;
/// this fixture performs no file read, model construction, load or execution.
func checkQwenStageOutputGateMetadata(configuration: Data, ranges: [Range<Int>]) throws
    -> QwenStageOutputGateMetadataCheckResult {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Output-gate metadata fixture: " + message) }
    }
    guard let originalRoot = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
        throw ProbeError("Output-gate metadata fixture requires a configuration object")
    }
    let nested = originalRoot["text_config"] != nil
    let originalText: [String: Any]
    if nested {
        guard let text = originalRoot["text_config"] as? [String: Any] else {
            throw ProbeError("Output-gate metadata fixture requires object text_config")
        }
        originalText = text
    } else { originalText = originalRoot }
    func configured(_ gate: Any?) throws -> Data {
        var root = originalRoot, text = originalText
        if let gate { text["output_gate_type"] = gate }
        else { text.removeValue(forKey: "output_gate_type") }
        if nested { root["text_config"] = text } else { root = text }
        return try QwenStageMetadata.json(root)
    }
    var accepted = 0, rejected = 0
    var fingerprints: [String] = []
    // Removal here creates a prospective absent-field test input. Production
    // validation never removes/normalizes this property to admit an artifact.
    let acceptedValues: [String?] = [nil, "swish", "silu"]
    for value in acceptedValues {
        let data = try configured(value)
        let plan = try QwenLayerStagePlan(configuration: data, ranges: ranges)
        try require(plan.originalConfiguration == data, "original input bytes changed")
        for stage in plan.stages {
            guard let root = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any] else {
                throw ProbeError("Output-gate metadata fixture received a non-object stage config")
            }
            let text = nested ? root["text_config"] as! [String: Any] : root
            if let value {
                try require(text["output_gate_type"] as? String == value,
                    "stage removed or normalized the declared spelling")
            } else {
                try require(text["output_gate_type"] == nil, "stage invented an absent gate property")
            }
        }
        fingerprints.append(plan.fingerprint)
        accepted += 1
    }
    try require(Set(fingerprints).count == 3,
        "distinct source declarations lost their plan identity")
    let rejectedValues: [Any] = [
        "sigmoid", "tanh", "", "SWISH", "Swish", " swish", "swish ",
        true, false, 0, 1, 1.5, NSNull(), ["swish"], ["type": "swish"],
    ]
    for value in rejectedValues {
        let data = try configured(value)
        do {
            _ = try QwenLayerStagePlan(configuration: data, ranges: ranges)
        } catch {
            try require(String(describing: error).contains("output gate"),
                "negative failed outside the new gate-value guard")
            rejected += 1
            continue
        }
        throw ProbeError("Output-gate metadata fixture accepted an unsupported declaration")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected)
}
