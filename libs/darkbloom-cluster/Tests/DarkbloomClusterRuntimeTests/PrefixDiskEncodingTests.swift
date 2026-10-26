import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// Encoded SSD prefix records: eligibility per family, the row codec's round
// trip against the SDK's reference, shallower frontiers, the encoding bound
// into directory, header and load agreement, a root holding both encodings,
// GLM's layer caches through a record, refused corrupt records and the bytes
// saved at the beta models' shapes. CPU only: small arrays, no model; the
// agreement test exchanges over local sockets.

private let balancedQwen = QwenStagePrefixDiskEncoding(quantization: .balanced, family: .qwenAttention)

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-encoding-tests-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func configuration(_ root: URL) -> QwenStagePrefixDiskConfiguration {
    var value = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 5, count: 32)))
    value.strideTokens = 64; value.minimumTokens = 1; value.minimumFreeBytes = 1
    return value
}

/// Deterministic rows that look like attention history: per-channel scales
/// spanning two orders of magnitude, one strong outlier channel (what the key
/// rotation spreads), a slow drift along the tokens.
private func rows(heads: Int, tokens: Int, width: Int, seed: UInt64, dtype: DType) -> MLXArray {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
    }
    var values = [Float](repeating: 0, count: heads * tokens * width)
    for head in 0..<heads {
        for token in 0..<tokens {
            for channel in 0..<width {
                let scale: Float = channel == 7 ? 8 : (channel % 16 == 3 ? 2 : 0.25 + Float(channel % 5) * 0.1)
                values[(head * tokens + token) * width + channel] = scale * (next() + 0.3 * sin(Float(token) * 0.01 + Float(channel)))
            }
        }
    }
    let array = MLXArray(values).reshaped([1, heads, tokens, width]).asType(dtype)
    eval(array)
    return array
}

/// One prompt's captured states: attention at `committed` (views at the
/// grid frontiers, as a capture holds them) and recurrent state per frontier.
private func states(committed: Int, frontiers: [Int], heads: Int = 2, width: Int = 128, layers: [Int] = [3, 7],
                    dtype: DType = .bfloat16, seed: UInt64 = 1) -> [QwenStagePrefixState] {
    var full: [Int: (keys: MLXArray, values: MLXArray)] = [:]
    for layer in layers {
        full[layer] = (keys: rows(heads: heads, tokens: committed, width: width, seed: seed &+ UInt64(layer), dtype: dtype),
                       values: rows(heads: heads, tokens: committed, width: width, seed: seed &+ UInt64(layer) &+ 100, dtype: dtype))
    }
    return (frontiers + [committed]).map { f in
        let attention = f == committed ? full : full.mapValues {
            (keys: $0.keys[0..., 0..., 0..<f, 0...], values: $0.values[0..., 0..., 0..<f, 0...])
        }
        let conv = MLXArray((0..<24).map { Float($0 + f) * 0.5 }).reshaped([1, 3, 8]).asType(.bfloat16)
        let ssm = MLXArray((0..<32).map { Float($0 * f) * 0.001 }).reshaped([1, 2, 4, 4])
        return QwenStagePrefixState(committedTokens: f, attention: attention, recurrent: [0: (conv: conv, ssm: ssm)])
    }
}

private func bytes(_ array: MLXArray) -> Data { eval(array); return array.asData(access: .copy).data }

private func floats(_ array: MLXArray) -> [Float] { array.asType(.float32).asArray(Float.self) }

/// A float32 value rounded to the native dtype's grid, back as float32.
private func native(_ value: Float, _ dtype: DType) -> Float {
    switch dtype {
    case .bfloat16:
        let raw = value.bitPattern
        return Float(bitPattern: ((raw &+ 0x7fff &+ ((raw >> 16) & 1)) >> 16) << 16)
    case .float16: return Float(Float16(value))
    default: return value
    }
}

/// What the SDK's scalar reference gives back for one native row: its
/// encoded bytes decoded in the original basis, rounded to the native dtype.
private func referenceRoundTrip(_ row: [Float], dtype: DType, key: Bool,
                                configuration: PagedKVQuantizationConfig) throws -> [Float] {
    let encoded = try PagedKVQuantizationReference.encode(row, config: configuration, isKey: key)
    return try PagedKVQuantizationReference.decode(encoded.bytes, headDim: row.count, config: configuration, isKey: key)
        .map { native($0, dtype) }
}

