import Foundation

/// Closed retained identities, not a model registry or provider allowlist.
/// Its private initializer is used only by the closed catalog below.
struct QwenDenseRegisteredSpecification {
    let model: QwenRegisteredDenseModel
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String, inventorySHA256: String
    let manifestBytes: Int, manifestFileCount: Int, sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int
    let layers: Int, hidden: Int, queryHeads: Int, linearValueHeads: Int, namedStateBytes: Int

    private init(model: QwenRegisteredDenseModel, configurationSHA256: String, manifestSHA256: String,
                 artifactSHA256: String, inventorySHA256: String, manifestBytes: Int, manifestFileCount: Int,
                 sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int, layers: Int, hidden: Int,
                 queryHeads: Int, linearValueHeads: Int, namedStateBytes: Int) {
        self.model = model; self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.artifactSHA256 = artifactSHA256; self.inventorySHA256 = inventorySHA256; self.manifestBytes = manifestBytes
        self.manifestFileCount = manifestFileCount; self.sourceBytes = sourceBytes; self.tensorCount = tensorCount
        self.largestTensorBytes = largestTensorBytes; self.layers = layers; self.hidden = hidden
        self.queryHeads = queryHeads; self.linearValueHeads = linearValueHeads; self.namedStateBytes = namedStateBytes
    }
    func expectedGeometry() throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: layers, fullAttentionInterval: 4, hiddenSize: hidden, queryHeads: queryHeads,
            kvHeads: 4, headDimension: 256, linearKeyHeads: 16, linearValueHeads: linearValueHeads,
            linearKeyDimension: 128, linearValueDimension: 128, convolutionKernel: 4)
    }
    static let all: [Self] = [
        .init(model: .qwen35NineB,
            configurationSHA256: "c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423",
            manifestSHA256: "4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4",
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
    ]
}
