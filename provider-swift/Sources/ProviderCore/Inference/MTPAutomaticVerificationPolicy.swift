import Foundation

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Request-stateful assistants own enough trusted history to use the
    /// engine's marginal 0...4 controller. Stateless Gemma keeps the
    /// established fixed initial depth.
    static func fixedDraftTokens(usesRequestStatefulDrafter: Bool) -> Int? {
        usesRequestStatefulDrafter ? nil : initialDraftTokens
    }

    public static func maxRectangularTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        chipName: String? = nil
    ) -> Int {
        let resolvedChipName = chipName
            ?? (try? sysctlString("machdep.cpu.brand_string"))
            ?? "Unknown"
        let certifiedMaximum = maxRectangularTokens(chipName: resolvedChipName)
        if let value = environment["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS"].flatMap(Int.init) {
            return min(max(value, 0), certifiedMaximum)
        }
        return certifiedMaximum
    }

    public static func maxRectangularTokens(chipName: String) -> Int {
        switch parseChipIdentity(chipName).0 {
        case .m3, .m4, .m5:
            return 8
        case .m1, .m2, .unknown:
            return 4
        }
    }
}