/// The 4-bit affine bound of one row: for a value row each element is within
/// half its group's step (plus the native rounding); for a key row the same
/// holds in the rotated basis, so the error of each rotation block, which the
/// normalized Hadamard transform preserves, is within the root sum of squares
/// of those half steps.
private func withinAffineBound(original: [Float], restored: [Float], dtype: DType, key: Bool,
                               configuration: PagedKVQuantizationConfig) -> Bool {
    let width = original.count, group = configuration.groupSize, levels = Float((1 << (key ? configuration.keyBits
        : configuration.valueBits)) - 1)
    let rotation = key ? configuration.resolvedRotationBlockSize(headDim: width) : 0
    let basis = key ? PagedKVQuantizationReference.rotate(original, blockSize: rotation) : original
    let halfSteps = stride(from: 0, to: width, by: group).flatMap { start -> [Float] in
        let slice = basis[start ..< start + group]
        return Array(repeating: (slice.max()! - slice.min()!) / levels / 2, count: group)
    }
    func roundingSlack(_ value: Float) -> Float {
        dtype == .float32 ? 1e-6 : abs(value) * (dtype == .bfloat16 ? 1 / 256 : 1 / 2048) + 1e-6
    }
    if !key {
        return original.indices.allSatisfy { abs(restored[$0] - original[$0]) <= halfSteps[$0] * 1.0001 + roundingSlack(restored[$0]) }
    }
    return stride(from: 0, to: width, by: rotation).allSatisfy { start in
        let block = start ..< start + rotation
        let error = block.reduce(Float(0)) { $0 + pow(restored[$1] - original[$1], 2) }.squareRoot()
        let bound = block.reduce(Float(0)) { $0 + halfSteps[$1] * halfSteps[$1] }.squareRoot() * 1.0001
            + block.reduce(Float(0)) { $0 + pow(roundingSlack(restored[$1]), 2) }.squareRoot()
        return error <= bound
    }
}

private func onCPU<R>(_ body: () throws -> R) rethrows -> R { try Device.withDefaultDevice(.cpu, body) }

private func recordURL(_ tier: QwenStagePrefixDiskTier) throws -> URL {
    let name = try #require(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).first { $0.hasSuffix(".dbpx") })
    return tier.directory.appendingPathComponent(name)
}

