import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@_spi(Benchmarking) @testable import ProviderCore

@Suite("Diffusion CLI benchmark row schema without a model")
struct DiffusionGemmaBenchmarkRowTests {
  private struct UsageRow: Decodable {
    let promptTokens: Int
    let promptTokenIDs: [Int]?
    let completionTokensIncludingEOS: Int
    let committedTokensExcludingEOS: Int
    let tokenIDs: [Int]
  }

  private func row(promptTokenIDs: [Int]?) throws -> DiffusionGemmaBenchmarkRow {
    var usage = CBv2Usage(promptTokens: 42, completionTokens: 4)
    usage.timing.prefillFirstLaunchNanos = 1_000_000
    usage.timing.promptComputedNanos = 101_000_000
    usage.timing.firstTokenNanos = 1_101_000_000
    usage.timing.finishedNanos = 1_201_000_000
    usage.timing.batchRowsMax = 1
    usage.timing.batchRowsSum = 9
    usage.timing.prefillChunks = 2
    usage.timing.decodeSteps = 1
    usage.timing.stepLatencyNanosSum = 300
    usage.timing.stepLatencyNanosMax = 150
    let sample = DiffusionGemmaBenchmarkIteration(
      tokenIDs: [7, 8, 9], text: "synthetic", usage: usage, totalMilliseconds: 1300,
      promptTokenIDs: promptTokenIDs, renderDate: "2026-10-09",
      preRequestActiveMemoryBytes: 100, peakMLXMemoryBytes: 350,
      peakObservedKVBytesInUse: 80, peakObservedKVBytesReserved: 96,
      peakObservedPagedCommittedBytes: 64, peakObservedPagedLivePageBytes: 48)
    let grant = EngineV2BenchmarkProductionGrant(
      physicalBytes: 1024, capFraction: 0.9, hardCapBytes: 921,
      effectiveCapBytes: 900, operatorReserveBytes: 124,
      activationReserveBytes: 100, targetWeightBytes: 200,
      assistantWeightBytes: 0, residentWeightBytes: 200,
      ramPrefixAllowanceBytes: 0, slotCount: 1, fleetBudgetBytes: 600,
      grantBytes: 600)
    let report = DiffusionGemmaBenchmarkResult(
      iterations: [sample], weightHash: "fixture-weights", backend: "paged",
      kvQuantization: "balanced", loadMilliseconds: 25, grant: grant)
    return try DiffusionGemmaBenchmarkRow(
      iteration: 2, report: report, sample: sample,
      runtimeIdentity: ["binary_sha256": "fixture-binary", "metallib_sha256": "fixture-metal"])
  }

  @Test(arguments: [Optional<[Int]>.none, .some([]), .some([11, 17, 11])])
  func promptUsageCountStaysNumericAndIDsHaveTheirOwnField(promptTokenIDs: [Int]?) throws {
    let report = try row(promptTokenIDs: promptTokenIDs)
    let data = Data(try report.jsonString().utf8)
    // A consumer using the existing numeric schema rejects an ID array or
    // a missing count. The usage count is deliberately unlike the ID length.
    let decoded = try JSONDecoder().decode(UsageRow.self, from: data)
    #expect(decoded.promptTokens == 42)
    #expect(decoded.promptTokenIDs == promptTokenIDs)
    #expect(decoded.completionTokensIncludingEOS == 4)
    #expect(decoded.committedTokensExcludingEOS == 3)
    #expect(decoded.tokenIDs == [7, 8, 9])
    let decodedObject = try JSONSerialization.jsonObject(with: data)
    let object = try #require(decodedObject as? [String: Any])
    if promptTokenIDs == nil {
      #expect(object["promptTokenIDs"] == nil)
    } else {
      #expect(object["promptTokenIDs"] as? [Int] == promptTokenIDs)
    }
  }

  @Test func diagnosticsAndMemoryFieldsKeepTheirExistingUnits() throws {
    let report = try row(promptTokenIDs: [11, 17, 11])
    let json = try report.jsonString()
    let decodedObject = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let object = try #require(decodedObject as? [String: Any])
    #expect(object["nativeExecutionQuanta"] as? Int == 9)
    #expect(object["nativePrefillQuanta"] as? Int == 2)
    #expect(object["committedBlocksAfterFirst"] as? Int == 1)
    #expect(object["nativeQuantumWallNanoseconds"] as? Int == 300)
    #expect(object["nativeQuantumMaxWallNanoseconds"] as? Int == 150)
    #expect(object["prefillMilliseconds"] as? Double == 100)
    #expect(object["generationIncludingFirstBlockMilliseconds"] as? Double == 1100)
    #expect(object["peakMLXMemoryDeltaBytes"] as? Int == 250)
    #expect(object["peakObservedPagedCommittedBytes"] as? Int == 64)
    #expect(object["peakObservedPagedLivePageBytes"] as? Int == 48)
    #expect(object["kvGrantBytes"] as? Int == 600)
    #expect(object["speedTargetQualified"] as? Bool == false)
    #expect(object["runtimeIdentity"] as? [String: String] == report.runtimeIdentity)
    let expectedHash = SHA256.hash(data: try JSONEncoder().encode([7, 8, 9]))
      .map { String(format: "%02x", $0) }.joined()
    #expect(object["committedTokenSHA256"] as? String == expectedHash)
    #expect(object["rawTextSHA256"] as? String == report.rawTextSHA256)
  }
}
