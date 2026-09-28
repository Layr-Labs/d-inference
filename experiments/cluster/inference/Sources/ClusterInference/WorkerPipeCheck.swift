import Dispatch
import Foundation

/// The fallback closes only a stalled test writer, releasing implementations
/// that incorrectly wait for 4 KiB or EOF instead of returning a short frame.
private final class WorkerPipeDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: FileHandle
    private var completed = false
    private var expired = false

    init(writer: FileHandle) { self.writer = writer }

    func expireIfWaiting() {
        lock.lock()
        let shouldClose = !completed
        if shouldClose { expired = true }
        lock.unlock()
        if shouldClose { try? writer.close() }
    }

    func finish() -> Bool {
        lock.lock()
        completed = true
        let returnedBeforeDeadline = !expired
        lock.unlock()
        return returnedBeforeDeadline
    }
}

func checkWorkerShortPipeFrame() throws {
    let pipe = Pipe()
    defer {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
    let command = WorkerCommand.shutdown(WorkerShutdown(epoch: String(repeating: "b", count: 32), sequence: 1))
    let frame = try command.canonicalData()
    guard frame.count < 4096,
          String(decoding: frame, as: UTF8.self).contains("\"version\":5") else {
        throw ProbeError("Short-pipe fixture must contain a v4 command smaller than a read chunk")
    }
    try pipe.fileHandleForWriting.write(contentsOf: frame + Data([10]))
    // Keep the writer open while next() runs. File-backed framing tests cannot
    // detect a read that requires EOF; this actual pipe must return before EOF.
    let deadline = WorkerPipeDeadline(writer: pipe.fileHandleForWriting)
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
        deadline.expireIfWaiting()
    }
    defer { _ = deadline.finish() }
    let received = try WorkerLineReader(handle: pipe.fileHandleForReading).next()
    guard deadline.finish(), received == frame,
        try WorkerCommand.decode(received!).canonicalData() == frame else {
        throw ProbeError("Worker short pipe frame required writer closure or lost command bytes")
    }
}
