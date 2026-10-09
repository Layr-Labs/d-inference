import CryptoKit
import Foundation
@_spi(Benchmarking) import ProviderCore

/// The ordinary native-block CLI row. Usage counts and token IDs have distinct
/// keys so existing numeric aggregations keep the original JSON contract.
public struct DiffusionGemmaBenchmarkRow: Encodable, Sendable {
  public let iteration: Int
  public let backend: String
  public let weightHash: String
  public let kvQuantization: String
  public let runtimeIdentity: [String: String]
  public let tokenIDs: [Int]
  public let text: String
  public let loadIncludingIntegrityMilliseconds: Double
  public let promptTokens: Int
  public let promptTokenIDs: [Int]?
  public let completionTokensIncludingEOS: Int
  public let committedTokensExcludingEOS: Int
  public let prefillMilliseconds: Double
  public let firstCommittedMilliseconds: Double
  public let generationIncludingFirstBlockMilliseconds: Double
  public let committedTokensPerSecond: Double
  public let totalMilliseconds: Double
  public let observedBatchRowsMax: UInt32
  public let nativeExecutionQuanta: UInt64
  public let nativePrefillQuanta: UInt32
  public let committedBlocksAfterFirst: UInt32
  public let nativeQuantumWallNanoseconds: UInt64
  public let nativeQuantumMaxWallNanoseconds: UInt64
  public let committedTokenSHA256: String
  public let rawTextSHA256: String
  public let kvGrantBytes: Int
  public let speedTargetQualified = false
  public let capacityObservation =
    "Host samples before submit and at delta/terminal events; excludes unobserved prefill transient peaks. Pre-request active bytes include weights and setup allocations."
  public let renderDate: String?
  public let preRequestActiveMemoryBytes: Int?
  public let peakMLXMemoryBytes: Int?
  public let peakMLXMemoryDeltaBytes: Int?
  public let peakObservedKVBytesInUse: Int?
  public let peakObservedKVBytesReserved: Int?
  public let peakObservedPagedCommittedBytes: Int?
  public let peakObservedPagedLivePageBytes: Int?

  init(
    iteration: Int, report: DiffusionGemmaBenchmarkResult,
    sample: DiffusionGemmaBenchmarkIteration, runtimeIdentity: [String: String]
  ) throws {
    self.iteration = iteration
    backend = report.backend
    weightHash = report.weightHash
    kvQuantization = report.kvQuantization
    self.runtimeIdentity = runtimeIdentity
    tokenIDs = sample.tokenIDs
    text = sample.text
    loadIncludingIntegrityMilliseconds = report.loadMilliseconds
    promptTokens = sample.usage.promptTokens
    promptTokenIDs = sample.promptTokenIDs
    completionTokensIncludingEOS = sample.usage.completionTokens
    committedTokensExcludingEOS = sample.tokenIDs.count
    prefillMilliseconds = sample.prefillMilliseconds
    firstCommittedMilliseconds = sample.firstCommittedMilliseconds
    generationIncludingFirstBlockMilliseconds = sample.generationMilliseconds
    committedTokensPerSecond = sample.committedTokensPerSecond
    totalMilliseconds = sample.totalMilliseconds
    observedBatchRowsMax = sample.usage.timing.batchRowsMax
    // These recorded native work diagnostics add no sampling/evaluation.
    nativeExecutionQuanta = sample.usage.timing.batchRowsSum
    nativePrefillQuanta = sample.usage.timing.prefillChunks
    committedBlocksAfterFirst = sample.usage.timing.decodeSteps
    nativeQuantumWallNanoseconds = sample.usage.timing.stepLatencyNanosSum
    nativeQuantumMaxWallNanoseconds = sample.usage.timing.stepLatencyNanosMax
    committedTokenSHA256 = SHA256.hash(data: try JSONEncoder().encode(sample.tokenIDs))
      .map { String(format: "%02x", $0) }.joined()
    rawTextSHA256 = SHA256.hash(data: Data(sample.text.utf8))
      .map { String(format: "%02x", $0) }.joined()
    kvGrantBytes = report.grant.grantBytes
    renderDate = sample.renderDate
    preRequestActiveMemoryBytes = sample.preRequestActiveMemoryBytes
    peakMLXMemoryBytes = sample.peakMLXMemoryBytes
    if let peak = sample.peakMLXMemoryBytes, let baseline = sample.preRequestActiveMemoryBytes {
      peakMLXMemoryDeltaBytes = max(0, peak - baseline)
    } else {
      peakMLXMemoryDeltaBytes = nil
    }
    peakObservedKVBytesInUse = sample.peakObservedKVBytesInUse
    peakObservedKVBytesReserved = sample.peakObservedKVBytesReserved
    peakObservedPagedCommittedBytes = sample.peakObservedPagedCommittedBytes
    peakObservedPagedLivePageBytes = sample.peakObservedPagedLivePageBytes
  }

  public func jsonString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