@Suite("Encoded prompt prefix SSD records", .serialized)
struct PrefixDiskEncodingTests {
    @Test func eligibilityIsDecidedPerFamilyInOnePlace() throws {
        let balanced = try #require(PagedKVQuantizationSelection.balanced.configuration)
        #expect(balanced.identity == "affine-v2-k4v4-g64-f32-h128-s1-r128")
        // Qwen: keys and values, any width the format encodes, the newest 128 rows native.
        let key = try #require(balancedQwen.rows(slot: "keys", width: 256, dtype: .bfloat16, committed: 4096))
        let value = try #require(balancedQwen.rows(slot: "values", width: 256, dtype: .bfloat16, committed: 4096))
        #expect(!key.values && value.values && key.nativeFrom == 3968 && value.nativeFrom == 3968)
        #expect(key.nativeRowBytes == 512 && key.encodedRowBytes == 128 + 4 * 4 + 4 * 4)
        #expect(balancedQwen.rows(slot: "keys", width: 256, dtype: .bfloat16, committed: 100)?.nativeFrom == 0)
        for (width, dtype) in [(8, DType.bfloat16), (96, .bfloat16), (576, .bfloat16), (640, .float32), (128, .int32)] {
            #expect(balancedQwen.rows(slot: "keys", width: width, dtype: dtype, committed: 4096) == nil, "\(width) \(dtype)")
        }
        #expect(balancedQwen.rows(slot: "conv", width: 128, dtype: .bfloat16, committed: 4096) == nil)
        // GLM: the DSA latents (keys slot) when the width is encodable; the index keys and gates never.
        let glm = QwenStagePrefixDiskEncoding(quantization: .balanced, family: .glm5NextDSA)
        #expect(glm.rows(slot: "keys", width: 512, dtype: .float32, committed: 8192)?.nativeFrom == 8064)
        #expect(glm.rows(slot: "keys", width: 512, dtype: .bfloat16, committed: 8192) != nil)
        #expect(glm.rows(slot: "values", width: 256, dtype: .bfloat16, committed: 8192) == nil)
        #expect(glm.rows(slot: "keys", width: 576, dtype: .bfloat16, committed: 8192) == nil)
        // Native, by selection or by family, encodes nothing and binds nothing.
        for encoding in [QwenStagePrefixDiskEncoding.native, .init(quantization: .native, family: .qwenAttention),
                         .init(quantization: .balanced, family: .native)] {
            #expect(encoding.configuration == nil && encoding.loadAgreementFields.isEmpty && encoding.planScopeSuffix.isEmpty
                && encoding.header == nil && encoding.description == "native")
            #expect(encoding.rows(slot: "keys", width: 256, dtype: .bfloat16, committed: 4096) == nil)
        }
        #expect(balancedQwen.loadAgreementFields == ["cluster-prefix-ssd-records-v1", "balanced", balanced.identity, "qwen-attention"])
        let k8v8 = QwenStagePrefixDiskEncoding(quantization: .k8v8, family: .qwenAttention)
        #expect(k8v8.loadAgreementFields != balancedQwen.loadAgreementFields && k8v8.planScopeSuffix != balancedQwen.planScopeSuffix)
        #expect(glm.loadAgreementFields != balancedQwen.loadAgreementFields)
        // The rows the layer-stage runtime serves.
        #expect(QwenStagePrefixDiskFamily.layerStage(runtimeModelID: "registered_qwen38_27b") == .qwenAttention)
        #expect(QwenStagePrefixDiskFamily.layerStage(runtimeModelID: "registered_qwen35_35b_a3b") == .qwenAttention)
        #expect(QwenStagePrefixDiskFamily.layerStage(runtimeModelID: "registered_nemotron35_lightning") == .native)
        #expect(QwenStagePrefixDiskFamily.layerStage(runtimeModelID: "registered_gemma4_26b_qat_4bit") == .native)
    }

    @Test func theRankParsesItsEncodingLikeMainsCheckpointPrecision() throws {
        let name = QwenStagePrefixDiskEncoding.environmentName
        #expect(name == "DARKBLOOM_CLUSTER_PREFIX_SSD_QUANTIZATION")
        #expect(try QwenStagePrefixDiskEncoding.fromEnvironment([:], family: .qwenAttention) == balancedQwen)
        #expect(try QwenStagePrefixDiskEncoding.fromEnvironment([name: " "], family: .qwenAttention) == balancedQwen)
        for (raw, selection) in [("native", PagedKVQuantizationSelection.native), ("off", .native), ("int4", .balanced),
                                 ("K8V8", .k8v8), ("int8", .k8v8), ("k8v4", .k8v4)] {
            #expect(try QwenStagePrefixDiskEncoding.fromEnvironment([name: raw], family: .glm5NextDSA)
                == .init(quantization: selection, family: .glm5NextDSA), "\(raw)")
        }
        for raw in ["k4v44", "invalid", "balanced;"] {
            #expect(throws: ProbeError.self) { _ = try QwenStagePrefixDiskEncoding.fromEnvironment([name: raw], family: .qwenAttention) }
        }
    }

    /// The load's first exchange over real local sockets, with the record
    /// encoding in each rank's agreement as the tensor-parallel load binds it:
    /// peers told different encodings refuse to load; native adds nothing.
    @Test func peersToldDifferentRecordEncodingsRefuseToLoad() throws {
        let base = ["fixture-plan-and-membership", "qwen-tensor-parallel-prefix-v2", "on"]
        func agreement(_ encoding: QwenStagePrefixDiskEncoding) throws -> String {
            sha256(try canonicalJSONData(base + encoding.loadAgreementFields))
        }
        #expect(try agreement(.init(quantization: .native, family: .qwenAttention)) == sha256(try canonicalJSONData(base)))
        func exchange(_ first: QwenStagePrefixDiskEncoding, _ second: QwenStagePrefixDiskEncoding) throws
            -> (Result<String, Error>, Result<String, Error>) {
            let fixture = try ResidualStreamCollectiveFixture()
            func agree(_ collective: Collective, _ encoding: QwenStagePrefixDiskEncoding) -> Result<String, Error> {
                Result {
                    let fingerprint = try agreement(encoding)
                    return try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: fingerprint) },
                        disagreementMessage: "Tensor-parallel load membership/source/plan/shares differ",
                        scope: .session(.loadAgreement, "resident-load-intent"), check: {})
                }
            }
            var rank0: Result<String, Error>?
            let rank1 = try fixture.exchange(send: { rank0 = agree(fixture.first, first) }, receive: { agree($0, second) })
            return (try #require(rank0), rank1)
        }
        let same = try exchange(balancedQwen, balancedQwen)
        #expect(try same.0.get() == same.1.get())
        for (first, second) in [(balancedQwen, QwenStagePrefixDiskEncoding(quantization: .native, family: .qwenAttention)),
                                (balancedQwen, .init(quantization: .k8v8, family: .qwenAttention))] {
            let mismatched = try exchange(first, second)
            for result in [mismatched.0, mismatched.1] {
                #expect(throws: ProbeError.self) { try result.get() }
            }
        }
    }

    /// The deepest frontier: older rows equal the SDK reference's round trip
    /// of each captured row and lie within the 4-bit affine bound; the newest
    /// 128 rows come back bit for bit; recurrent state is untouched.
    @Test func aRoundTripKeepsTheBandExactAndOlderRowsWithinTheAffineBound() throws {
        try onCPU {
            let profile = try #require(balancedQwen.configuration)
            for dtype in [DType.bfloat16, .float16, .float32] {
                let committed = 300
                let state = try #require(states(committed: committed, frontiers: [], dtype: dtype).last)
                let (measurement, restored) = try QwenStagePrefixDiskMeasurement.measure(state, encoding: balancedQwen, blockTokens: 64)
                #expect(measurement.entries.count == 4 && measurement.entries.allSatisfy { $0.encodedRows == committed - 128 && $0.bandExact })
                for (layer, pair) in state.attention {
                    let back = try #require(restored.attention[layer])
                    for (kind, original, decoded) in [("keys", pair.keys, back.keys), ("values", pair.values, back.values)] {
                        #expect(decoded.shape == original.shape && decoded.dtype == original.dtype)
                        let a = floats(original), b = floats(decoded), width = original.dim(3)
                        for head in 0..<original.dim(1) {
                            for token in [0, 1, 63, 64, 171] {
                                let start = (head * committed + token) * width
                                let row = Array(a[start ..< start + width]), got = Array(b[start ..< start + width])
                                #expect(got == (try referenceRoundTrip(row, dtype: dtype, key: kind == "keys", configuration: profile)),
                                    "\(dtype) \(kind) head \(head) token \(token)")
                                #expect(withinAffineBound(original: row, restored: got, dtype: dtype, key: kind == "keys",
                                    configuration: profile), "\(dtype) \(kind) head \(head) token \(token) outside the bound")
                            }
                        }
                        #expect(bytes(decoded[0..., 0..., 172..., 0...]) == bytes(original[0..., 0..., 172..., 0...]))
                        #expect(bytes(decoded[0..., 0..., ..<172, 0...]) != bytes(original[0..., 0..., ..<172, 0...]))
                    }
                }
                #expect(bytes(restored.recurrent[0]!.conv) == bytes(state.recurrent[0]!.conv)
                    && bytes(restored.recurrent[0]!.ssm) == bytes(state.recurrent[0]!.ssm))
                let keys = try #require(measurement.maxAbsError(kind: "keys")), values = try #require(measurement.maxAbsError(kind: "values"))
                #expect(keys > 0 && values > 0 && measurement.entries.allSatisfy { $0.maxAbsError < 0.25 * $0.maxAbsValue })
            }
        }
    }

    /// Records serve every kept frontier: frontier `f` reads rows `[0, f)`,
    /// approximate below the record's band and exact inside it; only the
    /// deepest frontier is guaranteed its exact newest rows.
    @Test func shallowerFrontiersReadApproximateRowsAndTheDeepestTheExactBand() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let committed = 300, tokens = Array(1000..<1301), band = committed - 128
            let captured = states(committed: committed, frontiers: [64, 128, 192, 256])
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            tier.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(tier.drain(timeoutSeconds: 60) && tier.recordCount == 1)
            let opened = try QwenStagePrefixDiskIO.open(url: try recordURL(tier), keys: tier.keys)
            #expect(opened.header.encoding == balancedQwen.header && opened.header.attention.allSatisfy { $0.nativeFrom == band })
            #expect(tier.frontiers(scope: "s", tokens: tokens, maximumFrontier: committed) == [300, 256, 192, 128, 64])
            let deepest = captured.last!
            for frontier in [300, 256, 192, 128, 64] {
                let restored = try #require(try tier.restore(scope: "s", tokens: tokens, frontier: frontier, check: {}))
                let original = captured.first { $0.committedTokens == frontier }!
                #expect(restored.committedTokens == frontier)
                for (layer, pair) in restored.attention {
                    for (decoded, source) in [(pair.keys, deepest.attention[layer]!.keys), (pair.values, deepest.attention[layer]!.values)] {
                        #expect(decoded.shape == [1, 2, frontier, 128])
                        let encoded = min(frontier, band)
                        if frontier > band {
                            #expect(bytes(decoded[0..., 0..., band..., 0...]) == bytes(source[0..., 0..., band ..< frontier, 0...]))
                        }
                        #expect(bytes(decoded[0..., 0..., ..<encoded, 0...]) != bytes(source[0..., 0..., ..<encoded, 0...]))
                    }
                }
                // The same older rows at every frontier: one encoded copy serves them all.
                let deepestRestore = try #require(try tier.restore(scope: "s", tokens: tokens, frontier: 300, check: {}))
                let shared = min(frontier, band)
                #expect(bytes(restored.attention[3]!.keys[0..., 0..., ..<shared, 0...])
                    == bytes(deepestRestore.attention[3]!.keys[0..., 0..., ..<shared, 0...]))
                #expect(bytes(restored.recurrent[0]!.conv) == bytes(original.recurrent[0]!.conv)
                    && bytes(restored.recurrent[0]!.ssm) == bytes(original.recurrent[0]!.ssm))
            }
            tier.close()
        }
    }

    /// A record written under one encoding is never restored under another:
    /// the encodings use different directories, a record moved into the
    /// other's directory is swept at load, and a restore of one under another
    /// encoding is refused; the load agreement binds the encoding.
    @Test func aRecordOfOneEncodingIsNeverRestoredUnderAnother() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let tokens = Array(0..<301), captured = states(committed: 300, frontiers: [])
            let balanced = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            let exact = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: .init(quantization: .native, family: .qwenAttention)))
            #expect(balanced.planDirectory != exact.planDirectory)
            #expect(exact.planDirectory.lastPathComponent == QwenStagePrefixDiskTier.planDirectoryName(scope: "plan"))
            balanced.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(balanced.drain(timeoutSeconds: 60) && balanced.recordCount == 1)
            #expect(exact.frontiers(scope: "s", tokens: tokens, maximumFrontier: 300).isEmpty)
            exact.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(exact.drain(timeoutSeconds: 60) && exact.recordCount == 1)
            let approximate = try #require(try balanced.restore(scope: "s", tokens: tokens, frontier: 300, check: {}))
            let precise = try #require(try exact.restore(scope: "s", tokens: tokens, frontier: 300, check: {}))
            #expect(bytes(precise.attention[3]!.keys) == bytes(captured[0].attention[3]!.keys))
            #expect(bytes(approximate.attention[3]!.keys) != bytes(captured[0].attention[3]!.keys))
            // The sealed header refuses a restore under another encoding.
            let encodedURL = try recordURL(balanced)
            let opened = try QwenStagePrefixDiskIO.open(url: encodedURL, keys: balanced.keys)
            for other in [QwenStagePrefixDiskEncoding.native, .init(quantization: .k8v8, family: .qwenAttention),
                          .init(quantization: .balanced, family: .glm5NextDSA)] {
                #expect(throws: ProbeError.self) {
                    _ = try QwenStagePrefixDiskIO.restore(url: encodedURL, opened: opened, frontier: 300, encoding: other, check: {})
                }
            }
            // A balanced record moved into the native tier's directory is never offered and goes at load.
            exact.close(); balanced.close()
            let moved = exact.directory.appendingPathComponent(encodedURL.lastPathComponent)
            try? FileManager.default.removeItem(at: moved)
            try FileManager.default.copyItem(at: encodedURL, to: moved)
            let reopened = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: .init(quantization: .native, family: .qwenAttention)))
            #expect(reopened.stats.sweptFiles == 1 && reopened.recordCount == 0 && !FileManager.default.fileExists(atPath: moved.path))
            reopened.close()
        }
    }

    /// One root keeps both encodings' records side by side, inside one budget:
    /// switching the encoding leaves the other's live records for a switch back.
    @Test func aRootHoldsBothEncodingsSideBySide() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let tokens = Array(500..<801), captured = states(committed: 300, frontiers: [128])
            let first = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            first.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(first.drain(timeoutSeconds: 60) && first.recordCount == 1)
            let encodedBytes = first.stats.persistedBytes
            first.close()
            let native = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: .native))
            #expect(native.stats.keptOtherRecords == 1 && native.stats.sweptPlans == 0 && native.recordCount == 0)
            native.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(native.drain(timeoutSeconds: 60) && native.recordCount == 1)
            #expect(native.stats.persistedBytes > encodedBytes)
            native.close()
            let plans = try FileManager.default.contentsOfDirectory(atPath: root.path).filter(QwenStagePrefixDiskTier.isPlanDirectoryName)
            #expect(plans.count == 2)
            let back = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            #expect(back.recordCount == 1 && back.stats.keptOtherRecords == 1)
            #expect(back.frontiers(scope: "s", tokens: tokens, maximumFrontier: 300) == [300, 128])
            #expect(try back.restore(scope: "s", tokens: tokens, frontier: 128, check: {}) != nil)
            back.close()
        }
    }

    /// GLM-5.3-Flash's layer caches (the pipeline's capture of a DSA layer of
    /// 512-wide BF16 latents and 128-wide index keys and pool gates, and a KDA
    /// layer) through a balanced record into fresh caches at every kept
    /// frontier: only the latents below the record's band are approximate
    /// (the SDK reference's round trip of each row); the band, the index
    /// keys, the pool gates, the validity and the KDA state are bit for bit.
    @Test func glmRecordsRestoreIntoFreshCachesWithOnlyOlderLatentsApproximate() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let glm = QwenStagePrefixDiskEncoding(quantization: .balanced, family: .glm5NextDSA)
            let profile = try #require(glm.configuration)
            let committed = 320, band = committed - 128, tokens = Array(7000 ... 7000 + committed)
            func dsa(_ count: Int) -> GLM5NextDSACache {
                let cache = GLM5NextDSACache()
                cache.state = [rows(heads: 1, tokens: count, width: 512, seed: 41, dtype: .bfloat16).reshaped([1, count, 512]),
                               rows(heads: 1, tokens: count, width: 128, seed: 42, dtype: .bfloat16).reshaped([1, count, 128]),
                               rows(heads: 1, tokens: count, width: 128, seed: 43, dtype: .bfloat16).reshaped([1, count, 128]),
                               MLXArray.ones([1, count], dtype: .bool)]
                return cache
            }
            func kda(_ count: Int) -> GLM5NextKDACache {
                let cache = GLM5NextKDACache()
                cache.state = [MLXArray((0..<24).map { Float($0 + count) * 0.5 }).reshaped([1, 3, 8]).asType(.bfloat16),
                               MLXArray((0..<32).map { Float($0 * count) * 0.001 }).reshaped([1, 2, 4, 4])]
                cache.metaState = ["glm5_kda_v1", String(count)]
                return cache
            }
            // One generator per history, so the shallower capture's rows are the deeper one's prefix.
            let captured: [(frontier: Int, layers: [any KVCache])] = [192, committed].map { ($0, [kda($0), dsa($0)]) }
            let capture = ClusterStagePrefixCapture.glm5Next(frontiers: [192, committed])
            for (frontier, layers) in captured { try capture.capture(at: frontier, caches: layers, globalLayers: [0, 1]) }
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "glm-plan",
                rank: 0, encoding: glm))
            tier.persist(scope: "s", tokens: tokens, states: capture.states(), blockTokens: 64)
            #expect(tier.drain(timeoutSeconds: 60) && tier.recordCount == 1)
            let opened = try QwenStagePrefixDiskIO.open(url: try recordURL(tier), keys: tier.keys)
            #expect(opened.header.encoding == glm.header && opened.header.attention.map(\.nativeFrom) == [band, nil])
            #expect(tier.frontiers(scope: "s", tokens: tokens, maximumFrontier: committed) == [committed, 192])
            for (frontier, original) in captured {
                let state = try #require(try tier.restore(scope: "s", tokens: tokens, frontier: frontier, check: {}))
                let fresh: [any KVCache] = [GLM5NextKDACache(), GLM5NextDSACache()]
                try GLM5NextStagePrefixSnapshot.restore(state, into: fresh, globalLayers: [0, 1])
                #expect(fresh.allSatisfy { $0.offset == frontier })
                for (a, b) in zip(original[0].state, fresh[0].state) { #expect(bytes(a) == bytes(b), "KDA at \(frontier)") }
                for slot in 1...3 {
                    #expect(bytes(original[1].state[slot]) == bytes(fresh[1].state[slot]), "DSA history \(slot) at \(frontier)")
                }
                let latents = original[1].state[0], restored = fresh[1].state[0], encoded = min(frontier, band)
                #expect(restored.shape == latents.shape && restored.dtype == latents.dtype)
                #expect(bytes(restored[0..., ..<encoded, 0...]) != bytes(latents[0..., ..<encoded, 0...]))
                if frontier > band { #expect(bytes(restored[0..., band..., 0...]) == bytes(latents[0..., band..., 0...])) }
                let a = floats(latents), b = floats(restored)
                for token in [0, 63, 64, encoded - 1] {
                    let row = Array(a[token * 512 ..< (token + 1) * 512]), got = Array(b[token * 512 ..< (token + 1) * 512])
                    #expect(got == (try referenceRoundTrip(row, dtype: .bfloat16, key: true, configuration: profile)),
                        "latents token \(token) at \(frontier)")
                    #expect(withinAffineBound(original: row, restored: got, dtype: .bfloat16, key: true, configuration: profile),
                        "latents token \(token) at \(frontier) outside the bound")
                }
            }
            tier.close()
        }
    }

    /// A changed byte, a truncated file, or authenticated rows the decoder
    /// refuses: the record is absent and deleted, never adopted.
    @Test func corruptOrTruncatedEncodedRecordsAreRefused() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let captured = states(committed: 300, frontiers: [])
            func written(_ tokens: [Int]) throws -> (QwenStagePrefixDiskTier, URL) {
                let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                    rank: 0, encoding: balancedQwen))
                tier.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
                #expect(tier.drain(timeoutSeconds: 60))
                return (tier, try recordURL(tier))
            }
            // One changed ciphertext byte inside an encoded unit.
            do {
                let tokens = Array(0..<301)
                let (tier, url) = try written(tokens)
                let opened = try QwenStagePrefixDiskIO.open(url: url, keys: tier.keys)
                let unit = opened.header.attention[0].units[0]
                let handle = try FileHandle(forUpdating: url)
                try handle.seek(toOffset: UInt64(opened.dataStart + unit.offset + 5))
                let byte = try #require(try handle.read(upToCount: 1))
                try handle.seek(toOffset: UInt64(opened.dataStart + unit.offset + 5))
                try handle.write(contentsOf: Data([byte[0] ^ 0x40])); try handle.close()
                #expect(try tier.restore(scope: "s", tokens: tokens, frontier: 300, check: {}) == nil)
                #expect(!FileManager.default.fileExists(atPath: url.path) && tier.stats.failedRestores == 1)
                tier.close()
            }
            // A file one byte short.
            do {
                let tokens = Array(1000..<1301)
                let (tier, url) = try written(tokens)
                let handle = try FileHandle(forUpdating: url)
                try handle.truncate(atOffset: try handle.seekToEnd() - 1); try handle.close()
                #expect(try tier.restore(scope: "s", tokens: tokens, frontier: 300, check: {}) == nil)
                #expect(!FileManager.default.fileExists(atPath: url.path))
                tier.close()
            }
            // Authenticated, but a scale the codec never writes (NaN): the decoder refuses the row.
            do {
                let tokens = Array(2000..<2301)
                let (tier, url) = try written(tokens)
                let opened = try QwenStagePrefixDiskIO.open(url: url, keys: tier.keys)
                let item = opened.header.attention[0], unit = item.units[0]
                let handle = try FileHandle(forUpdating: url)
                try handle.seek(toOffset: UInt64(opened.dataStart + unit.offset))
                let sealed = try #require(try handle.read(upToCount: unit.length))
                let nonce = try QwenStagePrefixDiskFormat.unitNonce(unit.index)
                var plain = try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.prefix(unit.length - 16),
                    tag: sealed.suffix(16)), using: opened.key)
                // Row 0 of head 0 is encoded: its first scale follows its 4-bit codes.
                var nan = Float.nan.bitPattern.littleEndian
                withUnsafeBytes(of: &nan) { plain.replaceSubrange(item.headDim / 2 ..< item.headDim / 2 + 4, with: $0) }
                let box = try AES.GCM.seal(plain, using: opened.key, nonce: nonce)
                try handle.seek(toOffset: UInt64(opened.dataStart + unit.offset))
                try handle.write(contentsOf: box.ciphertext + box.tag); try handle.close()
                #expect(try tier.restore(scope: "s", tokens: tokens, frontier: 300, check: {}) == nil)
                #expect(!FileManager.default.fileExists(atPath: url.path))
                tier.close()
            }
            // A truncated record found at load is swept.
            do {
                let tokens = Array(3000..<3301)
                let (tier, url) = try written(tokens)
                tier.close()
                let handle = try FileHandle(forUpdating: url)
                try handle.truncate(atOffset: 100); try handle.close()
                let reopened = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                    rank: 0, encoding: balancedQwen))
                #expect(reopened.frontiers(scope: "s", tokens: tokens, maximumFrontier: 300).isEmpty
                    && !FileManager.default.fileExists(atPath: url.path))
                reopened.close()
            }
        }
    }

    /// A row the codec cannot encode (non-finite) is never persisted: the
    /// record is dropped and nothing is offered.
    @Test func aRowTheCodecRefusesDropsTheRecord() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var captured = states(committed: 300, frontiers: [])
            let poisoned = captured[0].attention[3]!.keys
            let patched = which(MLXArray(0..<300).reshaped([1, 1, 300, 1]) .== 5, MLXArray(Float.nan).asType(poisoned.dtype), poisoned)
            eval(patched)
            captured[0] = QwenStagePrefixState(committedTokens: 300,
                attention: captured[0].attention.merging([3: (keys: patched, values: captured[0].attention[3]!.values)]) { $1 },
                recurrent: captured[0].recurrent)
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            let tokens = Array(0..<301)
            tier.persist(scope: "s", tokens: tokens, states: captured, blockTokens: 64)
            #expect(tier.drain(timeoutSeconds: 60))
            #expect(tier.recordCount == 0 && tier.stats.droppedPersists == 1 && tier.frontiers(scope: "s", tokens: tokens,
                maximumFrontier: 300).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).filter { $0.hasSuffix(".dbpx") }.isEmpty)
            tier.close()
        }
    }

    /// Opt-in timing (`PREFIX_RECORD_ENCODE_BENCH=1`): one Qwen 3.8 27B
    /// tensor-parallel rank's full-attention layer at 32,768 tokens (two
    /// key/value heads of 256, BF16) encoded unit by unit on one thread, then
    /// written by the tier (its encoding writers) and restored.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PREFIX_RECORD_ENCODE_BENCH"] == "1"))
    func encodingThroughputAtTheBetaShape() throws {
        try onCPU {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let committed = 32_768
            let state = try #require(states(committed: committed, frontiers: [], heads: 2, width: 256, layers: [3]).last)
            let rows = Double(2 * 2 * committed)
            let job = try QwenStagePrefixDiskJob.prepare(scope: "s", recordKey: "r", fileName: "f", rank: 0, deepest: state,
                frontiers: [(state, "k")], blockTokens: 4096, encoding: balancedQwen)
            var started = DispatchTime.now().uptimeNanoseconds
            for (entry, item) in job.header.attention.enumerated() {
                for block in item.units.indices { _ = try job.attentionPlaintext(entry: entry, block: block) }
            }
            let single = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan",
                rank: 0, encoding: balancedQwen))
            let tokens = Array(0 ..< committed + 1)
            started = DispatchTime.now().uptimeNanoseconds
            tier.persist(scope: "s", tokens: tokens, states: [state], blockTokens: 4096)
            #expect(tier.drain(timeoutSeconds: 600) && tier.recordCount == 1)
            let written = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            started = DispatchTime.now().uptimeNanoseconds
            #expect(try tier.restore(scope: "s", tokens: tokens, frontier: committed, check: {}) != nil)
            let restored = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            print(String(format: "encode one thread %.2f s (%.0f rows/s, %.2f us/row); tier write with %d writers %.2f s; restore %.2f s",
                         single, rows / single, single / rows * 1e6, QwenStagePrefixDiskIO.encodingWriters, written, restored))
            tier.close()
        }
    }

    /// The bytes an encoded record saves at the beta models' shapes, from the
    /// record layout itself: a Qwen 3.8 27B rank under tensor parallel (16
    /// full-attention layers of 4 key/value heads of 256, halved by the two
    /// ranks, BF16) and a GLM-5.3-Flash DSA layer (`kv_lora_rank` 512 latents
    /// encoded; `index_head_dim` 128 index keys and pool gates native), with
    /// one real encoded layer measured for its error.
    @Test func encodedRecordsAreSmallerAtTheBetaModelsShapes() throws {
        try onCPU {
            let tag = QwenStagePrefixDiskFormat.tagBytes
            func attentionBytes(_ encoding: QwenStagePrefixDiskEncoding, slot: String, heads: Int, width: Int, dtype: DType,
                                committed: Int, block: Int) -> Int {
                stride(from: 0, to: committed, by: block).reduce(0) { total, first in
                    let count = min(block, committed - first)
                    let run = encoding.rows(slot: slot, width: width, dtype: dtype, committed: committed)?
                        .headBytes(first: first, rows: count) ?? count * width * dtype.size
                    return total + heads * run + tag
                }
            }
            var lines: [String] = []
            // Qwen 3.8 27B, one TP rank: 2 KV heads of 256, keys and values of 16 layers, 4,096-token units.
            for committed in [4096, 32768, 131_072] {
                let native = 16 * 2 * attentionBytes(.native, slot: "keys", heads: 2, width: 256, dtype: .bfloat16,
                    committed: committed, block: 4096)
                let encoded = 16 * (attentionBytes(balancedQwen, slot: "keys", heads: 2, width: 256, dtype: .bfloat16,
                    committed: committed, block: 4096) + attentionBytes(balancedQwen, slot: "values", heads: 2, width: 256,
                    dtype: .bfloat16, committed: committed, block: 4096))
                lines.append("qwen38-27b tp rank \(committed) tokens: native \(native) encoded \(encoded) ratio "
                    + String(format: "%.3f", Double(native) / Double(encoded)))
                #expect(Double(native) / Double(encoded) > (committed >= 32768 ? 3.1 : 2.5))
            }
            // GLM-5.3-Flash DSA layer (11 of them): latents [1, 1, T, 512], index keys and gates [1, 1, T, 256].
            let glm = QwenStagePrefixDiskEncoding(quantization: .balanced, family: .glm5NextDSA)
            for dtype in [DType.bfloat16, .float32] {
                for committed in [8192, 131_072] {
                    let native = 11 * (attentionBytes(.native, slot: "keys", heads: 1, width: 512, dtype: dtype, committed: committed,
                        block: 4096) + attentionBytes(.native, slot: "values", heads: 1, width: 256, dtype: dtype,
                        committed: committed, block: 4096))
                    let encoded = 11 * (attentionBytes(glm, slot: "keys", heads: 1, width: 512, dtype: dtype, committed: committed,
                        block: 4096) + attentionBytes(glm, slot: "values", heads: 1, width: 256, dtype: dtype,
                        committed: committed, block: 4096))
                    lines.append("glm53-flash \(dtype) \(committed) tokens: native \(native) encoded \(encoded) ratio "
                        + String(format: "%.3f", Double(native) / Double(encoded)))
                    #expect(Double(native) / Double(encoded) > (dtype == .float32 ? 2.1 : 1.7))
                }
            }
            // One real layer of each, through the writer's and the reader's unit code.
            let qwen = try #require(states(committed: 4096 + 256, frontiers: [], heads: 2, width: 256, layers: [3]).last)
            let measuredQwen = try QwenStagePrefixDiskMeasurement.measure(qwen, encoding: balancedQwen, blockTokens: 4096).measurement
            #expect(measuredQwen.recordDataBytes < measuredQwen.nativeRecordDataBytes / 2)
            #expect(measuredQwen.attentionBytes == attentionBytes(balancedQwen, slot: "keys", heads: 2, width: 256, dtype: .bfloat16,
                committed: 4352, block: 4096) * 2 - 2 * 2 * tag)
            var latents = try #require(states(committed: 4096 + 256, frontiers: [], heads: 1, width: 512, layers: [3]).last)
            let gates = rows(heads: 1, tokens: 4352, width: 256, seed: 77, dtype: .bfloat16)
            latents = QwenStagePrefixState(committedTokens: 4352, attention: [3: (keys: latents.attention[3]!.keys, values: gates)],
                recurrent: latents.recurrent)
            let (measuredGLM, restoredGLM) = try QwenStagePrefixDiskMeasurement.measure(latents, encoding: glm, blockTokens: 4096)
            #expect(bytes(restoredGLM.attention[3]!.values) == bytes(gates), "the DSA index keys and gates stay exact")
            #expect(measuredGLM.entries.first { $0.kind == "values" }?.encodedRows == 0)
            for measurement in [measuredQwen, measuredGLM] {
                for entry in measurement.entries where entry.encodedRows > 0 {
                    lines.append("\(measurement.family) \(entry.kind) width \(entry.width): max abs error "
                        + String(format: "%.5f mean %.6f rms %.6f of max |x| %.3f", entry.maxAbsError, entry.meanAbsError,
                            entry.rmsError, entry.maxAbsValue) + " bytes \(entry.storedBytes)/\(entry.nativeBytes)")
                }
            }
            print(lines.joined(separator: "\n"))
        }
    }
}
