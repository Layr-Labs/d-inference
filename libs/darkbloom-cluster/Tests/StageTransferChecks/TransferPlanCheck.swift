import Foundation

/// The active inventories a registered model's stages have at one cut, rebuilt
/// from retained metadata the way the loader orders them: by local name.
func retainedDeliveredStages(_ profile: RetainedQwenInputs.Profile, cut: Int, layers: Int,
                             stages: [Int]) throws -> [QwenStageTransferPlan.DeliveredStage] {
    let plan = try QwenLayerStagePlan(configuration: profile.configuration, ranges: [0..<cut, cut..<layers])
    let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
    let parameters = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
    return try stages.map { stage in
        .init(stageIndex: stage, active: try parameters.filter { $0.stage == stage }
            .sorted { $0.localName < $1.localName }.map { parameter in
                guard let tensor = tensors[parameter.sourceName],
                      let dtype = QwenStageStoredDType(rawValue: tensor.sourceDType) else {
                    throw ProbeError("Retained tensor missing: " + parameter.sourceName)
                }
                return QwenStageActiveTensor(sourceName: parameter.sourceName, localName: parameter.localName,
                    shape: tensor.shape, sourceDType: dtype.nativeName,
                    loadedDType: (dtype == .float16 ? .bfloat16 : dtype).nativeName, byteCount: tensor.byteCount)
            })
    }
}

func checkTransferPlan(_ inputs: RetainedQwenInputs, _ checks: StageTransferChecks) throws {
    try checkRowSplit(checks)
    try checkRegisteredPlanGoldens(inputs, checks)
    try checkPlanStructure(inputs, checks)
    try checkPlanRefusals(checks)
}

private func checkRowSplit(_ checks: StageTransferChecks) throws {
    let limit = QwenStageTransferLimits.proposed.pieceByteLimit
    func split(_ rows: Int, _ rowBytes: Int, _ limit: Int) throws -> [Int] {
        let split = try QwenStageTransferPlan.RowSplit(rows: rows, rowBytes: rowBytes, pieceByteLimit: limit)
        return (0..<split.pieceCount).map(split.rows)
    }
    try checks.require("a tensor at the piece limit is one message",
        try split(4096, 2048, limit) == [4096] && split(1, limit, limit) == [1])
    // U32 [248320, 512]: 61 pieces, which 248,320 rows cannot divide evenly.
    try checks.require("the largest 9B tensor splits into the fewest balanced row-aligned pieces",
        try split(248_320, 2048, limit) == Array(repeating: 4071, count: 50) + Array(repeating: 4070, count: 11))
    // U32 [4096, 1536] is 24 MiB, three pieces by bytes, but 1,365 whole rows fit in a piece.
    try checks.require("row alignment costs mlp.down_proj.weight a fourth piece",
        try split(4096, 6144, limit) == [1024, 1024, 1024, 1024])
    try checks.require("tensors that divide evenly split into equal pieces",
        try split(12_288, 2048, limit) == [4096, 4096, 4096] && split(248_320, 128, limit) == Array(repeating: 62_080, count: 4)
        && split(8192, 2048, limit) == [4096, 4096] && split(10, 16, 48) == [3, 3, 2, 2])
    try checks.refuses("a row larger than a piece", because: "single row exceeds the piece limit") {
        _ = try split(4, limit + 4, limit)
    }
}

