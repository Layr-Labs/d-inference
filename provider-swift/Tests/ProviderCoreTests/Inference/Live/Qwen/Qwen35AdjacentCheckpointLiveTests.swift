import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

@Suite("Qwen3.5 adjacent demanded fork (live)", .serialized)
struct Qwen35AdjacentCheckpointLiveTests {
  private static let enabled =
    LiveInferenceFixtures.liveTestsEnabled
    && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CHECKPOINT_RETENTION"] == "1"

  @Test(
    "an adjacent demanded fork saves 4,096 additional tokens after encrypted SSD restart",
    .timeLimit(.minutes(15)), .enabled(if: enabled))
  func adjacentDemandedForkBeforeAfter() async throws {
    let fixture = try await Qwen35CheckpointRetentionFixture()
    do {
      let stripe = 1_024
      let tokens = try fixture.shortDonor(deepest: 6_144, stripeTokens: stripe)
      let fork = try fixture.forkPrompt(sharingAtLeast: 5_120)
      try #require(Qwen35CheckpointRetentionFixture.sharedPrefix(tokens, fork.tokens) >= 5_120)
      let store = try fixture.makeStore()
      let bridge = try fixture.makeBridge(store: store, stripeTokens: stripe)
      let donor = try await runQwen35CheckpointRetention(
        fixture, bridge: bridge, tokens: tokens, scope: "tenant-adjacent",
        id: "adjacent-donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
        donationDemand: .init(repeatedPrefixTokens: 5_120))
      try await requireQwen35CheckpointIdle(bridge)
      await store.waitForWritesForTesting()
      let kept = try fixture.positions(scope: "tenant-adjacent", prefixOf: tokens)
      #expect(kept.positions == [1_024, 5_120, 6_144])
      let target = try fixture.checkpointFile(position: 5_120, scope: "tenant-adjacent")
      let fileBytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      let tensorBytes = try #require(zip(kept.positions, kept.bytes).first { $0.0 == 5_120 }?.1)
      await bridge.shutdown()
      await store.closeAndWait()

      // The old policy discarded this already-staged endpoint at
      // publication. Withholding only its file recreates that outcome.
      let withheld = target.appendingPathExtension("withheld")
      try FileManager.default.moveItem(at: target, to: withheld)
      let beforeStore = try fixture.makeStore()
      let beforeBridge = try fixture.makeBridge(store: beforeStore, stripeTokens: stripe)
      let before = try await runQwen35CheckpointRetention(
        fixture, bridge: beforeBridge, tokens: fork.tokens, scope: "tenant-adjacent",
        id: "adjacent-before", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
        donationDemand: .init(repeatedPrefixTokens: 0))
      #expect(before.hitTokens == 1_024)
      try await requireQwen35CheckpointIdle(beforeBridge)
      await beforeBridge.shutdown()
      await beforeStore.closeAndWait()
      try FileManager.default.moveItem(at: withheld, to: target)

      let afterStore = try fixture.makeStore()
      let afterBridge = try fixture.makeBridge(store: afterStore, stripeTokens: stripe)
      let after = try await runQwen35CheckpointRetention(
        fixture, bridge: afterBridge, tokens: fork.tokens, scope: "tenant-adjacent",
        id: "adjacent-after", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
        donationDemand: .init(repeatedPrefixTokens: 0))
      #expect(after.hitTokens == 5_120)
      #expect(afterStore.stats().stageConsumptions == 1)
      try await requireQwen35CheckpointIdle(afterBridge)
      await afterBridge.shutdown()
      await afterStore.closeAndWait()

      let coldBridge = try fixture.makeBridge(store: nil, stripeTokens: stripe)
      let cold = try await runQwen35CheckpointRetention(
        fixture, bridge: coldBridge, tokens: fork.tokens, scope: "tenant-adjacent",
        id: "adjacent-cache-off", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker)
      try await requireQwen35CheckpointIdle(coldBridge)
      #expect(before.text == after.text && after.text == cold.text)
      #expect(after.hitTokens - before.hitTokens == 4_096)
      print(
        "[qwen35-adjacent-before-after] modelHash=\(fixture.modelHash) mtp=\(fixture.mtpActive) "
          + "donorPrompt=\(tokens.count) forkPrompt=\(fork.tokens.count) shared=\(fork.shared) "
          + "positions=\(kept.positions) targetTensorBytes=\(tensorBytes) targetFileBytes=\(fileBytes) "
          + "extraSavedTokens=\(after.hitTokens - before.hitTokens) beforeHit=\(before.hitTokens) afterHit=\(after.hitTokens) "
          + "donorTTFT=\(donor.ttft) donorFinishToDone=\(donor.finishToDone) "
          + "beforeTTFT=\(before.ttft) afterTTFT=\(after.ttft) coldTTFT=\(cold.ttft) "
          + "beforeBytesRead=\(beforeStore.stats().bytesRead) afterBytesRead=\(afterStore.stats().bytesRead) "
          + "sameText=\(before.text == after.text && after.text == cold.text)")
      await coldBridge.shutdown()
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

}
