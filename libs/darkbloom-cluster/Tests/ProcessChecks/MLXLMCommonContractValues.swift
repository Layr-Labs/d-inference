// Test-only value stand-ins. The actual ProviderCore owner/lease source is
// compiled unchanged against these names; this does not qualify an MLX build.
import Foundation
public struct CBv2RequestID: Hashable, Sendable { public let raw: UInt64; public init(_ raw: UInt64) { self.raw = raw } }
public struct CBv2SamplingParams: Sendable {
    public var temperature: Float = 1, topP: Float = 1, minP: Float = 0, repetitionPenalty: Float = 1
    public var frequencyPenalty: Float = 0, presencePenalty: Float = 0
    public var topK = 0, topLogprobs = 0
    public var seed: UInt64?
    public var logitBias: [Int: Float] = [:]
    public init(temperature: Float = 1) { self.temperature = temperature }
}
public struct CBv2Request: Sendable {
    public var id: CBv2RequestID
    public var promptTokens: [Int]
    public var sampling: CBv2SamplingParams
    public var maxTokens: Int
    public var stopTokens = Set<Int>()
    public var stopStrings: [String] = []
    public var priority = 0
    public var prefixCacheReceiptID: CBv2RequestID?
    public var multimodal: Int?, positionState: Int?, tokenConstraint: Int?
    public init(id: CBv2RequestID, promptTokens: [Int], sampling: CBv2SamplingParams, maxTokens: Int) {
        self.id = id; self.promptTokens = promptTokens; self.sampling = sampling; self.maxTokens = maxTokens
    }
}
public struct CBv2FirstTokenDeadlineAdmission: Sendable { public init() {} }
public enum CBv2FirstTokenProjectedWork: Sendable, Equatable { case unbounded }
public enum CBv2FinishReason: Sendable, Equatable { case stop, length, cancelled, error(String) }
