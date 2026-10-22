import Foundation

/// Append-only JSON-lines event log in the runner's state directory, mirrored to
/// stderr. Every line carries wall-clock time and seconds since runner start.
final class RunnerEventLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let handle: FileHandle
    private let start = ContinuousClock.now
    private static let wallClock = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw RunnerFailure.isolation("cannot create event log \(url.path)")
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }

    var elapsed: Duration { ContinuousClock.now - start }

    func emit(_ event: String, _ fields: [String: RunnerJSON] = [:]) {
        var line = fields
        line["event"] = .string(event)
        line["t_s"] = .seconds(elapsed)
        line["wall"] = .string(Date().formatted(Self.wallClock))
        var data = RunnerJSON.object(line).encoded()
        data.append(0x0A)
        lock.withLock {
            handle.write(data)
            FileHandle.standardError.write(data)
        }
    }
}

enum RunnerFailure: Error, CustomStringConvertible {
    case isolation(String)
    case checkpoint(String)
    case serve(String)

    var description: String {
        switch self {
        case .isolation(let reason): "isolation: \(reason)"
        case .checkpoint(let reason): "checkpoint: \(reason)"
        case .serve(let reason): "serve: \(reason)"
        }
    }
}
