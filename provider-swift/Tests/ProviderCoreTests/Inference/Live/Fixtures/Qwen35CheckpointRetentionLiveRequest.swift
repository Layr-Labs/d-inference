import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

struct Qwen35CheckpointRetentionOutput {
  let text: String
  let answer: String
  let hitTokens: Int
  let ttft: Duration
  let finishToDone: Duration
}

func runQwen35CheckpointRetention(
  _ fixture: Qwen35CheckpointRetentionFixture, bridge: EngineV2Bridge,
  tokens: [Int], scope: String, id: String, expectedMarker: String,
  donationDemand: SSDCheckpointDonationDemand? = nil
) async throws -> Qwen35CheckpointRetentionOutput {
  let signal = EngineV2RequestUsageSignal()
  let request = ChatCompletionRequest(
    model: fixture.modelID,
    messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
    temperature: 0, max_tokens: 48)
  let started = ContinuousClock.now
  let stream = await bridge.submitTokenized(
    promptTokens: tokens, request: request,
    requestId: id, cacheScope: scope, usageSignal: signal, donationDemand: donationDemand)
  var text = ""
  var firstChunk: ContinuousClock.Instant?
  var lastChunk: ContinuousClock.Instant?
  var done: ContinuousClock.Instant?
  var failure: String?
  var finishReason: String?
  for await event in stream {
    switch event {
    case .chunk(let chunk):
      if firstChunk == nil && !chunk.isEmpty { firstChunk = .now }
      if !chunk.isEmpty { lastChunk = .now }
      text += chunk
    case .info(_, _, _, let reason):
      finishReason = reason
      done = .now
    case .error(let message): failure = message
    case .terminal(_, let message, _, _): failure = message
    }
  }
  let finishToDone = (done ?? .now) - (lastChunk ?? started)
  try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
  try #require(finishReason == "stop", "request \(id) must finish naturally")
  let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
  try #require(!answer.isEmpty, "request \(id) produced no answer")
  let normalized = answer.uppercased().trimmingCharacters(
    in:
      CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'.*")))
  #expect(
    normalized == expectedMarker,
    "request \(id) must preserve the requested fact: \(answer)")
  let other =
    expectedMarker == Qwen35CheckpointRetentionFixture.releaseMarker
    ? Qwen35CheckpointRetentionFixture.backupMarker : Qwen35CheckpointRetentionFixture.releaseMarker
  #expect(
    !answer.uppercased().contains(other),
    "request \(id) must not leak the other marker: \(answer)")
  print(
    "[qwen35-retention-request] id=\(id) hit=\(signal.prefixCacheHitTokens ?? 0) "
      + "ttft=\((firstChunk ?? .now) - started) finishToDone=\(finishToDone) answer=\(answer.debugDescription)"
  )
  return Qwen35CheckpointRetentionOutput(
    text: text, answer: answer, hitTokens: signal.prefixCacheHitTokens ?? 0,
    ttft: (firstChunk ?? .now) - started, finishToDone: finishToDone)
}

func requireQwen35CheckpointIdle(_ bridge: EngineV2Bridge) async throws {
  let deadline = ContinuousClock.now + .seconds(30)
  while true {
    let capacity = await bridge.capacitySnapshot()
    let idle =
      capacity.activeRequests == 0 && capacity.waitingRequests == 0
      && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
    if idle { return }
    if ContinuousClock.now >= deadline {
      try #require(idle, "request accounting did not drain before reconstruction")
      return
    }
    try await taskSleep(.milliseconds(10))
  }
}