/// Goldens for the registered 9B: tensor and byte counts are the design's
/// table; piece and window counts were computed outside Swift from the same
/// retained metadata.
private func checkRegisteredPlanGoldens(_ inputs: RetainedQwenInputs, _ checks: StageTransferChecks) throws {
    struct Golden { let cut: Int; let stages: [Int]; let tensors: Int, bytes: Int, pieces: Int, windows: Int }
    let goldens = [
        Golden(cut: 4, stages: [0], tensors: 118, bytes: 1_058_851_136, pieces: 216, windows: 17),
        Golden(cut: 4, stages: [1], tensors: 809, bytes: 3_979_190_464, pieces: 1099, windows: 62),
        Golden(cut: 8, stages: [0], tensors: 233, bytes: 1_545_572_992, pieces: 363, windows: 24),
        Golden(cut: 8, stages: [1], tensors: 694, bytes: 3_492_468_608, pieces: 952, windows: 55),
        Golden(cut: 12, stages: [0], tensors: 348, bytes: 2_032_294_848, pieces: 510, windows: 32),
        Golden(cut: 12, stages: [1], tensors: 579, bytes: 3_005_746_752, pieces: 805, windows: 47),
        Golden(cut: 16, stages: [0], tensors: 463, bytes: 2_519_016_704, pieces: 657, windows: 40),
        Golden(cut: 16, stages: [1], tensors: 464, bytes: 2_519_024_896, pieces: 658, windows: 40),
        // A rank that holds both stages is delivered the whole model.
        Golden(cut: 4, stages: [0, 1], tensors: 927, bytes: 5_038_041_600, pieces: 1315, windows: 79),
        Golden(cut: 16, stages: [0, 1], tensors: 927, bytes: 5_038_041_600, pieces: 1315, windows: 79),
    ]
    for golden in goldens {
        let plan = try QwenStageTransferPlan(stages: retainedDeliveredStages(inputs.nine, cut: golden.cut, layers: 32,
            stages: golden.stages), limits: .proposed)
        try checks.require("9B cut \(golden.cut) stages \(golden.stages) plan matches its goldens",
            plan.tensors.count == golden.tensors && plan.payloadBytes == golden.bytes
            && plan.pieces.count == golden.pieces && plan.windows.count == golden.windows
            && plan.budgetNanoseconds == 5_000_000_000 + UInt64(golden.bytes))
    }
    let stage1 = try retainedDeliveredStages(inputs.nine, cut: 4, layers: 32, stages: [1])
    // 1,071 pieces by bytes alone, plus one for each of the 28 mlp.down_proj.weight tensors.
    try checks.require("cut 4 stage 1 is 1,071 pieces by bytes plus 28 from row alignment",
        stage1[0].active.reduce(0) { $0 + ($1.byteCount + 8_388_607) / 8_388_608 } == 1071
        && stage1[0].active.filter { $0.sourceName.hasSuffix("mlp.down_proj.weight") }.count == 28)
    let sixteen = try QwenStageTransferPlan(stages: stage1,
        limits: .init(pieceByteLimit: 16 * 1024 * 1024, windowByteLimit: 64 * 1024 * 1024, windowPieceLimit: 64))
    let single = try QwenStageTransferPlan(stages: stage1,
        limits: .init(pieceByteLimit: 8 * 1024 * 1024, windowByteLimit: 8 * 1024 * 1024, windowPieceLimit: 1))
    try checks.require("cut 4 stage 1 is 925 pieces at 16 MiB, and one window per piece when windows hold one",
        sixteen.pieces.count == 925 && sixteen.windows.count == 65
        && single.pieces.count == 1099 && single.windows.count == 1099)
}

