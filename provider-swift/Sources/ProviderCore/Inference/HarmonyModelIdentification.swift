// Copyright © 2026 Eigen Labs.

func isHarmonyModelHint(_ value: String?) -> Bool {
    guard let value else { return false }
    let normalized = value.lowercased()
    return normalized.contains("gpt-oss")
        || normalized.contains("gpt_oss")
        || normalized.contains("gptoss")
}
