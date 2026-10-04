import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Qualified Bonsai demanded short checkpoints", .serialized)
struct BonsaiDemandedShortCheckpointTests {
  @Test("serving and production benchmark qualify the exact canonical artifact")
  func canonicalProductionArtifactQualifies() throws {
    let fixture = try BonsaiShortCheckpointFixture()
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    #expect(!model.cbv2RecurrentStateSpec.layers.isEmpty)
    for floor in [1_024, 2_048] {
      let store = try fixture.store(floor: floor)
      for purpose in [EngineV2Factory.ConstructionPurpose.serving, .benchmark] {
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
          model: model, backend: .paged, store: store,
          constructionPurpose: purpose, checkpointPartition: .production) == floor)
      }
    }
  }

  @Test("aliases and replacement aggregate hashes require new qualification")
  func exactCanonicalIdentityOnly() throws {
    let fixture = try BonsaiShortCheckpointFixture()
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    for modelID in ["prism-ml/Ternary-Bonsai-2-27B-mlx-2bit",
      "EigenLabs/Ternary-Bonsai-2-27B-MLX-2bit", "prism-ml/ternary-bonsai-2-27b",
      "ternary-bonsai-2-27b-future", "TERNARY-BONSAI-2-27B", "ternary-bonsai-2-27b "] {
      #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
        model: model, backend: .paged, store: try fixture.store(modelID: modelID)) == nil)
    }
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: model, backend: .paged,
      store: try fixture.store(aggregate: String(repeating: "b", count: 64))) == nil)
  }

  @Test("paged COMPLETE storage and the unchanged one-thousand-token floor are required")
  func backendLayoutAndFloorRemainMandatory() throws {
    let fixture = try BonsaiShortCheckpointFixture()
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: model, backend: .paged, store: nil) == nil)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: model, backend: .contiguous, store: try fixture.store()) == nil)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: model, backend: .paged, store: try fixture.store(floor: 1_023)) == nil)
    for layout in [CBv2CompleteCheckpointManifest.layout,
      CBv2CompleteCheckpointManifest.historicalAttentionLayout,
      CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout] {
      #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
        model: model, backend: .paged, store: try fixture.store(layout: layout)) == nil)
    }
  }

  @Test("the final serving wrapper retains actual MTP-off capability and identity")
  func wrapperIdentityAndActualMTPRemainUnchanged() throws {
    let fixture = try BonsaiShortCheckpointFixture()
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    let serving = try EngineV2Factory.directServingModel(model: model, isVLM: true)
    #expect((serving as? MLXVLM.PrismHadamardQwen35) === model)
    #expect(model.cbv2Capabilities.supportsMTP == false)
    #expect(EngineV2Factory.ProductionModelAdapter(model: serving)?.modelCapabilities.supportsMTP == false)
  }

  @Test("an attention-only wrapper is excluded while existing dense policy is retained")
  func actualRecurrentStateIsRequiredAndDensePolicyIsPreserved() throws {
    let fixture = try BonsaiShortCheckpointFixture(attentionOnly: true)
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    #expect(model.cbv2RecurrentStateSpec.layers.isEmpty)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: model, backend: .paged, store: try fixture.store()) == nil)
    let recurrentFixture = try BonsaiShortCheckpointFixture()
    defer { recurrentFixture.remove() }
    let fields = try #require(try JSONSerialization.jsonObject(with: recurrentFixture.modelData)
      as? [String: Any])
    let textData = try JSONSerialization.data(withJSONObject: try #require(fields["text_config"]))
    let genericText = Qwen35TextModel(try JSONDecoder().decode(
      Qwen35TextConfiguration.self, from: textData))
    #expect(!genericText.cbv2RecurrentStateSpec.layers.isEmpty)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: genericText, backend: .paged, store: try recurrentFixture.store()) == nil)
    // The existing Qwen35Model branch is unchanged, including its existing
    // Prism text subclass. This newly measured profile covers the VLM wrapper.
    let dense = try MLXLLM.PrismHadamardQwen35TextModel(configurationData: fixture.modelData)
    #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
      model: dense, backend: .paged, store: try fixture.store()) == 1_024)
  }

  @Test("serving and production remain short-only even with a benchmark selector")
  func longPromptExtensionRemainsBenchmarkOnly() throws {
    let fixture = try BonsaiShortCheckpointFixture()
    defer { fixture.remove() }
    let model = try MLXVLM.PrismHadamardQwen35(configurationData: fixture.modelData)
    let store = try fixture.store()
    for purpose in [EngineV2Factory.ConstructionPurpose.serving, .benchmark] {
      #expect(!EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
        model: model, backend: .paged, store: store,
        constructionPurpose: purpose, checkpointPartition: .production))
    }
    #expect(!EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
      model: model, backend: .paged, store: store,
      constructionPurpose: .serving, checkpointPartition: .demandedRecurrentQualification))
    #expect(EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
      model: model, backend: .paged, store: store,
      constructionPurpose: .benchmark, checkpointPartition: .demandedRecurrentQualification))
  }
}
