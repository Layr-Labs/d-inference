import Foundation
#if canImport(os)
import os
#endif

/// Process-wide, local-only analytics entry point.
///
/// Disabled until explicitly configured. Recording is synchronous only long
/// enough to reserve a bounded queue slot; all JSON and filesystem work runs on
/// a utility queue and can never block inference.
public final class LocalAnalytics: @unchecked Sendable {
    public static let shared = LocalAnalytics()
    public static let defaultQueueCapacity = 1_000
    public static let defaultRotationInterval: TimeInterval = 60
    public static let defaultRotationBytes = 16 * 1_024 * 1_024

    private let lock = NSLock()
    private var writer: LocalAnalyticsWriter?
    public let processEpoch = UUID().uuidString.lowercased()

    private init() {}

    public func configure(enabled: Bool, rootURL: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else {
            writer?.shutdown()
            writer = nil
            return
        }
        guard writer == nil else { return }
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom", isDirectory: true)
            .appendingPathComponent("analytics", isDirectory: true)
        writer = LocalAnalyticsWriter(rootURL: root)
    }

    public func record(_ event: LocalAnalyticsEvent) {
        lock.lock()
        let writer = self.writer
        lock.unlock()
        writer?.record(event)
    }

    public func flush() {
        lock.lock()
        let writer = self.writer
        lock.unlock()
        writer?.flush()
    }

    public func shutdown() {
        lock.lock()
        let writer = self.writer
        self.writer = nil
        lock.unlock()
        writer?.shutdown()
    }
}

final class LocalAnalyticsWriter: @unchecked Sendable {
    private let rootURL: URL
    private let activeURL: URL
    private let readyURL: URL
    private let stateURL: URL
    private let queueCapacity: Int
    private let rotationInterval: TimeInterval
    private let rotationBytes: Int
    private let queue = DispatchQueue(label: "dev.darkbloom.local-analytics", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingCount = 0
    private var droppedEvents: UInt64 = 0
    private var writeFailures: UInt64 = 0
    private var handle: FileHandle?
    private var segmentStartedAt: Date?
    private var segmentBytes = 0
    private var timer: DispatchSourceTimer?

    #if canImport(os)
    private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "local-analytics")
    #endif

