import Foundation
import CryptoKit

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func emitJSON<T: Encodable>(_ value: T) throws {
    let bytes = try canonicalJSONData(value)
    FileHandle.standardOutput.write(bytes + Data([10]))
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageSchedule.swift
import Foundation

/// Same immutable request object is supplied to both stages. No teacher-token
/// policy, sampling, request coalescing or changed microchunk schedule is hidden here.
struct QwenLayerStageRequestSpec: Codable, Equatable {
    let requestID: UUID
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int

    init(requestID: UUID, promptCount: Int, chunkSize: Int, outputCount: Int) throws {
        guard (1...128).contains(promptCount), (1...32).contains(chunkSize),
            (1...4).contains(outputCount) else {
            throw ProbeError("Initial layer stages require prompt<=128, chunk<=32, output<=4 and batch one")
        }
        self.requestID = requestID; self.promptCount = promptCount
        self.chunkSize = chunkSize; self.outputCount = outputCount
    }

    private enum CodingKeys: String, CodingKey { case requestID, promptCount, chunkSize, outputCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: values.decode(UUID.self, forKey: .requestID),
            promptCount: values.decode(Int.self, forKey: .promptCount),
            chunkSize: values.decode(Int.self, forKey: .chunkSize),
            outputCount: values.decode(Int.self, forKey: .outputCount))
    }

    var fingerprint: String {
        // UUID and integers have a stable explicit representation independent of JSONEncoder options.
        sha256(Data("qwen-stage-request-v1|\(requestID.uuidString.lowercased())|\(promptCount)|\(chunkSize)|\(outputCount)".utf8))
    }
}

struct QwenLayerStageFrame: Codable, Equatable {
    enum Phase: String, Codable { case prefill, decode }
    let sequence: Int
    let phase: Phase
    let tokenOffset: Int
    let tokenCount: Int
    let finalPromptChunk: Bool
}

/// Pure admission and frontier bookkeeping; advance only after all native
/// outputs/state roots have completed and the recurrent generation committed.
struct QwenLayerStageSchedule {
    let request: QwenLayerStageRequestSpec
    private(set) var committedTokens = 0
    private(set) var committedPromptTokens = 0
    private(set) var decodeForwardCount = 0
    private(set) var nextSequence = 0

    init(request: QwenLayerStageRequestSpec) { self.request = request }

    var complete: Bool {
        committedPromptTokens == request.promptCount && decodeForwardCount == request.outputCount - 1
    }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        guard committedPromptTokens < request.promptCount, offset == committedTokens,
            count == min(request.chunkSize, request.promptCount - committedPromptTokens),
            final == (committedPromptTokens + count == request.promptCount) else {
            throw ProbeError("Layer-stage prefill differs from the agreed microchunk schedule or token frontier")
        }
        return .init(sequence: nextSequence, phase: .prefill, tokenOffset: offset,
            tokenCount: count, finalPromptChunk: final)
    }

    func admitDecode(offset: Int) throws -> QwenLayerStageFrame {
        guard committedPromptTokens == request.promptCount, offset == committedTokens,
            decodeForwardCount < request.outputCount - 1 else {
            throw ProbeError("Layer-stage decode is outside the agreed token frontier")
        }
        return .init(sequence: nextSequence, phase: .decode, tokenOffset: offset,
            tokenCount: 1, finalPromptChunk: false)
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        let expected = try frame.phase == .prefill
            ? admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset, final: frame.finalPromptChunk)
            : admitDecode(offset: frame.tokenOffset)
        guard frame == expected else { throw ProbeError("Layer-stage committed frame changed after admission") }
        committedTokens += frame.tokenCount; nextSequence += 1
        if frame.phase == .prefill { committedPromptTokens += frame.tokenCount }
        else { decodeForwardCount += 1 }
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/WorkerJSONScanner.swift
import Foundation

/// Foundation JSON decoding discards duplicate keys and accepts 1.0 as Int.
/// Scan bounded protocol JSON first so neither ambiguity reaches agreement.
func validateWorkerJSON(_ data: Data) throws {
    var scanner = WorkerJSONScanner(bytes: Array(data))
    try scanner.value(depth: 0)
    scanner.whitespace()
    guard scanner.offset == scanner.bytes.count else { throw ProbeError("Trailing worker JSON content") }
}

private struct WorkerJSONScanner {
    let bytes: [UInt8]
    var offset = 0

    mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw ProbeError("Worker JSON exceeds nesting limit") }
        whitespace()
        guard offset < bytes.count else { throw ProbeError("Truncated worker JSON value") }
        switch bytes[offset] {
        case 123: try object(depth: depth)
        case 91: try array(depth: depth)
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try integer()
        default: throw ProbeError("Invalid worker JSON value")
        }
    }

    mutating func object(depth: Int) throws {
        offset += 1
        whitespace()
        if consume(125) { return }
        var keys = Set<String>()
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw ProbeError("Duplicate worker JSON key: \(key)") }
            whitespace()
            guard consume(58) else { throw ProbeError("Missing worker JSON colon") }
            try value(depth: depth + 1)
            whitespace()
            if consume(125) { return }
            guard consume(44) else { throw ProbeError("Missing worker JSON object delimiter") }
        }
    }

    mutating func array(depth: Int) throws {
        offset += 1
        whitespace()
        if consume(93) { return }
        while true {
            try value(depth: depth + 1)
            whitespace()
            if consume(93) { return }
            guard consume(44) else { throw ProbeError("Missing worker JSON array delimiter") }
        }
    }

    mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ProbeError("Worker JSON object keys must be strings") }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 {
                // Decode escapes/UTF-8 before comparing keys, including \uXXXX aliases.
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            guard byte >= 32 else { throw ProbeError("Unescaped worker JSON control byte") }
            if byte == 92 {
                guard offset < bytes.count else { throw ProbeError("Truncated worker JSON escape") }
                let escaped = bytes[offset]
                offset += 1
                if escaped == 117 {
                    guard offset + 4 <= bytes.count,
                        bytes[offset..<(offset + 4)].allSatisfy({
                            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                        }) else { throw ProbeError("Invalid worker JSON Unicode escape") }
                    offset += 4
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) {
                    throw ProbeError("Invalid worker JSON string escape")
                }
            }
        }
        throw ProbeError("Unterminated worker JSON string")
    }

    mutating func integer() throws {
        let start = offset
        _ = consume(45)
        guard offset < bytes.count else { throw ProbeError("Truncated worker JSON integer") }
        if !consume(48) {
            guard (49...57).contains(bytes[offset]) else { throw ProbeError("Invalid worker JSON integer") }
            repeat { offset += 1 } while offset < bytes.count && (48...57).contains(bytes[offset])
        }
        guard offset - start <= 20 else { throw ProbeError("Worker JSON integer exceeds supported range") }
        if offset < bytes.count, [46, 69, 101].contains(bytes[offset]) {
            throw ProbeError("Worker protocol requires integer JSON syntax, not fractions or exponents")
        }
    }

    mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard offset + expected.count <= bytes.count,
            Array(bytes[offset..<(offset + expected.count)]) == expected else {
            throw ProbeError("Invalid worker JSON literal")
        }
        offset += expected.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/BoundedProbeInput.swift
import CoreFoundation
import Foundation

/// Shared byte and integer parsing for explicitly bounded diagnostics.
enum BoundedProbeInput {
    static func data(_ file: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ProbeError("Diagnostic input file is empty or exceeds its byte limit")
        }
        return data
    }

    static func tokenIDs(_ file: URL) throws -> [Int] {
        let bytes = try data(file, maximumBytes: 65_536)
        try validateWorkerJSON(bytes)
        return try JSONDecoder().decode([Int].self, from: bytes)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/CanonicalJSON.swift
import Foundation

func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}



// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageWireExpectation.swift
import Foundation

/// Values must come from the locally verified stage receipt and source plan,
/// never from the received header. Producer is the source plan's stage zero.
struct QwenLayerStageWireSourceIdentity: Equatable {
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let producerStageFingerprint: String

    init(sourceConfigurationSHA256: String, artifactAggregateSHA256: String,
         storageCommitmentSHA256: String, planFingerprint: String,
         producerStageFingerprint: String) throws {
        guard [sourceConfigurationSHA256, artifactAggregateSHA256, storageCommitmentSHA256,
               planFingerprint, producerStageFingerprint].allSatisfy(qwenStageWireIsSHA256) else {
            throw ProbeError("Stage wire source identity requires canonical SHA-256 values")
        }
        self.sourceConfigurationSHA256 = sourceConfigurationSHA256
        self.artifactAggregateSHA256 = artifactAggregateSHA256
        self.storageCommitmentSHA256 = storageCommitmentSHA256
        self.planFingerprint = planFingerprint; self.producerStageFingerprint = producerStageFingerprint
    }
}

/// Allocation geometry is derived exclusively from local admission. A decoded
/// header must agree with these values before any payload receive is posted.
struct QwenLayerStageBoundaryWireExpectation {
    let requestFingerprint: String
    let sourceIdentity: QwenLayerStageWireSourceIdentity
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    init(request: QwenLayerStageRequestSpec, frame: QwenLayerStageFrame, tokenIDs: [Int],
         sourceIdentity: QwenLayerStageWireSourceIdentity, hiddenSize: Int,
         nativeDType: String) throws {
        try Self.requireFrame(frame, request: request)
        guard tokenIDs.count == frame.tokenCount,
              tokenIDs.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }),
              (1...8192).contains(hiddenSize) else {
            throw ProbeError("Stage wire expectation requires locally admitted token IDs and hidden width")
        }
        let elementBytes = try qwenStageWireElementBytes(nativeDType)
        self.requestFingerprint = request.fingerprint; self.sourceIdentity = sourceIdentity
        self.frame = frame
        // Exact convention of QwenLayerStageBoundary.tokenHash, without importing MLX.
        self.tokenIDsSHA256 = sha256(Data(tokenIDs.map(String.init).joined(separator: ",").utf8))
        self.shape = [1, frame.tokenCount, hiddenSize]; self.dtype = nativeDType
        self.byteCount = frame.tokenCount * hiddenSize * elementBytes
    }

    /// Reuse the existing pure schedule to prove that even the locally supplied
    /// expected frame is a complete frame of this bounded request. Admission does
    /// not advance a live request; its owner chooses the currently expected frame.
    private static func requireFrame(_ frame: QwenLayerStageFrame,
                                     request: QwenLayerStageRequestSpec) throws {
        var schedule = QwenLayerStageSchedule(request: request)
        for offset in stride(from: 0, to: request.promptCount, by: request.chunkSize) {
            let count = min(request.chunkSize, request.promptCount - offset)
            let expected = try schedule.admitPrefill(count: count, offset: offset,
                final: offset + count == request.promptCount)
            if expected == frame { return }
            try schedule.commit(expected)
        }
        for _ in 0..<(request.outputCount - 1) {
            let expected = try schedule.admitDecode(offset: schedule.committedTokens)
            if expected == frame { return }
            try schedule.commit(expected)
        }
        throw ProbeError("Stage wire expected frame does not belong to the agreed request schedule")
    }
}

func qwenStageWireIsSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
}

func qwenStageWireElementBytes(_ dtype: String) throws -> Int {
    switch dtype {
    case "float16", "bfloat16": return 2
    case "float32": return 4
    default: throw ProbeError("Stage wire dtype must equal an admitted native floating-point dtype")
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageBoundaryWireHeader.swift
import Foundation

/// This value carries no array, pointer, receive allocation or transport state.
/// The supported receive entry is decode(_:expected:), which scans bounded raw
/// JSON before Codable can discard duplicate keys or accept fractional integers.
struct QwenLayerStageBoundaryWireHeader: Codable, Equatable {
    static let maximumEncodedBytes = 16 * 1024
    let version: Int
    let requestFingerprint: String
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let producerStageFingerprint: String
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let payloadSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    /// Native sender adapters can pass the actual boundary fields here, then
    /// validate(expected:) before encoding. Do not replace actual metadata with
    /// the expected metadata to hide a producer discrepancy.
    init(requestFingerprint: String, sourceIdentity: QwenLayerStageWireSourceIdentity,
         frame: QwenLayerStageFrame, tokenIDsSHA256: String, payloadSHA256: String,
         shape: [Int], dtype: String, byteCount: Int) throws {
        self.version = 1; self.requestFingerprint = requestFingerprint
        self.sourceConfigurationSHA256 = sourceIdentity.sourceConfigurationSHA256
        self.artifactAggregateSHA256 = sourceIdentity.artifactAggregateSHA256
        self.storageCommitmentSHA256 = sourceIdentity.storageCommitmentSHA256
        self.planFingerprint = sourceIdentity.planFingerprint
        self.producerStageFingerprint = sourceIdentity.producerStageFingerprint
        self.frame = frame; self.tokenIDsSHA256 = tokenIDsSHA256; self.payloadSHA256 = payloadSHA256
        self.shape = shape; self.dtype = dtype; self.byteCount = byteCount
        try validateIntrinsic()
    }

    init(expected: QwenLayerStageBoundaryWireExpectation, payloadSHA256: String) throws {
        try self.init(requestFingerprint: expected.requestFingerprint, sourceIdentity: expected.sourceIdentity,
            frame: expected.frame, tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: payloadSHA256,
            shape: expected.shape, dtype: expected.dtype, byteCount: expected.byteCount)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, requestFingerprint, sourceConfigurationSHA256, artifactAggregateSHA256
        case storageCommitmentSHA256, planFingerprint, producerStageFingerprint, frame
        case tokenIDsSHA256, payloadSHA256, shape, dtype, byteCount
    }
    private enum DecodePermit: Equatable { case boundedStrictJSON }
    private static let permitKey = CodingUserInfoKey(rawValue: "qwen-layer-stage-bounded-header-v1")!
    private static let frameFields: Set<String> = [
        "sequence", "phase", "tokenOffset", "tokenCount", "finalPromptChunk",
    ]

    init(from decoder: Decoder) throws {
        guard decoder.userInfo[Self.permitKey] as? DecodePermit == .boundedStrictJSON else {
            throw ProbeError("Stage wire JSON must enter through bounded strict decode(_:expected:)")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        requestFingerprint = try values.decode(String.self, forKey: .requestFingerprint)
        sourceConfigurationSHA256 = try values.decode(String.self, forKey: .sourceConfigurationSHA256)
        artifactAggregateSHA256 = try values.decode(String.self, forKey: .artifactAggregateSHA256)
        storageCommitmentSHA256 = try values.decode(String.self, forKey: .storageCommitmentSHA256)
        planFingerprint = try values.decode(String.self, forKey: .planFingerprint)
        producerStageFingerprint = try values.decode(String.self, forKey: .producerStageFingerprint)
        frame = try values.decode(QwenLayerStageFrame.self, forKey: .frame)
        tokenIDsSHA256 = try values.decode(String.self, forKey: .tokenIDsSHA256)
        payloadSHA256 = try values.decode(String.self, forKey: .payloadSHA256)
        shape = try values.decode([Int].self, forKey: .shape)
        dtype = try values.decode(String.self, forKey: .dtype)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        try validateIntrinsic()
    }

    static func decode(_ data: Data, expected: QwenLayerStageBoundaryWireExpectation) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Stage wire header is empty or exceeds 16 KiB")
        }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
              let frame = object["frame"] as? [String: Any], Set(frame.keys) == frameFields,
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(object[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = object["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Stage wire header/frame fields must be exact and dimensions/counts must be integer JSON values")
        }
        let decoder = JSONDecoder()
        decoder.userInfo[permitKey] = DecodePermit.boundedStrictJSON
        let header = try decoder.decode(Self.self, from: data)
        try header.validate(expected: expected)
        return header
    }

    func encoded() throws -> Data {
        try validateIntrinsic()
        let data = try canonicalJSONData(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded stage wire header exceeds its bound") }
        return data
    }

    func validate(expected: QwenLayerStageBoundaryWireExpectation) throws {
        try validateIntrinsic()
        let source = expected.sourceIdentity
        guard requestFingerprint == expected.requestFingerprint,
              sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
              artifactAggregateSHA256 == source.artifactAggregateSHA256,
              storageCommitmentSHA256 == source.storageCommitmentSHA256,
              planFingerprint == source.planFingerprint,
              producerStageFingerprint == source.producerStageFingerprint,
              frame == expected.frame, tokenIDsSHA256 == expected.tokenIDsSHA256,
              shape == expected.shape, dtype == expected.dtype, byteCount == expected.byteCount else {
            throw ProbeError("Stage wire header differs from local request/source/frame/token/layout expectations")
        }
    }

    /// Optional CPU payload check. A native adapter can instead reconstruct the
    /// existing boundary and invoke its actual owned-array/hash validation.
    func validatePayload(_ payload: Data) throws {
        guard payload.count == byteCount, sha256(payload) == payloadSHA256 else {
            throw ProbeError("Stage wire payload length or logical-byte digest differs")
        }
    }

    private func validateIntrinsic() throws {
        guard version == 1,
              [requestFingerprint, sourceConfigurationSHA256, artifactAggregateSHA256,
               storageCommitmentSHA256, planFingerprint, producerStageFingerprint,
               tokenIDsSHA256, payloadSHA256].allSatisfy(qwenStageWireIsSHA256),
              (0..<132).contains(frame.sequence), (0..<132).contains(frame.tokenOffset),
              (1...32).contains(frame.tokenCount), shape.count == 3,
              shape[0] == 1, shape[1] == frame.tokenCount, (1...8192).contains(shape[2]) else {
            throw ProbeError("Stage wire version, hashes, frame or native batch-one geometry is invalid")
        }
        if frame.phase == .decode, frame.tokenCount != 1 || frame.finalPromptChunk {
            throw ProbeError("Stage wire decode frame must consume one token without a prompt-final flag")
        }
        let elementBytes = try qwenStageWireElementBytes(dtype)
        guard byteCount == shape[1] * shape[2] * elementBytes else {
            throw ProbeError("Stage wire logical payload length differs from its bounded native layout")
        }
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageWireAcknowledgement.swift
import Foundation

/// Acknowledgements bind both the completed header and the particular protocol
/// transition. No acknowledgement by itself claims model or state correctness.
enum QwenLayerStageWireAcknowledgement {
    enum Phase: String { case ready, consumed }
    static let elements = 64
    static let byteCount = elements * MemoryLayout<Int32>.size

    static func values(header: Data, phase: Phase) -> [Int32] {
        let identity = "qwen-stage-ack-v1|\(phase.rawValue)|\(sha256(header))"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], header: Data, phase: Phase) throws {
        guard actual == values(header: header, phase: phase) else {
            throw ProbeError("Stage wire acknowledgement differs from its header or transition")
        }
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageBoundaryWireCheck.swift
import Foundation

/// Pure header/admission check; no model, array, socket, payload transport or GPU.
func checkQwenLayerStageBoundaryWire() throws {
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
        artifactAggregateSHA256: String(repeating: "b", count: 64),
        storageCommitmentSHA256: String(repeating: "c", count: 64),
        planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
    let request = try QwenLayerStageRequestSpec(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        promptCount: 65, chunkSize: 32, outputCount: 4)
    var schedule = QwenLayerStageSchedule(request: request)
    var accepted = 0, rejected = 0
    func roundTrip(_ frame: QwenLayerStageFrame) throws {
        let expected = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
            tokenIDs: Array(repeating: 7, count: frame.tokenCount), sourceIdentity: source,
            hiddenSize: 128, nativeDType: "bfloat16")
        let payload = Data(repeating: 19, count: expected.byteCount)
        let original = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
        let decoded = try QwenLayerStageBoundaryWireHeader.decode(original.encoded(), expected: expected)
        guard decoded == original, decoded.byteCount == expected.byteCount else {
            throw ProbeError("Valid stage wire round trip changed header identity")
        }
        try decoded.validatePayload(payload)
        accepted += 1
    }
    for offset in [0, 32, 64] {
        let count = min(32, request.promptCount - offset)
        let frame = try schedule.admitPrefill(count: count, offset: offset, final: offset + count == request.promptCount)
        try roundTrip(frame); try schedule.commit(frame)
    }
    for _ in 0..<3 {
        let frame = try schedule.admitDecode(offset: schedule.committedTokens)
        try roundTrip(frame); try schedule.commit(frame)
    }
    guard schedule.complete, accepted == 6 else { throw ProbeError("Stage wire round trips missed part of the request") }

    let frame = QwenLayerStageFrame(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 32, finalPromptChunk: false)
    let expected = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
        tokenIDs: Array(repeating: 7, count: 32), sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    let payload = Data(repeating: 19, count: expected.byteCount)
    let header = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
    let encoded = try header.encoded()
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let text = String(decoding: encoded, as: UTF8.self)
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Stage wire check accepted " + label)
    }
    func rejectObject(_ label: String, change: (inout [String: Any]) -> Void) throws {
        var changed = object; change(&changed)
        let data = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
        try reject(label) { _ = try QwenLayerStageBoundaryWireHeader.decode(data, expected: expected) }
    }
    for key in ["requestFingerprint", "sourceConfigurationSHA256", "artifactAggregateSHA256",
                "storageCommitmentSHA256", "planFingerprint", "producerStageFingerprint", "tokenIDsSHA256"] {
        try rejectObject("wrong " + key) { $0[key] = String(repeating: "f", count: 64) }
    }
    for (key, value) in [("sequence", 1), ("tokenOffset", 1), ("tokenCount", 31)] {
        try rejectObject("wrong frame " + key) {
            var nested = $0["frame"] as! [String: Any]; nested[key] = value; $0["frame"] = nested
        }
    }
    try rejectObject("wrong final flag") {
        var nested = $0["frame"] as! [String: Any]; nested["finalPromptChunk"] = true; $0["frame"] = nested
    }
    try rejectObject("wrong phase") {
        var nested = $0["frame"] as! [String: Any]; nested["phase"] = "decode"; $0["frame"] = nested
    }
    for shape in [[2, 32, 128], [1, 31, 128], [1, 32, 256], [1, 32, 0], [1, 32], [1, 32, 8193]] {
        try rejectObject("wrong shape") { $0["shape"] = shape }
    }
    try rejectObject("wrong native dtype") { $0["dtype"] = "float32"; $0["byteCount"] = expected.byteCount * 2 }
    try rejectObject("unsupported dtype") { $0["dtype"] = "uint8" }
    try rejectObject("wrong payload length") { $0["byteCount"] = expected.byteCount + 1 }
    try rejectObject("wrong version") { $0["version"] = 2 }
    try rejectObject("malformed digest") { $0["payloadSHA256"] = String(repeating: "A", count: 64) }
    try rejectObject("extra field") { $0["unexpected"] = 1 }
    try rejectObject("missing field") { $0.removeValue(forKey: "payloadSHA256") }
    try rejectObject("extra frame field") {
        var nested = $0["frame"] as! [String: Any]; nested["unexpected"] = 1; $0["frame"] = nested
    }
    try rejectObject("missing frame field") {
        var nested = $0["frame"] as! [String: Any]; nested.removeValue(forKey: "sequence"); $0["frame"] = nested
    }
    try rejectObject("boolean count") { $0["byteCount"] = true }
    try rejectObject("boolean dimension") { $0["shape"] = [true, 32, 128] as [Any] }
    try rejectObject("integer final flag") {
        var nested = $0["frame"] as! [String: Any]; nested["finalPromptChunk"] = 0; $0["frame"] = nested
    }
    for malformed in [
        text.replacingOccurrences(of: "\"byteCount\":8192", with: "\"byteCount\":8192.0"),
        text.replacingOccurrences(of: "\"byteCount\":8192", with: "\"byteCount\":8192e0"),
        "{\"version\":1," + String(text.dropFirst()),
        "{\"\\u0076ersion\":1," + String(text.dropFirst()),
        text + " null", "[]", "null", "",
    ] {
        try reject("strict JSON syntax/type") {
            _ = try QwenLayerStageBoundaryWireHeader.decode(Data(malformed.utf8), expected: expected)
        }
    }
    try reject("oversize JSON") {
        _ = try QwenLayerStageBoundaryWireHeader.decode(Data(repeating: 32,
            count: QwenLayerStageBoundaryWireHeader.maximumEncodedBytes + 1), expected: expected)
    }
    try reject("bare Codable decoder bypass") { _ = try JSONDecoder().decode(QwenLayerStageBoundaryWireHeader.self, from: encoded) }
    try reject("wrong payload bytes") { try header.validatePayload(Data(repeating: 20, count: expected.byteCount)) }
    try reject("short payload") { try header.validatePayload(payload.dropLast()) }
    try reject("wrong locally expected token count") {
        _ = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame, tokenIDs: [7],
            sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    }
    try reject("frame outside local request") {
        _ = try QwenLayerStageBoundaryWireExpectation(request: request,
            frame: .init(sequence: 0, phase: .decode, tokenOffset: 0, tokenCount: 1, finalPromptChunk: false),
            tokenIDs: [7], sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_boundary_wire_check"
        let cpuOnly = true
        let acceptedFrames: Int
        let rejectedFixtures: Int
    }
    try emitJSON(Result(acceptedFrames: accepted, rejectedFixtures: rejected))
}


// Verbatim input: /Users/developer/DarkbloomDev/cluster-research/stage-lookahead-wire-draft/QwenLayerStageLookaheadWireEnvelope.swift
import Foundation

/// A distinct, closed v2 envelope around the unchanged v1 boundary contract.
/// Expectations come from local admission, never from the received object.
/// Not Decodable: all receive paths must scan bounded original JSON first.
struct QwenLayerStageLookaheadWireEnvelope: Equatable {
    static let version = 2
    static let flow = "prompt_lookahead_one_v1"
    static let maximumEncodedBytes = 16 * 1024

    let boundary: QwenLayerStageBoundaryWireHeader
    private let outerData: Data

    /// Pass the producer's actual native boundary metadata, not a replacement
    /// synthesized from expected fields. Validation precedes sender encoding.
    init(boundary: QwenLayerStageBoundaryWireHeader,
         expected: QwenLayerStageBoundaryWireExpectation) throws {
        try boundary.validate(expected: expected)
        let data = try canonicalJSONData(Content(boundary: boundary))
        try Self.requireByteBound(data)
        self.boundary = boundary
        self.outerData = data
    }

    private init(boundary: QwenLayerStageBoundaryWireHeader, validatedOuterData: Data) {
        self.boundary = boundary
        self.outerData = validatedOuterData
    }

    /// Exact sent/received bytes, including accepted insignificant whitespace.
    /// ACKs bind these bytes; re-encoding the nested object would change identity.
    func encoded() -> Data { outerData }

    static func decode(_ data: Data,
                       expected: QwenLayerStageBoundaryWireExpectation) throws -> Self {
        try requireByteBound(data)
        // This scanner visits the complete nested original input. It rejects
        // duplicate decoded keys and every fractional/exponent number lexeme
        // before Foundation can normalize NSNumber(1.0) or discard duplicates.
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "flow", "boundary"],
              BoundedProbeInput.integer(object["version"]) == version,
              object["flow"] as? String == flow,
              let nested = object["boundary"] as? [String: Any],
              let frame = nested["frame"] as? [String: Any],
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(nested[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = nested["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Lookahead v2 envelope requires exact version/flow/fields and original integer JSON values")
        }
        // Only now may the nested dictionary be serialized. The unchanged v1
        // strict decoder proves its complete closed schema, types, intrinsic
        // bounds and agreement with independently admitted local expectations.
        let nestedData = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        let boundary = try QwenLayerStageBoundaryWireHeader.decode(nestedData, expected: expected)
        return Self(boundary: boundary, validatedOuterData: data)
    }

    private static func requireByteBound(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Lookahead v2 envelope is empty or exceeds 16 KiB")
        }
    }

    private struct Content: Encodable {
        let version = QwenLayerStageLookaheadWireEnvelope.version
        let flow = QwenLayerStageLookaheadWireEnvelope.flow
        let boundary: QwenLayerStageBoundaryWireHeader
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/cluster-research/stage-lookahead-wire-draft/QwenLayerStageLookaheadWireAcknowledgement.swift
import Foundation

/// The v2 namespace binds flow, phase and the exact admitted outer wire bytes.
/// `received` does not assert model consumption; `consumed` remains a separate
/// transition. This codec admits bytes only and implements no transport state.
enum QwenLayerStageLookaheadWireAcknowledgement {
    enum Phase: String, CaseIterable { case ready, received, consumed }
    static let elements = 64
    static let byteCount = elements * MemoryLayout<Int32>.size

    static func values(envelope: QwenLayerStageLookaheadWireEnvelope,
                       phase: Phase) -> [Int32] {
        let identity = "qwen-stage-ack-v2|\(QwenLayerStageLookaheadWireEnvelope.flow)|\(phase.rawValue)|\(sha256(envelope.encoded()))"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], envelope: QwenLayerStageLookaheadWireEnvelope,
                         phase: Phase) throws {
        guard actual == values(envelope: envelope, phase: phase) else {
            throw ProbeError("Lookahead v2 acknowledgement differs from its exact envelope, flow or transition")
        }
    }
}


// Verbatim input: /Users/developer/DarkbloomDev/cluster-research/stage-lookahead-wire-draft/QwenLayerStageLookaheadWireCheck.swift
import Foundation

/// Pure codec checks. No model, MLX array, process, socket or transport operation.
func checkQwenLayerStageLookaheadWire(includeVectors: Bool = false) throws {
    typealias Envelope = QwenLayerStageLookaheadWireEnvelope
    typealias ACK = QwenLayerStageLookaheadWireAcknowledgement
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
        artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
        planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
    let request = try QwenLayerStageRequestSpec(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        promptCount: 65, chunkSize: 32, outputCount: 4)
    var schedule = QwenLayerStageSchedule(request: request)
    var frames = [QwenLayerStageFrame]()
    for offset in [0, 32, 64] {
        let count = min(32, request.promptCount - offset)
        let frame = try schedule.admitPrefill(count: count, offset: offset, final: offset + count == request.promptCount)
        frames.append(frame); try schedule.commit(frame)
    }
    for _ in 0..<3 {
        let frame = try schedule.admitDecode(offset: schedule.committedTokens)
        frames.append(frame); try schedule.commit(frame)
    }
    func expectation(_ frame: QwenLayerStageFrame, dtype: String = "bfloat16") throws -> QwenLayerStageBoundaryWireExpectation {
        try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
            tokenIDs: Array(repeating: 7, count: frame.tokenCount), sourceIdentity: source, hiddenSize: 128, nativeDType: dtype)
    }
    struct AcknowledgementVector: Encodable {
        let phase: String
        let values: [Int32]
        let logicalBytesSHA256: String
    }
    struct Vector: Encodable {
        let variant: String
        let frame: QwenLayerStageFrame
        let dtype: String
        let payloadByteCount: Int
        let innerBase64: String
        let outerBase64: String
        let outerSHA256: String
        let acknowledgements: [AcknowledgementVector]
    }
    var vectors = [Vector](), rejections = [String]()
    func capture(_ envelope: Envelope, variant: String) throws {
        let acks = try ACK.Phase.allCases.map { phase -> AcknowledgementVector in
            let values = ACK.values(envelope: envelope, phase: phase)
            try ACK.validate(values, envelope: envelope, phase: phase)
            var bytes = Data()
            for value in values {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            }
            guard values.count == 64, bytes.count == 256 else { throw ProbeError("Lookahead ACK storage geometry changed") }
            return .init(phase: phase.rawValue, values: values, logicalBytesSHA256: sha256(bytes))
        }
        vectors.append(.init(variant: variant, frame: envelope.boundary.frame, dtype: envelope.boundary.dtype,
            payloadByteCount: envelope.boundary.byteCount, innerBase64: try envelope.boundary.encoded().base64EncodedString(),
            outerBase64: envelope.encoded().base64EncodedString(), outerSHA256: sha256(envelope.encoded()), acknowledgements: acks))
    }
    for dtype in ["bfloat16", "float16", "float32"] {
        for frame in frames {
            let expected = try expectation(frame, dtype: dtype)
            let payload = Data(repeating: 19, count: expected.byteCount)
            let boundary = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
            let envelope = try Envelope(boundary: boundary, expected: expected)
            let decoded = try Envelope.decode(envelope.encoded(), expected: expected)
            guard decoded == envelope, decoded.boundary == boundary else { throw ProbeError("Lookahead round trip changed identity") }
            try decoded.boundary.validatePayload(payload)
            try capture(decoded, variant: "canonical")
        }
    }
    let expected = try expectation(frames[0])
    let payload = Data(repeating: 19, count: expected.byteCount)
    let boundary = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
    let envelope = try Envelope(boundary: boundary, expected: expected)
    let encoded = envelope.encoded(), text = String(decoding: encoded, as: UTF8.self)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    func replace(_ original: String, _ replacement: String) throws -> Data {
        guard text.contains(original) else { throw ProbeError("Lookahead test replacement did not select original bytes") }
        return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
    }
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejections.append(label); return }
        throw ProbeError("Lookahead codec admitted " + label)
    }
    func rejectData(_ label: String, _ data: Data) throws {
        try reject(label) { _ = try Envelope.decode(data, expected: expected) }
    }
    func rejectObject(_ label: String, _ change: (inout [String: Any]) -> Void) throws {
        var changed = object; change(&changed)
        try rejectData(label, JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]))
    }
    func rejectNested(_ label: String, _ change: (inout [String: Any]) -> Void) throws {
        try rejectObject(label) { outer in
            var nested = outer["boundary"] as! [String: Any]; change(&nested); outer["boundary"] = nested
        }
    }
    for (variant, data) in [
        ("surrounding_whitespace", Data(" \n".utf8) + encoded + Data("\t".utf8)),
        ("integer_negative_zero", try replace("\"tokenOffset\":0", "\"tokenOffset\":-0")),
        ("exact_byte_limit", encoded + Data(repeating: 32, count: Envelope.maximumEncodedBytes - encoded.count)),
    ] {
        let decoded = try Envelope.decode(data, expected: expected)
        guard decoded.boundary == boundary, decoded.encoded() == data, decoded.encoded() != encoded,
              ACK.values(envelope: decoded, phase: .ready) != ACK.values(envelope: envelope, phase: .ready) else {
            throw ProbeError("Lookahead decoder canonicalized exact outer bytes before ACK binding")
        }
        try capture(decoded, variant: variant)
        try reject("canonical ACK replay into " + variant) {
            try ACK.validate(ACK.values(envelope: envelope, phase: .ready), envelope: decoded, phase: .ready)
        }
    }
    try rejectData("bare v1 into lookahead v2", boundary.encoded())
    try reject("lookahead v2 into bare v1") { _ = try QwenLayerStageBoundaryWireHeader.decode(encoded, expected: expected) }
    for flow in ["strict_v1", "prompt_lookahead_two_v1", "prompt_lookahead_one_v2", ""] {
        try rejectObject("incompatible flow " + flow) { $0["flow"] = flow }
    }
    try rejectObject("numeric flow") { $0["flow"] = 1 }
    try rejectObject("outer version 1") { $0["version"] = 1 }
    try rejectObject("outer boolean version") { $0["version"] = true }
    try rejectObject("missing outer flow") { $0.removeValue(forKey: "flow") }
    try rejectObject("extra outer field") { $0["unexpected"] = 1 }
    try rejectObject("nonobject nested boundary") { $0["boundary"] = [] }
    try rejectNested("extra nested field") { $0["unexpected"] = 1 }
    try rejectNested("missing nested byteCount") { $0.removeValue(forKey: "byteCount") }
    try rejectNested("nested version 2") { $0["version"] = 2 }
    try rejectNested("boolean nested count") { $0["byteCount"] = true }
    try rejectNested("boolean shape dimension") { $0["shape"] = [true, 32, 128] as [Any] }
    try rejectNested("numeric finalPromptChunk") {
        var frame = $0["frame"] as! [String: Any]; frame["finalPromptChunk"] = 0; $0["frame"] = frame
    }
    try rejectNested("boolean frame sequence") {
        var frame = $0["frame"] as! [String: Any]; frame["sequence"] = true; $0["frame"] = frame
    }
    try rejectNested("extra frame field") {
        var frame = $0["frame"] as! [String: Any]; frame["extra"] = false; $0["frame"] = frame
    }
    try rejectNested("missing frame sequence") {
        var frame = $0["frame"] as! [String: Any]; frame.removeValue(forKey: "sequence"); $0["frame"] = frame
    }
    for (original, bad) in [
        ("\"version\":2", "\"version\":2.0"), ("\"version\":2", "\"version\":2e0"),
        ("\"version\":1", "\"version\":1.0"), ("\"byteCount\":8192", "\"byteCount\":8192.0"),
        ("\"byteCount\":8192", "\"byteCount\":8192e0"), ("\"byteCount\":8192", "\"byteCount\":9223372036854775808"),
        ("\"sequence\":0", "\"sequence\":0.0"), ("\"tokenOffset\":0", "\"tokenOffset\":0E0"),
        ("\"tokenCount\":32", "\"tokenCount\":32.0"), ("\"shape\":[1,32,128]", "\"shape\":[1.0,32,128]"),
        ("\"shape\":[1,32,128]", "\"shape\":[1,32e0,128]"), ("\"shape\":[1,32,128]", "\"shape\":[1,32,128.0]"),
        ("\"version\":2", "\"version\":02"), ("\"version\":2", "\"version\":200000000000000000000"),
        ("\"version\":2", "\"version\":NaN"),
    ] { try rejectData("raw integer lexeme " + bad, replace(original, bad)) }
    for malformed in [
        "{\"version\":2," + String(text.dropFirst()),
        "{\"\\u0076ersion\":2," + String(text.dropFirst()),
        text.replacingOccurrences(of: "\"boundary\":{", with: "\"boundary\":{\"version\":1,"),
        text.replacingOccurrences(of: "\"boundary\":{", with: "\"boundary\":{\"\\u0076ersion\":1,"),
        text.replacingOccurrences(of: "\"frame\":{", with: "\"frame\":{\"sequence\":0,"),
        text.replacingOccurrences(of: "\"frame\":{", with: "\"frame\":{\"seque\\u006ece\":0,"),
        text + " null", "[]", "null", "", String(text.dropLast()),
        String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66),
    ].enumerated() { try rejectData("raw malformed JSON \(malformed.offset)", Data(malformed.element.utf8)) }
    try rejectData("invalid UTF8", Data([0xff, 0xfe]))
    try rejectData("over byte bound", encoded + Data(repeating: 32, count: Envelope.maximumEncodedBytes + 1 - encoded.count))
    try reject("sender actual header differs from local tokens") {
        let different = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frames[0], tokenIDs: Array(repeating: 8, count: 32),
            sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
        _ = try Envelope(boundary: boundary, expected: different)
    }
    try reject("receiver local frame replay") { _ = try Envelope.decode(encoded, expected: expectation(frames[1])) }
    for actual in ACK.Phase.allCases {
        for expectedPhase in ACK.Phase.allCases where actual != expectedPhase {
            try reject("ACK phase \(actual.rawValue) replay into \(expectedPhase.rawValue)") {
                try ACK.validate(ACK.values(envelope: envelope, phase: actual), envelope: envelope, phase: expectedPhase)
            }
        }
    }
    let changed = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: String(repeating: "f", count: 64))
    let other = try Envelope(boundary: changed, expected: expected)
    for phase in ACK.Phase.allCases {
        try reject("ACK changed header replay " + phase.rawValue) {
            try ACK.validate(ACK.values(envelope: envelope, phase: phase), envelope: other, phase: phase)
        }
    }
    try reject("bare v1 ACK into v2") {
        try ACK.validate(QwenLayerStageWireAcknowledgement.values(header: boundary.encoded(), phase: .ready), envelope: envelope, phase: .ready)
    }
    try reject("v2 ACK into bare v1") {
        try QwenLayerStageWireAcknowledgement.validate(ACK.values(envelope: envelope, phase: .ready), header: boundary.encoded(), phase: .ready)
    }
    try reject("bare v1 namespace using same outer bytes") {
        try ACK.validate(QwenLayerStageWireAcknowledgement.values(header: encoded, phase: .ready), envelope: envelope, phase: .ready)
    }
    try reject("short ACK") { try ACK.validate(Array(ACK.values(envelope: envelope, phase: .ready).dropLast()), envelope: envelope, phase: .ready) }
    try reject("oversize ACK") { try ACK.validate(ACK.values(envelope: envelope, phase: .ready) + [0], envelope: envelope, phase: .ready) }
    try reject("out of range ACK element") {
        var values = ACK.values(envelope: envelope, phase: .ready); values[0] = Int32.max
        try ACK.validate(values, envelope: envelope, phase: .ready)
    }
    guard vectors.count == 21, Set(rejections).count == rejections.count else { throw ProbeError("Lookahead codec coverage changed") }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_lookahead_wire_check"
        let cpuOnly = true
        let flow = Envelope.flow
        let acceptedEnvelopeCases: Int
        let rejectedFixtures: Int
        let rejectionLabels: [String]
        let vectors: [Vector]?
    }
    try emitJSON(Result(acceptedEnvelopeCases: vectors.count, rejectedFixtures: rejections.count,
        rejectionLabels: rejections, vectors: includeVectors ? vectors : nil))
}


try checkQwenLayerStageBoundaryWire()
try checkQwenLayerStageLookaheadWire(includeVectors: true)
