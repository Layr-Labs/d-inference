import CryptoKit
import Foundation
import MLXLMCommon
import MLXVLM

@testable import ProviderCore

/// Real final wrapper and empty encrypted store. These policy witnesses do not
/// evaluate native model arrays or qualify artifact performance.
final class BonsaiShortCheckpointFixture {
  static let modelID = "ternary-bonsai-2-27b"
  static let aggregate = "ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c"
  let root: URL
  let modelData: Data
  private var stores: [SSDHybridCheckpointStore] = []

  init(attentionOnly: Bool = false) throws {
    let text: [String: Any] = [
      "model_type": "qwen3_5_text", "hidden_size": 64, "num_hidden_layers": 1,
      "intermediate_size": 128, "num_attention_heads": 1, "num_key_value_heads": 1,
      "head_dim": 64, "linear_num_value_heads": 1, "linear_num_key_heads": 1,
      "linear_key_head_dim": 64, "linear_value_head_dim": 64,
      "linear_conv_kernel_dim": 4, "full_attention_interval": attentionOnly ? 1 : 4,
      "vocab_size": 128, "mtp_num_hidden_layers": 0, "num_experts": 0,
    ]
    let vision: [String: Any] = [
      "model_type": "qwen3_5", "depth": 1, "hidden_size": 64,
      "intermediate_size": 128, "out_hidden_size": 64, "num_heads": 1,
      "patch_size": 1, "spatial_merge_size": 1, "temporal_patch_size": 1,
      "num_position_embeddings": 16, "deepstack_visual_indexes": [Int](),
    ]
    let fields: [String: Any] = [
      "schema_version": 2, "model_type": "prism_hadamard_qwen35",
      "base_model_type": "qwen3_5", "gdn_activation_layout": "grouped",
      "tensor_namespace": "mlx-vlm-qwen3_5", "hadamard_config": "hadamard.json",
      "components": ["text": true, "vision": true, "mtp": false],
      "quantization": ["bits": 2, "group_size": 128, "mode": "affine"],
      "text_config": text, "vision_config": vision,
      "modules": [
        ["path": "model.embed_tokens", "block": 512, "embedding": true, "dtype": "float16"],
        ["path": "lm_head", "block": 512, "embedding": false, "dtype": "float16"],
      ],
    ]
    modelData = try JSONSerialization.data(withJSONObject: fields)
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("bonsai-short-policy-\(UUID().uuidString)")
  }

  func store(modelID: String = BonsaiShortCheckpointFixture.modelID,
    aggregate: String = BonsaiShortCheckpointFixture.aggregate, floor: Int = 1_024,
    layout: String = CBv2CompleteCheckpointManifest.pagedLayout
  ) throws -> SSDHybridCheckpointStore {
    let modelRoot = root.appendingPathComponent(String(format: "%012x", stores.count))
    try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
    let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: aggregate,
      promptContractID: String(repeating: "a", count: 64), buildID: "fixture-build",
      numericsFingerprint: "fixture-numerics")
    let store = SSDHybridCheckpointStore(config: .init(
      modelId: modelID, identity: identity, backendLayout: layout,
      root: modelRoot, dedicatedRoot: root, epochStore: nil,
      maxReadBytes: 16 << 20, maxStageMillis: 1_000, minEffectiveTokens: floor,
      ttlSeconds: 1_800, strictFsync: false, nowSeconds: { 100 },
      diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
      kekKey: SymmetricKey(data: Data(repeating: 7, count: 32)),
      kvBudget: nil, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
    stores.append(store)
    return store
  }

  func remove() {
    // No request/stage/write is submitted by these factory-policy tests.
    stores.forEach { $0.close() }
    try? FileManager.default.removeItem(at: root)
  }
}
