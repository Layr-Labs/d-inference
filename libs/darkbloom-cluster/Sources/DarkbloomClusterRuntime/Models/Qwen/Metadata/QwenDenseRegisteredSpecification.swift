import Foundation

/// Closed retained identities, not a model registry or provider allowlist.
/// Its private initializer is used only by the closed catalog below.
struct QwenDenseRegisteredSpecification {
    let model: QwenRegisteredDenseModel
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String, inventorySHA256: String
    /// SHA-256 of the canonical per-tensor content inventory, or nil for a model
    /// nobody has inventoried. It is in no existing fingerprint, so no receipt,
    /// commitment or agreement changes when a model gains one.
    let contentInventorySHA256: String?
    let manifestBytes: Int, manifestFileCount: Int, sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int
    let layers: Int, hidden: Int, queryHeads: Int, linearValueHeads: Int, namedStateBytes: Int
    /// Key/value heads of a full-attention layer.
    let kvHeads: Int
    /// The routed-expert feed-forward of every layer, or nil for a dense one.
    let routedExperts: QwenRoutedExpertGeometry?
    /// True when the artifact's weight files also hold unsigned-byte tensors
    /// that no stage owns (the Qwen3.6 MTP head's MXFP8 payloads). Its headers
    /// are then read under a scope that can describe them; a stage still
    /// loads none.
    let unownedUInt8Tensors: Bool
    /// The `model_type` the artifact's configuration must declare: the routed
    /// family's, or the one its pack declares (`qwen3_5` for an affine pack).
    var rootModelType: String { routedExperts == nil ? model.pack.rootModelType : QwenRoutedExpertStageMetadata.rootModelType }