private func checkPlanStructure(_ inputs: RetainedQwenInputs, _ checks: StageTransferChecks) throws {
    let stages = try retainedDeliveredStages(inputs.nine, cut: 4, layers: 32, stages: [0, 1])
    let limits = QwenStageTransferLimits.proposed
    let plan = try QwenStageTransferPlan(stages: stages, limits: limits)
    let active = stages.flatMap(\.active)
    try checks.require("tensors follow the delivered stages' active order with their real shapes and dtypes",
        plan.tensors.map(\.sourceName) == active.map(\.sourceName)
        && plan.tensors.map(\.localName) == active.map(\.localName)
        && plan.tensors.map(\.shape) == active.map(\.shape)
        && plan.tensors.map(\.dtype.nativeName) == active.map(\.sourceDType)
        && plan.tensors.map(\.stageIndex) == Array(repeating: 0, count: 118) + Array(repeating: 1, count: 809))
    var next = 0, whole = true, rowAligned = true
    for (index, tensor) in plan.tensors.enumerated() {
        let pieces = plan.pieces[tensor.pieces]
        whole = whole && tensor.pieces.lowerBound == next && !pieces.isEmpty
            && pieces.allSatisfy { $0.tensor == index && $0.dtype == tensor.dtype && $0.byteCount <= limits.pieceByteLimit }
            && pieces.reduce(0) { $0 + $1.byteCount } == tensor.byteCount
            && zip(pieces, pieces.dropFirst()).allSatisfy { $0.byteOffset + $0.byteCount == $1.byteOffset }
            && pieces.first?.byteOffset == 0
        rowAligned = rowAligned && pieces.allSatisfy { Array($0.shape.dropFirst()) == Array(tensor.shape.dropFirst()) }
            && pieces.reduce(0) { $0 + $1.shape[0] } == tensor.shape[0]
            && (tensor.byteCount > limits.pieceByteLimit || (pieces.count == 1 && pieces.first?.shape == tensor.shape))
        next = tensor.pieces.upperBound
    }
    try checks.require("pieces cover every tensor once, in order, within the piece limit",
        whole && next == plan.pieces.count && plan.pieces.enumerated().allSatisfy { $0.offset == $0.element.index })
    try checks.require("a split keeps trailing dimensions and whole rows; an unsplit tensor keeps its shape", rowAligned)
    var cursor = 0, bytes = 0, bounded = true, longest = true
    for window in plan.windows {
        let size = plan.pieces[window.pieces].reduce(0) { $0 + $1.byteCount }
        bounded = bounded && window.pieces.lowerBound == cursor && !window.pieces.isEmpty
            && window.precedingBytes == bytes && window.byteCount == size
            && size <= limits.windowByteLimit && window.pieces.count <= limits.windowPieceLimit
        // The longest run: the piece after a window would not have fitted in it.
        if window.pieces.upperBound < plan.pieces.count {
            longest = longest && (window.pieces.count == limits.windowPieceLimit
                || size + plan.pieces[window.pieces.upperBound].byteCount > limits.windowByteLimit)
        }
        cursor = window.pieces.upperBound; bytes += size
    }
    try checks.require("windows partition the pieces within both window limits",
        bounded && cursor == plan.pieces.count && bytes == plan.payloadBytes)
    try checks.require("each window is the longest run that fits", longest)

    let again = try QwenStageTransferPlan(stages: stages, limits: limits)
    let smaller = try QwenStageTransferPlan(stages: stages,
        limits: .init(pieceByteLimit: 4 * 1024 * 1024, windowByteLimit: 64 * 1024 * 1024, windowPieceLimit: 64))
    let other = try QwenStageTransferPlan(stages: retainedDeliveredStages(inputs.nine, cut: 8, layers: 32, stages: [0, 1]),
        limits: limits)
    var renamed = stages
    let entry = renamed[1].active[5]
    renamed[1] = .init(stageIndex: 1, active: Array(renamed[1].active[..<5]) + [QwenStageActiveTensor(
        sourceName: entry.sourceName, localName: entry.localName, shape: entry.shape, sourceDType: entry.sourceDType,
        loadedDType: "float32", byteCount: entry.byteCount)] + Array(renamed[1].active[6...]))
    try checks.require("both ranks compute one plan fingerprint; limits, cut or any active field change it",
        again == plan && again.fingerprint == plan.fingerprint && QwenDenseProfileIdentity.isSHA256(plan.fingerprint)
        && smaller.fingerprint != plan.fingerprint && other.fingerprint != plan.fingerprint
        && (try QwenStageTransferPlan(stages: renamed, limits: limits)).fingerprint != plan.fingerprint)
    // One piece is one aligned read of the sender's verified descriptor.
    try checks.require("proposed limits are 8 MiB pieces in windows of 64 MiB and 64 pieces",
        limits.pieceByteLimit == 8_388_608 && limits.windowByteLimit == 67_108_864 && limits.windowPieceLimit == 64
        && limits.pieceByteLimit == CheckpointAlignedReadPlan.maximumScratchRequestBytes
        && limits == (try QwenStageTransferLimits(pieceByteLimit: 8_388_608, windowByteLimit: 67_108_864, windowPieceLimit: 64)))
}

