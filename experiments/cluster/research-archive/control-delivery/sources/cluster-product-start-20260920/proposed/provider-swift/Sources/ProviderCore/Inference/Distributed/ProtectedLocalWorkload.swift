import Foundation
import MLXLMCommon
import DarkbloomClusterProtocol

/// Narrow provider-side envelope for the existing protected native experiment.
/// Its original owner still requires exactly P32/O2/empty stops before reserve.
enum ProtectedLocalWorkload {
    static func require(_ request: CBv2Request) throws {
        guard request.promptTokens.count==32,request.maxTokens==2,request.stopTokens.isEmpty,request.stopStrings.isEmpty else {
            throw DistributedEngineError.unsupportedRequest("Protected experiment requires its exact saved short workload")
        }
    }

    static func profile(_ native: ClusterWorkerProfile, requestTimeoutSeconds: Int) throws -> DistributedResidentExecutionProfile {
        guard native.maximumPromptTokens >= 32, native.maximumOutputTokens >= 2,
              native.maximumChunkTokens >= 16, native.maximumContextTokens >= 34,
              (1...300).contains(requestTimeoutSeconds) else { throw NativePairMemberError.binding }
        return try .init(id: native.id, vocabularySize: native.vocabularySize,
            maxPromptTokens: 32, maxOutputTokens: 2, maxContextTokens: 34,
            requestTimeout: .seconds(requestTimeoutSeconds))
    }
}