    private init(model: QwenRegisteredDenseModel, configurationSHA256: String, manifestSHA256: String,
                 contentInventorySHA256: String? = nil,
                 artifactSHA256: String, inventorySHA256: String, manifestBytes: Int, manifestFileCount: Int,
                 sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int, layers: Int, hidden: Int,
                 queryHeads: Int, linearValueHeads: Int, namedStateBytes: Int,
                 kvHeads: Int = 4, routedExperts: QwenRoutedExpertGeometry? = nil,
                 unownedUInt8Tensors: Bool = false) {
        self.model = model; self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.artifactSHA256 = artifactSHA256; self.inventorySHA256 = inventorySHA256; self.manifestBytes = manifestBytes
        self.contentInventorySHA256 = contentInventorySHA256
        self.manifestFileCount = manifestFileCount; self.sourceBytes = sourceBytes; self.tensorCount = tensorCount
        self.largestTensorBytes = largestTensorBytes; self.layers = layers; self.hidden = hidden
        self.queryHeads = queryHeads; self.linearValueHeads = linearValueHeads; self.namedStateBytes = namedStateBytes
        self.kvHeads = kvHeads; self.routedExperts = routedExperts
        self.unownedUInt8Tensors = unownedUInt8Tensors
    }
    func expectedGeometry() throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: layers, fullAttentionInterval: 4, hiddenSize: hidden, queryHeads: queryHeads,
            kvHeads: kvHeads, headDimension: 256, linearKeyHeads: 16, linearValueHeads: linearValueHeads,
            linearKeyDimension: 128, linearValueDimension: 128, convolutionKernel: 4)
    }
    static let all: [Self] = [
        .init(model: .qwen35NineB,
            configurationSHA256: "c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423",
            manifestSHA256: "4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4",
            contentInventorySHA256: "e636e715e70904e6c6ae7a59bd9244fbeaf199fa5972aaa808499646cff7e1c0",
            artifactSHA256: "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
            inventorySHA256: "4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51",
            manifestBytes: 6_113_952_230, manifestFileCount: 12, sourceBytes: 5_038_041_600,
            tensorCount: 927, largestTensorBytes: 508_559_360, layers: 32, hidden: 4096,
            queryHeads: 16, linearValueHeads: 32, namedStateBytes: 745_345_056),
        .init(model: .qwen38TwentySevenB,
            configurationSHA256: "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff",
            manifestSHA256: "d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc",
            artifactSHA256: "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463",
            inventorySHA256: "ebe2ded36d62a6f83bfa1c1b69951a8e24e9e63094745eb60c4bb353c8951624",
            manifestBytes: 16_320_415_757, manifestFileCount: 14, sourceBytes: 15_132_802_048,
            tensorCount: 1847, largestTensorBytes: 635_699_200, layers: 64, hidden: 5120,
            queryHeads: 24, linearValueHeads: 48, namedStateBytes: 1_599_082_560),
        // Qwen3.5 35B A3B, catalog `qwen3.5-35b-a3b` 2026-08-25-r1. 1,637
        // canonical text tensors: 1,757 stored ones, with each layer's routed
        // gate and up halves counted as the one fused tensor they load as.
        .init(model: .qwen35ThirtyFiveBA3B,
            configurationSHA256: "58a2b700bbe36066bc3e8bac65341a7f886c8dbe4db510553150004cfb0294f7",
            manifestSHA256: "db0a8dd2902473c4b6dcd4eab9511212b52fe7bf9cb8e043aebfc47a900d21ff",
            artifactSHA256: "95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c",
            inventorySHA256: "6d40ee61eead498b1b5863a3c975a0b57a7e2e03a59cfe287f88818acdfd54d9",
            manifestBytes: 20_893_747_852, manifestFileCount: 14, sourceBytes: 19_498_262_656,
            tensorCount: 1637, largestTensorBytes: 268_435_456, layers: 40, hidden: 2048,
            queryHeads: 16, linearValueHeads: 32, namedStateBytes: 558_344_232,
            kvHeads: 2, routedExperts: .init(experts: 256, expertsPerToken: 8,
                                             expertIntermediate: 512, sharedIntermediate: 512)),
        // Qwen3.6 35B A3B, catalog `qwen3.6-35b-a3b-vl-mtp-mxfp8` 2026-08-11-r1:
        // the same geometry. Its routers are 8-bit, which the configuration
        // declares per module. Its vision tower and its MTP head, the only
        // tensors that are not affine, are in the same files and are never read.
        .init(model: .qwen36ThirtyFiveBA3B,
            configurationSHA256: "b852ada32203b112e217e5cb48afeadaf16594c0f5d3f5f7a380897e5e8732c2",
            manifestSHA256: "54ba4df3022077a69974cfd4de91196622c865b45ae361e1051c1cda405bc7cc",
            artifactSHA256: "d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed",
            inventorySHA256: "9f18359fe9a49c2b07f490154ca5771990432f34cc86aaf3e0ad5e85e485d0d3",
            manifestBytes: 21_308_856_601, manifestFileCount: 13, sourceBytes: 19_508_787_456,
            tensorCount: 1637, largestTensorBytes: 268_435_456, layers: 40, hidden: 2048,
            queryHeads: 16, linearValueHeads: 32, namedStateBytes: 558_344_232,
            kvHeads: 2, routedExperts: .init(experts: 256, expertsPerToken: 8,
                                             expertIntermediate: 512, sharedIntermediate: 512),
            unownedUInt8Tensors: true),
        // Ternary Bonsai 2 27B, catalog `ternary-bonsai-2-27b` 2026-09-17-r1: the
        // 27B's geometry as a Prism Hadamard pack in one safetensors file.
        // 1,655 canonical text tensors; the 402 transform-sign tensors stored
        // beside the packed modules (11,640,832 bytes) are checked against
        // the artifact's `hadamard.json` by the loader and are not among them.
        // The state estimate already counts four bytes per element, which is
        // what this pack's F32 keys, values and convolution state take.
        .init(model: .ternaryBonsai2TwentySevenB,
            configurationSHA256: "238de7c512cc56a733421e3fd011d88f8260739e3d00e32c5d65b7943cc9f837",
            manifestSHA256: "e6871c8df1f9d30895ff5caf84a40fe902cf8771cda56a2b9f087991ca34c1e4",
            artifactSHA256: "ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c",
            inventorySHA256: "64bbd7171cad459855fdb40d1f489d21c6ec6f5420e27cbdbd0d2aaea1830708",
            manifestBytes: 8_608_670_713, manifestFileCount: 8, sourceBytes: 7_662_073_856,
            tensorCount: 1655, largestTensorBytes: 317_849_600, layers: 64, hidden: 5120,
            queryHeads: 24, linearValueHeads: 48, namedStateBytes: 1_599_082_560),
    ]
}
