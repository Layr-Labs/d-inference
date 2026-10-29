import Foundation

/// Adapter-supplied synthetic input recipe, bound by canonical capability bytes.
/// It consumes one ordinary admission and uses fresh request state. Completing
/// these shapes does not predict user TTFT or warm every possible context shape.
public struct ClusterRuntimeStartupPreparation: Equatable, Sendable {
    public let kind = "configuredChunkAndDecode_v1"
    public let requestCount = 1
    public let tokenPattern: [Int]
    public let outputCount: Int

    public init(tokenPattern: [Int], outputCount: Int) {
        self.tokenPattern = tokenPattern; self.outputCount = outputCount
    }

    func validate(profile: ClusterWorkerProfile) throws {
        try workerRequire((1...16).contains(tokenPattern.count)
            && tokenPattern.allSatisfy({ $0 >= 0 && $0 < profile.vocabularySize })
            && (2...8).contains(outputCount) && outputCount <= profile.maximumOutputTokens
            && (1...ClusterWorkerLimits.contextTokens).contains(profile.maximumContextTokens)
            && (1...profile.maximumContextTokens).contains(profile.maximumChunkTokens)
            && profile.maximumChunkTokens <= profile.maximumPromptTokens
            && profile.maximumChunkTokens <= profile.maximumContextTokens - outputCount,
            "Startup preparation exceeds its admitted profile")
    }

    public func reservation(profile: ClusterWorkerProfile, chunkSize: Int,
                            deadlineUptimeNanoseconds: UInt64, capacityLimitBytes: Int) throws -> ClusterWorkerReservation {
        try validate(profile: profile)
        try workerRequire((1...profile.maximumChunkTokens).contains(chunkSize)
            && deadlineUptimeNanoseconds > 0
            && (1...ClusterWorkerLimits.capacityBytes).contains(capacityLimitBytes),
            "Invalid startup preparation bounds")
        return .init(profileID: profile.id,
            promptTokenIDs: (0..<chunkSize).map { tokenPattern[$0 % tokenPattern.count] },
            stopTokenIDs: [], outputCount: outputCount, chunkSize: chunkSize,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, capacityLimitBytes: capacityLimitBytes)
    }
}
