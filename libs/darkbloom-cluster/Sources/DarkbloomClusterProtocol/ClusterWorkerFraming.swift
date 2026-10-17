import Foundation

/// Incremental line framing with one bounded unfinished record. The pipe owner
/// calls this on a serial executor and bounds each read to readChunkBytes.
public struct ClusterWorkerLineDecoder: Sendable {
    public static let readChunkBytes = 65_536
    private let maximumRecordBytes: Int
    private var pending = Data()
    private var failed = false
    private var ended = false
    public init(commandStream: Bool) {
        maximumRecordBytes = commandStream ? ClusterWorkerLimits.commandBytes : ClusterWorkerLimits.eventBytes
    }
    public mutating func append(_ data: Data) throws -> [Data] {
        do {
            try workerRequire(!failed && !ended && data.count <= Self.readChunkBytes, "Framer failed, ended or read chunk exceeds bound")
            var records: [Data] = []
            for byte in data {
                try workerRequire(pending.count < maximumRecordBytes, "Unterminated worker record exceeds limit")
                pending.append(byte)
                if byte == 10 {
                    try workerRequire(pending.count > 1, "Empty worker record")
                    records.append(pending); pending = Data()
                }
            }
            return records
        } catch { failed = true; throw error }
    }
    /// EOF is framing completion only. It never acknowledges request retirement.
    public mutating func finish() throws {
        do { try workerRequire(!failed && !ended && pending.isEmpty, "EOF interrupted a worker record"); ended = true }
        catch { failed = true; throw error }
    }
}
