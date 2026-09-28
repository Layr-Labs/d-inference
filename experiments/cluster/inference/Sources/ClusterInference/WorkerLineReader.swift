import Darwin
import Foundation

/// JSONL framing bounds command bytes (excluding LF) and requires a newline at
/// EOF. Reading in 4 KiB chunks bounds buffering even for an untrusted producer.
final class WorkerLineReader {
    private let handle: FileHandle
    private var buffered = Data()
    private var scannedBytes = 0
    private var atEOF = false

    init(handle: FileHandle = .standardInput) { self.handle = handle }

    func next() throws -> Data? {
        while true {
            if let newline = buffered.dropFirst(scannedBytes).firstIndex(of: 10) {
                let count = buffered.distance(from: buffered.startIndex, to: newline)
                guard count <= workerMaximumLineBytes else { throw ProbeError("Worker JSONL frame exceeds 2 MiB") }
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                scannedBytes = 0
                return line
            }
            scannedBytes = buffered.count
            guard buffered.count <= workerMaximumLineBytes else { throw ProbeError("Worker JSONL frame exceeds 2 MiB") }
            if atEOF {
                guard buffered.isEmpty else { throw ProbeError("Worker stdin ended inside a JSONL frame") }
                return nil
            }
            // Foundation's read(upToCount:) can wait to fill the requested
            // count on a pipe. POSIX read returns currently available bytes,
            // so a short LF-terminated command needs neither 4 KiB nor EOF.
            var chunk = [UInt8](repeating: 0, count: 4096)
            let (count, errorNumber) = chunk.withUnsafeMutableBytes { bytes -> (Int, Int32) in
                let count = Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                return (count, count < 0 ? errno : 0)
            }
            if count < 0 {
                if errorNumber == EINTR { continue }
                throw ProbeError("Worker stdin read failed (errno \(errorNumber))")
            }
            if count == 0 { atEOF = true }
            else { buffered.append(contentsOf: chunk.prefix(count)) }
        }
    }
}