private func checkPlanRefusals(_ checks: StageTransferChecks) throws {
    func tensor(_ name: String, local: String? = nil, shape: [Int] = [2, 2], dtype: String = "uint32",
                bytes: Int? = nil) -> QwenStageActiveTensor {
        QwenStageActiveTensor(sourceName: name, localName: local ?? name, shape: shape, sourceDType: dtype,
            loadedDType: dtype, byteCount: bytes ?? shape.reduce(dtype == "uint32" || dtype == "float32" ? 4 : 2, *))
    }
    func plan(_ stages: [(Int, [QwenStageActiveTensor])], piece: Int = 64) throws {
        _ = try QwenStageTransferPlan(stages: stages.map { .init(stageIndex: $0.0, active: $0.1) },
            limits: .init(pieceByteLimit: piece, windowByteLimit: 128, windowPieceLimit: 4))
    }
    try plan([(0, [tensor("a")]), (1, [tensor("b")])])
    let order = "one or both stages, each once, in stage order"
    try checks.refuses("no delivered stage", because: order) { try plan([]) }
    try checks.refuses("three delivered stages", because: order) {
        try plan([(0, [tensor("a")]), (1, [tensor("b")]), (1, [tensor("c")])])
    }
    try checks.refuses("stage index outside the pair", because: order) { try plan([(2, [tensor("a")])]) }
    try checks.refuses("stages out of order", because: order) { try plan([(1, [tensor("b")]), (0, [tensor("a")])]) }
    try checks.refuses("one stage delivered twice", because: order) { try plan([(1, [tensor("a")]), (1, [tensor("b")])]) }
    try checks.refuses("stage with no active tensor", because: "empty or repeats a local name") { try plan([(0, [])]) }
    try checks.refuses("local name repeated in a stage", because: "empty or repeats a local name") {
        try plan([(0, [tensor("a", local: "x"), tensor("b", local: "x")])])
    }
    try checks.refuses("source tensor delivered in both stages", because: "delivers a source tensor twice") {
        try plan([(0, [tensor("a")]), (1, [tensor("a")])])
    }
    let geometry = "unsupported dtype, shape or byte count"
    try checks.refuses("dtype the wire does not carry", because: geometry) {
        try plan([(0, [tensor("a", dtype: "int64", bytes: 16)])])
    }
    try checks.refuses("safetensors spelling where the native dtype is expected", because: geometry) {
        try plan([(0, [tensor("a", dtype: "U32", bytes: 16)])])
    }
    try checks.refuses("planned byte count that disagrees with shape and dtype", because: geometry) {
        try plan([(0, [tensor("a", bytes: 12)])])
    }
    try checks.refuses("planned zero dimension", because: geometry) { try plan([(0, [tensor("a", shape: [0, 2], bytes: 0)])]) }
    try checks.refuses("scalar with no axis to split", because: geometry) { try plan([(0, [tensor("a", shape: [], bytes: 4)])]) }
    try checks.refuses("planned five dimensions", because: geometry) { try plan([(0, [tensor("a", shape: [1, 1, 1, 1, 1])])]) }
    try checks.refuses("dimension above the C Int range", because: geometry) {
        try plan([(0, [tensor("a", shape: [Int(Int32.max) + 1], dtype: "float32")])])
    }
    try checks.refuses("tensor whose row exceeds the piece limit", because: "single row exceeds the piece limit") {
        try plan([(0, [tensor("a", shape: [2, 32])])])
    }
    try checks.refuses("more pieces than the piece limit", because: "exceeds its piece limit") {
        try plan([(0, [tensor("a", shape: [QwenStageTransferPlan.maximumPieceCount + 1], dtype: "float32")])], piece: 4)
    }
    try checks.refuses("more tensors than the tensor limit", because: "exceeds its tensor limit") {
        try plan([(0, (0...2048).map { tensor("a\($0)") }), (1, (0..<2048).map { tensor("b\($0)") })])
    }
    func limits(_ piece: Int, _ windowBytes: Int, _ windowPieces: Int) throws {
        _ = try QwenStageTransferLimits(pieceByteLimit: piece, windowByteLimit: windowBytes, windowPieceLimit: windowPieces)
    }
    try limits(16 * 1024 * 1024, 1024 * 1024 * 1024, 1024)
    try limits(1, 1, 1)
    let bounds = "outside its bounds"
    try checks.refuses("piece limit of zero", because: bounds) { try limits(0, 64, 4) }
    try checks.refuses("piece limit above the 16 MiB receive cap", because: bounds) {
        try limits(16 * 1024 * 1024 + 1, 64 * 1024 * 1024, 4)
    }
    try checks.refuses("window smaller than one piece", because: bounds) { try limits(64, 63, 4) }
    try checks.refuses("window byte limit above its bound", because: bounds) { try limits(64, 1024 * 1024 * 1024 + 1, 4) }
    try checks.refuses("window of no pieces", because: bounds) { try limits(64, 64, 0) }
    try checks.refuses("window piece limit above its bound", because: bounds) { try limits(64, 64, 1025) }
}
