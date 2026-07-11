import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

public struct InferenceActivityState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public let schema: Int
    public let pid: Int32
    public let processIdentity: ProcessIdentity?
    public let writtenAt: Double
    public let activeRequestCount: Int

    public init(
        schema: Int = Self.currentSchema,
        pid: Int32,
        processIdentity: ProcessIdentity?,
        writtenAt: Double,
        activeRequestCount: Int
    ) {
        self.schema = schema
        self.pid = pid
        self.processIdentity = processIdentity
        self.writtenAt = writtenAt
        self.activeRequestCount = activeRequestCount
    }
}

public enum InferenceActivityFile {
    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment[
            "DARKBLOOM_INFERENCE_ACTIVITY_FILE"
        ], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
            .appendingPathComponent("inference-activity.json")
    }

    public static func read(
        from url: URL = path()
    ) -> InferenceActivityState? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 16_384 else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let state = try? decoder.decode(
            InferenceActivityState.self,
            from: data
        ), state.schema == InferenceActivityState.currentSchema else {
            return nil
        }
        return state
    }

    static func write(
        _ state: InferenceActivityState,
        to url: URL = path()
    ) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            // Inference must continue if this optional local signal is unavailable.
        }
    }
}

public final class InferenceActivityTracker: @unchecked Sendable {
    public static let shared = InferenceActivityTracker()

    private let lock = NSLock()
    private let path: URL
    private var requestIDs: Set<String> = []
    private var refreshTimer: DispatchSourceTimer!

    init(path: URL = InferenceActivityFile.path()) {
        self.path = path
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "io.darkbloom.provider.inference-activity"
            )
        )
        refreshTimer = timer
        timer.schedule(
            deadline: .now() + 5,
            repeating: 5,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.refreshIfActive()
        }
        timer.resume()
    }

    deinit {
        refreshTimer.cancel()
    }

    public func begin(_ requestID: String) {
        lock.withLock {
            guard requestIDs.insert(requestID).inserted else { return }
            persist()
        }
    }

    public func end(_ requestID: String) {
        lock.withLock {
            guard requestIDs.remove(requestID) != nil else { return }
            persist()
        }
    }

    private func persist() {
        InferenceActivityFile.write(
            InferenceActivityState(
                pid: getpid(),
                processIdentity: ProcessIdentity.current(),
                writtenAt: Date().timeIntervalSince1970,
                activeRequestCount: requestIDs.count
            ),
            to: path
        )
    }

    private func refreshIfActive() {
        lock.withLock {
            guard !requestIDs.isEmpty else { return }
            persist()
        }
    }
}
