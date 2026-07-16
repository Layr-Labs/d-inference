import Foundation

/// Exact benchmark-side mirror of SpecDecLimits.residentEstimate. ProviderCore
/// does not expose that helper publicly, so a drift test pins the two formulas.
public enum MTPBenchmarkSizing {
    public static let assistantResidentMultiplier = 1.20

    public static func assistantResidentBytes(artifactBytes: UInt64) -> UInt64 {
        guard artifactBytes > 0 else { return 0 }
        let estimate = (Double(artifactBytes) * assistantResidentMultiplier).rounded(.up)
        guard estimate.isFinite, estimate < Double(UInt64.max) else { return .max }
        return UInt64(estimate)
    }

    public static func assistantResidentBytes(
        artifact: MTPBenchmarkArtifactFacts
    ) -> UInt64 {
        assistantResidentBytes(artifactBytes: UInt64(max(0, artifact.artifactBytes)))
    }

    /// Total resident model weights handed to `UnifiedMemoryCap`. Assistant
    /// memory is model residency, not an operator/OS reserve.
    public static func totalResidentWeightBytes(
        targetWeightBytes: Int,
        assistant: MTPBenchmarkArtifactFacts
    ) -> UInt64 {
        let target = UInt64(max(0, targetWeightBytes))
        let value = target.addingReportingOverflow(assistantResidentBytes(artifact: assistant))
        return value.overflow ? .max : value.partialValue
    }
}
