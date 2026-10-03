import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

@Suite("Qwen3.5 demanded short checkpoint (live)", .serialized)
struct Qwen35DemandedShortCheckpointLiveTests {
  private static let enabled =
    LiveInferenceFixtures.liveTestsEnabled
    && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CHECKPOINT_RETENTION"] == "1"

  @Test(
    "a demanded short dense prompt captures one aligned prefix and restores exact output",
    .timeLimit(.minutes(15)), .enabled(if: enabled))
  func demandedShortPromptCapturesAndRestores() async throws {
    let fixture = try await Qwen35CheckpointRetentionFixture()
    do {
      let stripe = 4_096
      let tokens = try fixture.shortDonor(deepest: 2_048, stripeTokens: 512)
      let fork = try fixture.forkPrompt(sharingAtLeast: 2_048)
      let scope = "tenant-short"
      let coldBridge = try fixture.makeBridge(store: nil, stripeTokens: stripe)
      let cold = try await runQwen35CheckpointRetention(
        fixture, bridge: coldBridge, tokens: tokens, scope: scope,
        id: "short-cache-off", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker)
      try await requireQwen35CheckpointIdle(coldBridge)
      await coldBridge.shutdown()

      // A fleet-novel prompt keeps the single original prefill range.
      let novelStore = try fixture.makeStore()
      let novelBridge = try fixture.makeBridge(store: novelStore, stripeTokens: stripe)
      let novel = try await runQwen35CheckpointRetention(
        fixture, bridge: novelBridge, tokens: tokens, scope: "tenant-short-novel",
        id: "short-novel", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
        donationDemand: .init(repeatedPrefixTokens: 0))
      try await requireQwen35CheckpointIdle(novelBridge)
      await novelStore.waitForWritesForTesting()
      #expect(novelStore.stats().filesWritten == 0)
      #expect(novel.text == cold.text)
      await novelBridge.shutdown()
      await novelStore.closeAndWait()

      let store = try fixture.makeStore()
      let bridge = try fixture.makeBridge(store: store, stripeTokens: stripe)
      let trace = try await fixture.observeGeometry(bridge)
      let donor = try await runQwen35CheckpointRetention(
        fixture, bridge: bridge, tokens: tokens, scope: scope,
        id: "short-demanded", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
        donationDemand: .init(repeatedPrefixTokens: 2_048))
      try await requireQwen35CheckpointIdle(bridge)
      await store.waitForWritesForTesting()
      let geometry = trace.records(promptLength: tokens.count)
      #expect(geometry.map(\.range) == [0..<2_048, 2_048..<tokens.count])
      #expect(geometry.allSatisfy { $0.cap == stripe }, "the original maximum cap stays unchanged")
      let kept = try fixture.positions(scope: scope, prefixOf: tokens)
      #expect(kept.positions == [2_048])
      #expect(store.stats().filesWritten == 1)
      #expect(donor.text == cold.text)
      let file = try fixture.checkpointFile(position: 2_048, scope: scope)
      let fileBytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      await bridge.shutdown()
      await store.closeAndWait()

      let warmStore = try fixture.makeStore()
      let warmBridge = try fixture.makeBridge(store: warmStore, stripeTokens: stripe)
      let warm = try await runQwen35CheckpointRetention(
        fixture, bridge: warmBridge, tokens: fork.tokens, scope: scope,
        id: "short-warm-fork", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
        donationDemand: .init(repeatedPrefixTokens: 0))
      #expect(warm.hitTokens == 2_048)
      #expect(warmStore.stats().stageConsumptions == 1)
      try await requireQwen35CheckpointIdle(warmBridge)
      await warmBridge.shutdown()
      await warmStore.closeAndWait()
      let forkColdBridge = try fixture.makeBridge(store: nil, stripeTokens: stripe)
      let forkCold = try await runQwen35CheckpointRetention(
        fixture, bridge: forkColdBridge, tokens: fork.tokens, scope: scope,
        id: "short-fork-cache-off", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker)
      try await requireQwen35CheckpointIdle(forkColdBridge)
      #expect(warm.text == forkCold.text)
      print(
        "[qwen35-short-demanded] modelHash=\(fixture.modelHash) mtp=\(fixture.mtpActive) "
          + "prompt=\(tokens.count) hint=2048 stripe=4096 ranges=\(geometry.map(\.range)) "
          + "positions=\(kept.positions) tensorBytes=\(kept.bytes) fileBytes=\(fileBytes) "
          + "coldTTFT=\(cold.ttft) novelTTFT=\(novel.ttft) donorTTFT=\(donor.ttft) "
          + "donorFinishToDone=\(donor.finishToDone) forkPrompt=\(fork.tokens.count) shared=\(fork.shared) "
          + "warmHit=\(warm.hitTokens) warmTTFT=\(warm.ttft) forkColdTTFT=\(forkCold.ttft) "
          + "bytesRead=\(warmStore.stats().bytesRead) sameText=\(warm.text == forkCold.text && donor.text == cold.text)"
      )
      await forkColdBridge.shutdown()
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

}