    init(
        rootURL: URL,
        queueCapacity: Int = LocalAnalytics.defaultQueueCapacity,
        rotationInterval: TimeInterval = LocalAnalytics.defaultRotationInterval,
        rotationBytes: Int = LocalAnalytics.defaultRotationBytes
    ) {
        self.rootURL = rootURL
        self.activeURL = rootURL.appendingPathComponent("events/active", isDirectory: true)
        self.readyURL = rootURL.appendingPathComponent("events/ready", isDirectory: true)
        self.stateURL = rootURL.appendingPathComponent("state/writer-state.json")
        self.queueCapacity = max(1, queueCapacity)
        self.rotationInterval = max(1, rotationInterval)
        self.rotationBytes = max(1_024, rotationBytes)

        queue.sync {
            do {
                try prepareWorkspace()
                try recoverOpenSegment()
            } catch {
                noteWriteFailure(error)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.periodicMaintenance() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        try? handle?.close()
    }

    func record(_ event: LocalAnalyticsEvent) {
        pendingLock.lock()
        guard pendingCount < queueCapacity else {
            droppedEvents &+= 1
            pendingLock.unlock()
            return
        }
        pendingCount += 1
        pendingLock.unlock()

        queue.async { [weak self] in
            defer {
                self?.pendingLock.lock()
                self?.pendingCount -= 1
                self?.pendingLock.unlock()
            }
            self?.append(event)
        }
    }

    func flush() {
        queue.sync {
            do { try handle?.synchronize() } catch { noteWriteFailure(error) }
        }
    }

    func shutdown() {
        timer?.cancel()
        queue.sync {
            do {
                try rotateIfNeeded(force: true)
                try writeState()
            } catch {
                noteWriteFailure(error)
            }
        }
    }

    private func append(_ event: LocalAnalyticsEvent) {
        do {
            try rotateIfNeeded(at: event.eventAt)
            try openSegmentIfNeeded(at: event.eventAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            try handle?.write(contentsOf: data)
            segmentBytes += data.count
            if segmentBytes >= rotationBytes {
                try rotateIfNeeded(force: true)
            }
        } catch {
            noteWriteFailure(error)
        }
    }

    private func prepareWorkspace() throws {
        for directory in [
            rootURL,
            rootURL.appendingPathComponent("events", isDirectory: true),
            activeURL,
            readyURL,
            rootURL.appendingPathComponent("events/quarantine", isDirectory: true),
            rootURL.appendingPathComponent("parquet", isDirectory: true),
            rootURL.appendingPathComponent("parquet/jobs", isDirectory: true),
            rootURL.appendingPathComponent("parquet/hourly-rollups", isDirectory: true),
            rootURL.appendingPathComponent("state", isDirectory: true),
            rootURL.appendingPathComponent("state/manifests", isDirectory: true),
            rootURL.appendingPathComponent("tmp", isDirectory: true),
            rootURL.appendingPathComponent("rill", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private var openURL: URL { activeURL.appendingPathComponent("current.open.jsonl") }

    private func openSegmentIfNeeded(at date: Date) throws {
        guard handle == nil else { return }
        if !FileManager.default.fileExists(atPath: openURL.path) {
            FileManager.default.createFile(
                atPath: openURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        handle = try FileHandle(forWritingTo: openURL)
        try handle?.seekToEnd()
        segmentBytes = Int((try? handle?.offset()) ?? 0)
        segmentStartedAt = date
    }

    private func periodicMaintenance() {
        do {
            try handle?.synchronize()
            try rotateIfNeeded(at: Date())
        } catch {
            noteWriteFailure(error)
        }
    }

    private func rotateIfNeeded(at now: Date = Date(), force: Bool = false) throws {
        guard let started = segmentStartedAt, handle != nil else { return }
        let crossedHour = Calendar(identifier: .iso8601).component(.hour, from: started)
            != Calendar(identifier: .iso8601).component(.hour, from: now)
            || !Calendar(identifier: .iso8601).isDate(started, inSameDayAs: now)
        guard force || crossedHour || now.timeIntervalSince(started) >= rotationInterval else { return }

        try handle?.synchronize()
        try handle?.close()
        handle = nil

        if segmentBytes > 0 {
            let destination = try readySegmentURL(startedAt: started)
            try FileManager.default.moveItem(at: openURL, to: destination)
        } else {
            try? FileManager.default.removeItem(at: openURL)
        }
        segmentStartedAt = nil
        segmentBytes = 0
        try writeState()
    }

    private func readySegmentURL(startedAt: Date) throws -> URL {
        let day = Self.format(startedAt, pattern: "yyyy-MM-dd")
        let stamp = Self.format(startedAt, pattern: "yyyyMMdd'T'HHmmss'Z'")
        let directory = readyURL.appendingPathComponent("date=\(day)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(
            "events-\(stamp)-\(UUID().uuidString.lowercased()).jsonl")
    }

    private func recoverOpenSegment() throws {
        guard FileManager.default.fileExists(atPath: openURL.path) else { return }
        let data = try Data(contentsOf: openURL)
        guard !data.isEmpty else {
            try FileManager.default.removeItem(at: openURL)
            return
        }
        let lastNewline = data.lastIndex(of: 0x0A)
        if let lastNewline {
            let complete = data.prefix(through: lastNewline)
            let destination = try readySegmentURL(startedAt: Date())
            try Data(complete).write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        if let lastNewline, data.index(after: lastNewline) < data.endIndex {
            let trailing = data.suffix(from: data.index(after: lastNewline))
            let quarantine = rootURL.appendingPathComponent("events/quarantine", isDirectory: true)
                .appendingPathComponent("incomplete-\(UUID().uuidString.lowercased()).json")
            try Data(trailing).write(to: quarantine, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quarantine.path)
        }
        try FileManager.default.removeItem(at: openURL)
    }

    private func writeState() throws {
        pendingLock.lock()
        let state: [String: Any] = [
            "schema_version": 1,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
            "dropped_events": droppedEvents,
            "write_failures": writeFailures,
            "pending_events": pendingCount,
        ]
        pendingLock.unlock()
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func noteWriteFailure(_ error: Error) {
        pendingLock.lock()
        writeFailures &+= 1
        pendingLock.unlock()
        #if canImport(os)
        logger.error("Local analytics write failed: \(String(describing: type(of: error)), privacy: .public)")
        #endif
    }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
