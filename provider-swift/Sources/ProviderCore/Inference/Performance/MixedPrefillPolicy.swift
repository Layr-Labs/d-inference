import Foundation

enum MixedPrefillPolicy {
    static let globalKey = "DARKBLOOM_CBV2_MIXED_PREFILL_CAP"
    static let modelKey = "DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL"

    /// Per-model overrides precede the existing process override; reviewed
    /// profiles supply the automatic policy. Unknown models retain no cap.
    /// Gemma's ordinary floor preserves final-layer narrowing; zero is the
    /// existing explicit disable-prefill-while-decoding diagnostic override.
    static func resolve(
        modelID: String?, profile: ServingPerformanceProfile?, environment: [String: String],
        requiresNarrowingFloor: Bool = false
    ) -> Int? {
        var selected: Int?
        if let modelID, let entries = environment[modelKey] {
            for entry in entries.split(separator: ",") {
                let fields = entry.split(separator: "=", maxSplits: 1)
                guard fields.count == 2,
                    fields[0].trimmingCharacters(in: .whitespaces) == modelID,
                    let cap = Int(fields[1].trimmingCharacters(in: .whitespaces)), cap >= 0
                else { continue }
                selected = cap
            }
        }
        if selected == nil, let raw = environment[globalKey], let cap = Int(raw), cap >= 0 {
            selected = cap
        }
        selected = selected ?? profile?.mixedPrefillTokenCap
        if let selected, selected > 0,
            requiresNarrowingFloor || modelID?.lowercased().contains("gemma") == true {
            return max(128, selected)
        }
        return selected
    }
}
