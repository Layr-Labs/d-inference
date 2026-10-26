import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// GLM tensor parallel's SSD records at the pair's checkpoint precision
// (`GLM5NextTensorParallelPrefixDisk.encoding`): the DSA latents a rank reads
// row by row from its histories are encoded as attention arrays are, the
// index keys, pool gates, NextN history and KDA states stay exact, and the
// record adopts into the rank's request state. Synthetic rows on the CPU
// device at the artifact's widths; no model, no pair.

@Suite("GLM tensor-parallel prefix SSD records, encoded", .serialized)
struct GLM5NextTensorParallelPrefixRecordEncodingTests {
    typealias Record = GLM5NextTensorParallelPrefixRecord
    typealias Disk = GLM5NextTensorParallelPrefixDisk

    /// A rank of an eight-layer stage at the artifact's history widths: DSA
    /// layers 3 and 7 with 512-wide latents and 128-wide index keys and pool
    /// gates (BF16, as the page pool keeps them), the NextN layer 8, two KDA
    /// heads of width 2.
    static let layout = Record.Layout(firstLayer: 0, dsaLayers: [3, 7], kdaLayers: [0, 1, 2, 4, 5, 6],
        latentWidth: 512, keyWidth: 128, historyTypes: [.bfloat16, .bfloat16, .bfloat16], nextNLayer: 8,
        nextNTypes: [.bfloat16, .bfloat16, .bfloat16], convolutionShape: [1, 12, 4], recurrentShape: [1, 2, 2, 2],
        paged: true)
    static let chunk = 64
    static let balanced = QwenStagePrefixDiskEncoding(quantization: .balanced, family: .glm5NextDSA)

