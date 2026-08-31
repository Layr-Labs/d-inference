import Foundation

extension WorkerInferenceSupport {
    enum ReusableSSDWeightHashDecision: Equatable {
        case eligible(String)
        case unavailable
        case changed
    }

    static func clampEngineV2Concurrency(_ requested: UInt64) -> Int {
        Int(min(max(requested, 1), 8))
    }

    static func assistantMemoryFits(
        availableGb: Double,
        targetRequiredGb: Double,
        assistantBytes: UInt64
    ) -> Bool {
        guard availableGb.isFinite, targetRequiredGb.isFinite else { return false }
        let assistantGb = Double(assistantBytes) / 1_073_741_824.0
        return availableGb >= targetRequiredGb + assistantGb
    }

    static func pendingLoadReservationBytes(
        estimatedWeightsGb: Double,
        extraWeightBytes: UInt64
    ) -> UInt64 {
        let base: UInt64
        if !estimatedWeightsGb.isFinite || estimatedWeightsGb <= 0 {
            base = 0
        } else if estimatedWeightsGb >= Double(UInt64.max) / 1_073_741_824.0 {
            base = UInt64.max
        } else {
            base = UInt64((estimatedWeightsGb * 1_073_741_824.0).rounded(.up))
        }
        let (sum, overflow) = base.addingReportingOverflow(extraWeightBytes)
        return overflow ? UInt64.max : sum
    }

    static func modelIsVLM(at modelPath: URL) -> Bool {
        let configURL = modelPath.appendingPathComponent("config.json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: configURL, options: [.mappedIfSafe]),
            data.count <= 16 * 1024 * 1024,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        if let visionConfig = object["vision_config"], !(visionConfig is NSNull) {
            return true
        }
        if let architectures = object["architectures"] as? [String] {
            return architectures.contains { architecture in
                let lowered = architecture.lowercased()
                return lowered.contains("vision") || lowered.contains("vl")
            }
        }
        return false
    }

    static func reusableSSDWeightHashDecision(
        preLoadHash: String?,
        postLoadHash: String?
    ) -> ReusableSSDWeightHashDecision {
        guard let preLoadHash, let postLoadHash else { return .unavailable }
        return preLoadHash == postLoadHash ? .eligible(preLoadHash) : .changed
    }
}
