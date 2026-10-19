import CryptoKit
import Foundation

/// Closed public messages inside the existing encrypted exact-pair channel.
/// Decoding never creates Completed, Authorized, a native grant or an exit.
enum GLM5NextCalibrationDispatchWire {
    static let maximumBytes = 1 << 20
    static let maximumMessages: UInt64 = 128
    static let tag: UInt16 = 0x5E71
    enum Kind: String, Codable { case hello, quotation, document, start, commit, commitAck, launchBarrier, bootstrap, result, resultAck, cancel }
    struct Header: Codable, Equatable {
        let version: Int
        let purpose: String
        let pair: GLM5NextCalibrationPeerQuoteDocument.Pair
        let sessionID: UUID
        let epoch: UUID
        let requestID: UUID
        let expiresUnixSeconds: Int64
        let rank: Int
        let senderIncarnation: UUID
        let receiverIncarnation: UUID
        let connectionGeneration: UInt64
        let sequence: UInt64
    }
    struct Packet: Codable { let header: Header; let kind: Kind; let payload: Data }
    struct Empty: Codable {}
    struct Digest: Codable { let sha256: String }
    struct Bootstrap: Codable { let sequence: UInt64; let bytes: Data }
    struct Commit: Codable {
        let starts: [Data]
        let planSHA256: String
        let profileSHA256: String
        let matrixSHA256: String
        let coordinator: String
        let interface: String
        let device: String
    }
    enum Termination: String, Codable { case noLaunch, exited, signalled }
    struct Result: Codable {
        let commitSHA256: String
        let termination: Termination
        let code: Int32?
        let journalResolved: Bool
        let bootstrapCompleted: Bool
        let report: Data?
        let reportSHA256: String?
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(value)
        guard !data.isEmpty, data.count <= maximumBytes else { throw invalid("dispatch size") }
        return data
    }
    static func decode<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumBytes else { throw invalid("dispatch size") }
        let value = try JSONDecoder().decode(type, from: data)
        guard try canonical(value) == data else { throw invalid("dispatch unknown/noncanonical fields") }
        return value
    }
    static func validate(_ packet: Packet, expected: Header, now: Int64) throws {
        guard packet.header == expected, expected.version == 1, expected.purpose == "finiteCalibration",
              (0...1).contains(expected.rank), expected.sequence > 0, expected.sequence <= maximumMessages,
              expected.sessionID != zero, expected.epoch != zero, expected.requestID != zero,
              expected.senderIncarnation != zero, expected.receiverIncarnation != zero,
              expected.senderIncarnation != expected.receiverIncarnation, expected.connectionGeneration == 1,
              expected.expiresUnixSeconds > 0 else { throw invalid("dispatch route/sequence") }
        // Terminal cleanup evidence may arrive after execution expiry; it cannot
        // extend the finite operation, mint admission or permit another launch.
        if packet.kind != .result && packet.kind != .resultAck && packet.kind != .cancel {
            guard now >= 0, now < expected.expiresUnixSeconds else { throw invalid("dispatch expired") }
        }
    }
    static let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    static func hash(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func invalid(_ value: String) -> ClusterConfigurationError { GLM5NextCalibrationDocument.invalid(value) }
}