    /// BF16 rows that look like a history: finite, per-channel scales, one
    /// strong channel, deterministic in `seed`.
    static func plane(rows: Int, width: Int, seed: Int) -> Data {
        var data = Data(count: rows * width * 2)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for row in 0 ..< rows {
                for channel in 0 ..< width {
                    let scale: Float = channel == 5 ? 6 : 0.25 + Float(channel % 7) * 0.1
                    let bits = (scale * sin(Float(row * 31 + channel * 7 + seed) * 0.173)).bitPattern
                    words[row * width + channel] = UInt16(truncatingIfNeeded: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) >> 16)
                }
            }
        }
        return data
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in raw.bindMemory(to: UInt16.self).map { Float(bitPattern: UInt32($0) << 16) } }
    }

    /// `value` rounded to the nearest BF16 (ties to even), as a float.
    static func bf16(_ value: Float) -> Float {
        let bits = value.bitPattern
        return Float(bitPattern: ((bits &+ 0x7fff &+ ((bits >> 16) & 1)) >> 16) << 16)
    }

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    /// A history's rows as the writer reads them: copied unit by unit from `data`.
    static func source(_ data: Data, width: Int, rows: Int) -> QwenStagePrefixDiskRows {
        let row = width * 2
        return .init(dtype: .bfloat16, tokens: rows, width: width, heldBytes: data.count, read: { range, destination in
            data.withUnsafeBytes {
                destination.copyMemory(from: $0.baseAddress!.advanced(by: range.lowerBound * row), byteCount: range.count * row)
            }
        })
    }

    struct Synthetic {
        let state: QwenStagePrefixState
        let rows: [Int: Record.Rows]
        let keys: [Int: Data]
        let values: [Int: Data]
    }

    static func synthetic(frontier: Int) -> Synthetic {
        var rows: [Int: Record.Rows] = [:], keys: [Int: Data] = [:], values: [Int: Data] = [:]
        for layer in layout.dsaLayers + [layout.nextNLayer!] {
            let k = plane(rows: frontier, width: layout.latentWidth, seed: layer * 101)
            let v = plane(rows: frontier, width: 2 * layout.keyWidth, seed: layer * 103 + 7)
            rows[layer] = (source(k, width: layout.latentWidth, rows: frontier), source(v, width: 2 * layout.keyWidth, rows: frontier))
            keys[layer] = k; values[layer] = v
        }
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for layer in layout.kdaLayers {
            recurrent[layer] = (MLXArray((0 ..< 48).map { Float($0 * 3 + layer) }, layout.convolutionShape).asType(.bfloat16),
                                MLXArray((0 ..< 8).map { Float($0 - layer) * 0.5 }, layout.recurrentShape))
        }
        return .init(state: QwenStagePrefixState(committedTokens: frontier, attention: [:], recurrent: recurrent),
            rows: rows, keys: keys, values: values)
    }

    static func open(_ root: URL, records: QwenStagePrefixDiskEncoding) throws -> Disk {
        var configuration = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 0x5a, count: 32)))
        configuration.minimumTokens = 1; configuration.minimumFreeBytes = 1
        let planScope = Disk.planScope(artifactAggregateSHA256: String(repeating: "a", count: 64),
            inventorySHA256: String(repeating: "b", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)], mtpDepth: 2)
        let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: planScope, rank: 0,
            encoding: Disk.encoding(records, layout: layout), stagingEpoch: UUID().uuidString.lowercased()))
        return Disk(tier: tier, planScope: planScope, layout: layout)
    }

    /// A rank's record under balanced: each DSA layer's latents encoded below
    /// the record's newest 128 rows, read row by row on the writer's threads;
    /// index keys and pool gates, the NextN history (kept native as
    /// speculative state) and the KDA states exact. A new tier on the same
    /// directory restores it, and it adopts into the rank's request state
    /// (`Record.Restorable`) with the older latents equal to the SDK
    /// reference's round trip of each row and everything else bit for bit.
    /// The same state under native records writes more bytes, in another directory.
    @Test func aBalancedRecordEncodesOnlyTheDSALatentsAndAdopts() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-tp-encoded-\(UUID().uuidString)",
                isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let frontier = 320, band = frontier - 128, prompt = (0 ..< frontier + 5).map { 4 + ($0 * 7) % 23 }
            let record = Self.synthetic(frontier: frontier)
            #expect(Disk.encoding(Self.balanced, layout: Self.layout).nativeLayers == [8])
            let encodedBytes: Int
            do {
                let disk = try Self.open(root, records: Self.balanced)
                disk.tier.persist(scope: disk.scope(chunk: Self.chunk), tokens: prompt, states: [record.state],
                    blockTokens: Self.chunk, attentionRows: record.rows)
                #expect(disk.tier.drain(timeoutSeconds: 60) && disk.tier.stats.persisted == 1)
                encodedBytes = disk.tier.stats.persistedBytes
                disk.tier.close()
            }
            let disk = try Self.open(root, records: Self.balanced)
            defer { disk.tier.close() }
            #expect(disk.tier.stats.loadedRecords == 1)
            let name = try #require(try FileManager.default.contentsOfDirectory(atPath: disk.tier.directory.path)
                .first { $0.hasSuffix(".dbpx") })
            let header = try QwenStagePrefixDiskIO.open(url: disk.tier.directory.appendingPathComponent(name), keys: disk.tier.keys).header
            #expect(header.encoding == Self.balanced.header)
            #expect(header.attention.map { "\($0.layer):\($0.kind)" } == ["3:keys", "3:values", "7:keys", "7:values", "8:keys", "8:values"])
            #expect(header.attention.map(\.nativeFrom) == [band, nil, band, nil, nil, nil])

            let restorable = try #require(disk.read(boundary: frontier, prompt: prompt, scope: disk.scope(chunk: Self.chunk),
                stop: { false }))
            #expect(restorable.frontier == frontier && restorable.states.count == Self.layout.kdaLayers.count)
            let profile = try #require(Self.balanced.configuration)
            let latentRow = Self.layout.latentWidth * 2, keyRow = Self.layout.keyWidth * 2
            for layer in Self.layout.dsaLayers {
                let history = try #require(restorable.histories[layer]), original = try #require(record.keys[layer])
                #expect(history.map(\.shape) == [[1, frontier, 512], [1, frontier, 128], [1, frontier, 128], [1, frontier]])
                let latents = Self.bytes(history[0])
                #expect(latents.count == original.count && latents.dropFirst(band * latentRow) == original.dropFirst(band * latentRow))
                #expect(latents.prefix(band * latentRow) != original.prefix(band * latentRow))
                for row in [0, 63, 64, band - 1] {
                    let range = row * latentRow ..< (row + 1) * latentRow
                    let input = Self.floats(original.subdata(in: range))
                    let encoded = try PagedKVQuantizationReference.encode(input, config: profile, isKey: true)
                    let expected = try PagedKVQuantizationReference.decode(encoded.bytes, headDim: input.count, config: profile,
                        isKey: true).map(Self.bf16)
                    #expect(Self.floats(latents.subdata(in: range)) == expected, "layer \(layer) row \(row)")
                }
                // Index keys and pool gates, split from their side-by-side rows, and validity: exact.
                let packed = try #require(record.values[layer])
                var indexKeys = Data(), gates = Data()
                for row in 0 ..< frontier {
                    indexKeys.append(packed.subdata(in: row * 2 * keyRow ..< row * 2 * keyRow + keyRow))
                    gates.append(packed.subdata(in: row * 2 * keyRow + keyRow ..< (row + 1) * 2 * keyRow))
                }
                #expect(Self.bytes(history[1]) == indexKeys && Self.bytes(history[2]) == gates && history[3].all().item(Bool.self))
            }
            let nextN = try #require(restorable.nextN)
            #expect(Self.bytes(nextN[0]) == record.keys[8]!, "the NextN latents stay exact")
            for (layer, pair) in record.state.recurrent {
                let restored = try #require(restorable.states[layer])
                #expect(Self.bytes(restored.conv) == Self.bytes(pair.conv) && Self.bytes(restored.ssm) == Self.bytes(pair.ssm))
            }

            // The same state as native records: its own directory, more bytes, every row exact.
            let native = try Self.open(root, records: QwenStagePrefixDiskEncoding(quantization: .native, family: .glm5NextDSA))
            defer { native.tier.close() }
            #expect(native.tier.planDirectory != disk.tier.planDirectory && native.tier.recordCount == 0)
            native.tier.persist(scope: native.scope(chunk: Self.chunk), tokens: prompt, states: [record.state],
                blockTokens: Self.chunk, attentionRows: record.rows)
            #expect(native.tier.drain(timeoutSeconds: 60) && native.tier.stats.persisted == 1)
            // Two DSA layers' older latent rows, each `keyRowBytes` instead of 1,024, less a slightly larger header.
            let saved = 2 * band * (latentRow - (try profile.rowLayout(headDim: 512)).keyRowBytes)
            let difference = native.tier.stats.persistedBytes - encodedBytes
            #expect(difference <= saved && difference > saved - 4096, "\(difference) of \(saved)")
            let exact = try #require(native.read(boundary: frontier, prompt: prompt, scope: native.scope(chunk: Self.chunk),
                stop: { false }))
            #expect(Self.bytes(exact.histories[3]![0]) == record.keys[3]!)
        }
    }

    /// A tenant's encoded records are its own (`GLM5NextTensorParallelResidentRuntime.prefixDiskScope`
    /// keys a request's records by its partition): found, offered and read only under that tenant.
    @Test func aTenantsEncodedRecordsAreItsOwn() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-tp-tenant-\(UUID().uuidString)",
                isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let frontier = 192, prompt = (0 ..< frontier + 3).map { 9 + ($0 * 5) % 31 }
            let a = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-a"))
            let b = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-b"))
            let disk = try Self.open(root, records: Self.balanced)
            defer { disk.tier.close() }
            let plain = disk.scope(chunk: Self.chunk)
            let scopeA = try #require(ClusterWorkerPrefixCache.scope(plain, a))
            let scopeB = try #require(ClusterWorkerPrefixCache.scope(plain, b))
            #expect(ClusterWorkerPrefixCache.scope(plain, nil) == plain)
            #expect(ClusterWorkerPrefixCache.scope(plain, .disabled) == nil)
            #expect(Set([scopeA, scopeB, plain]).count == 3)
            let record = Self.synthetic(frontier: frontier)
            disk.tier.persist(scope: scopeA, tokens: prompt, states: [record.state], blockTokens: Self.chunk,
                attentionRows: record.rows)
            #expect(disk.tier.drain(timeoutSeconds: 60) && disk.tier.recordCount == 1)
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: Self.chunk)
            #expect(disk.boundaries(scope: scopeA, prompt: prompt, candidates: candidates) == [frontier])
            #expect(disk.boundaries(scope: scopeB, prompt: prompt, candidates: candidates).isEmpty)
            #expect(disk.boundaries(scope: plain, prompt: prompt, candidates: candidates).isEmpty)
            #expect(disk.read(boundary: frontier, prompt: prompt, scope: scopeB, stop: { false }) == nil)
            let restored = try #require(disk.read(boundary: frontier, prompt: prompt, scope: scopeA, stop: { false }))
            #expect(restored.frontier == frontier && Self.bytes(restored.nextN![0]) == record.keys[8]!)
        }
    }

    /// A rank restored from a balanced record keeps a deeper boundary of a
    /// longer prompt: its row readers' latents that decode from the earlier
    /// record's are stored as that record stored them
    /// (`QwenStagePrefixDiskVerbatimSource`), so they come back bit for bit;
    /// written without the earlier record, they are encoded again and move.
    @Test func restoredLatentsKeepTheirFirstEncoding() throws {
        try Device.withDefaultDevice(.cpu) {
            func directory() throws -> URL {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("glm-tp-verbatim-\(UUID().uuidString)",
                    isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            let root = try directory(), elsewhere = try directory()
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
            let first = 192, second = 320, prompt = (0 ..< second + 3).map { 4 + ($0 * 11) % 29 }
            let record = Self.synthetic(frontier: first)
            let disk = try Self.open(root, records: Self.balanced)
            defer { disk.tier.close() }
            let scope = disk.scope(chunk: Self.chunk)
            disk.tier.persist(scope: scope, tokens: Array(prompt[0...first]), states: [record.state], blockTokens: Self.chunk,
                attentionRows: record.rows)
            #expect(disk.tier.drain(timeoutSeconds: 60) && disk.tier.stats.persisted == 1)
            let restored = try #require(disk.read(boundary: first, prompt: Array(prompt[0...first]), scope: scope, stop: { false }))
            // The rank's histories at the deeper boundary: the restored rows, then its own.
            var rows: [Int: Record.Rows] = [:], latents: [Int: Data] = [:]
            for layer in Self.layout.dsaLayers + [8] {
                let history = try #require(layer == 8 ? restored.nextN : restored.histories[layer])
                latents[layer] = Self.bytes(history[0])
                let k = latents[layer]! + Self.plane(rows: second - first, width: 512, seed: layer * 7 + 1)
                let v = record.values[layer]! + Self.plane(rows: second - first, width: 256, seed: layer * 13 + 2)
                rows[layer] = (Self.source(k, width: 512, rows: second), Self.source(v, width: 256, rows: second))
            }
            let state = QwenStagePrefixState(committedTokens: second, attention: [:], recurrent: record.state.recurrent)
            disk.tier.persist(scope: scope, tokens: Array(prompt[0...second]), states: [state], blockTokens: Self.chunk,
                attentionRows: rows)
            // The DSA latents below the earlier record's band: two layers of one head.
            #expect(disk.tier.drain(timeoutSeconds: 60) && disk.tier.stats.persisted == 2
                && disk.tier.stats.verbatimRows == 2 * (first - 128))
            let again = try #require(disk.read(boundary: second, prompt: Array(prompt[0...second]), scope: scope, stop: { false }))
            let kept = (first - 128) * 1024
            for layer in Self.layout.dsaLayers {
                #expect(Self.bytes(again.histories[layer]![0]).prefix(kept) == latents[layer]!.prefix(kept), "layer \(layer)")
            }
            let fresh = try Self.open(elsewhere, records: Self.balanced)
            defer { fresh.tier.close() }
            fresh.tier.persist(scope: fresh.scope(chunk: Self.chunk), tokens: Array(prompt[0...second]), states: [state],
                blockTokens: Self.chunk, attentionRows: rows)
            #expect(fresh.tier.drain(timeoutSeconds: 60) && fresh.tier.stats.verbatimRows == 0)
            let moved = try #require(fresh.read(boundary: second, prompt: Array(prompt[0...second]),
                scope: fresh.scope(chunk: Self.chunk), stop: { false }))
            #expect(Self.layout.dsaLayers.contains { Self.bytes(moved.histories[$0]![0]).prefix(kept) != latents[$0]!.prefix(kept) })
        }
    }
}
