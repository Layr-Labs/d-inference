import Foundation

/// Make OOM crashes visible. A jetsam SIGKILL is uncatchable and flushes no
/// telemetry, so OOMs surface only as a coordinator-side "read_error" disconnect.
/// Two best-effort detectors recover the signal: (1) a pre-death marker written
/// on critical memory pressure that the NEXT launch reports; (2) a launch scan of
/// ~/Library/Logs/DiagnosticReports for JetsamEvent/EXC_RESOURCE reports naming
/// our process. Tolerant: a parse failure never crashes startup.
public enum OOMDetector {

    // MARK: - Types

    /// Marker written just before a suspected OOM death (on critical pressure).
    public struct Marker: Codable, Equatable, Sendable {
        public var pid: Int32
        public var epochSeconds: Double
        public var peakMemoryBytes: UInt64
        public var availableBytesAtEvent: UInt64
        public var modelId: String?

        public init(pid: Int32, epochSeconds: Double, peakMemoryBytes: UInt64,
                    availableBytesAtEvent: UInt64, modelId: String? = nil) {
            self.pid = pid
            self.epochSeconds = epochSeconds
            self.peakMemoryBytes = peakMemoryBytes
            self.availableBytesAtEvent = availableBytesAtEvent
            self.modelId = modelId
        }
    }

    /// One detected OOM signal, ready to be turned into an `oom` telemetry event.
    public struct Finding: Equatable, Sendable {
        public enum Source: String, Sendable {
            case memoryPressureMarker = "memory_pressure_marker"
            case jetsamReport = "jetsam_report"
            case memoryCrashReport = "memory_crash_report"
        }
        public var source: Source
        public var message: String
        public var reason: String?
        public var peakMemoryBytes: UInt64?
        public var reportName: String?
        public var epochSeconds: Double?

        public init(source: Source, message: String, reason: String? = nil,
                    peakMemoryBytes: UInt64? = nil, reportName: String? = nil,
                    epochSeconds: Double? = nil) {
            self.source = source
            self.message = message
            self.reason = reason
            self.peakMemoryBytes = peakMemoryBytes
            self.reportName = reportName
            self.epochSeconds = epochSeconds
        }
    }

    // MARK: - Paths

    /// ~/.darkbloom/ — stable + daemon-writable (the /usr/local install dir may not be).
    public static func defaultMarkerURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".darkbloom").appendingPathComponent("oom_marker.json")
    }

    public static func defaultDiagnosticReportsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// Last-scan watermark: only reports newer than this are emitted, so a
    /// crashloop doesn't re-report the same JetsamEvent every launch.
    public static func defaultLastScanURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".darkbloom").appendingPathComponent("oom_last_scan")
    }

    public static func loadLastScan(at url: URL = defaultLastScanURL()) -> Date? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    public static func saveLastScan(_ date: Date, at url: URL = defaultLastScanURL()) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Marker I/O

    public static func writeMarker(_ marker: Marker, to url: URL = defaultMarkerURL()) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort: a marker we can't write just keeps this OOM invisible.
        }
    }

    /// Read the marker and delete it (consume-once) so the same event isn't
    /// reported on every subsequent launch.
    @discardableResult
    public static func readAndClearMarker(at url: URL = defaultMarkerURL()) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    // MARK: - Pure parsers (.ips reports)

    /// Parse a kernel `JetsamEvent-*.ips` (header line + JSON body with a
    /// `processes` array); finding iff our process was killed. Pure + tolerant.
    public static func parseJetsamReport(contents: String, processName: String) -> Finding? {
        guard let body = jsonBody(from: contents) else { return nil }
        let pageSize = (body["pageSize"] as? Int)
            ?? ((body["memoryStatus"] as? [String: Any])?["pageSize"] as? Int)
            ?? 16384
        guard let processes = body["processes"] as? [[String: Any]] else { return nil }
        let needle = processName.lowercased()
        for proc in processes {
            guard let name = proc["name"] as? String, name.lowercased().contains(needle) else { continue }
            let rpages = (proc["rpages"] as? Int) ?? (proc["pages"] as? Int) ?? 0
            let bytes = UInt64(max(0, rpages)) &* UInt64(max(0, pageSize))
            let reason = (proc["reason"] as? String) ?? (proc["killDelta"] as? String)
            return Finding(
                source: .jetsamReport,
                message: "jetsam killed \(name) (\(reason ?? "memory pressure"))",
                reason: reason,
                peakMemoryBytes: bytes > 0 ? bytes : nil)
        }
        return nil
    }

    /// Parse a process crash `.ips` for a memory kill: `EXC_RESOURCE` with a
    /// MEMORY subtype, or a JETSAM termination namespace. Pure + tolerant.
    public static func parseMemoryCrashReport(contents: String, processName: String) -> Finding? {
        guard let header = jsonHeader(from: contents) else { return nil }
        // Header names the app; only consider reports for our process.
        let appName = (header["app_name"] as? String) ?? (header["procName"] as? String) ?? ""
        guard appName.lowercased().contains(processName.lowercased()) else { return nil }
        guard let body = jsonBody(from: contents) else { return nil }

        if let exception = body["exception"] as? [String: Any] {
            let type = (exception["type"] as? String) ?? ""
            let subtype = (exception["subtype"] as? String) ?? ""
            if type.contains("EXC_RESOURCE") && subtype.uppercased().contains("MEMORY") {
                return Finding(
                    source: .memoryCrashReport,
                    message: "\(appName) hit memory resource limit (\(subtype))",
                    reason: subtype)
            }
        }
        if let termination = body["termination"] as? [String: Any] {
            let namespace = (termination["namespace"] as? String) ?? ""
            if namespace.uppercased().contains("JETSAM") {
                let reason = (termination["indicator"] as? String) ?? namespace
                return Finding(
                    source: .memoryCrashReport,
                    message: "\(appName) terminated by jetsam (\(reason))",
                    reason: reason)
            }
        }
        return nil
    }

    // MARK: - Launch detection (I/O)

    /// Scan DiagnosticReports for OOM-relevant reports modified since `since`.
    /// Best-effort; returns [] on any directory/read error.
    public static func scanDiagnosticReports(
        dir: URL,
        processName: String,
        since: Date,
        fileManager: FileManager = .default
    ) -> [Finding] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }

        var findings: [Finding] = []
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "ips" || ext == "panic" else { continue }
            let name = url.lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < since { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let isJetsam = name.hasPrefix("JetsamEvent")
            var finding: Finding?
            if isJetsam {
                finding = parseJetsamReport(contents: contents, processName: processName)
            } else {
                finding = parseMemoryCrashReport(contents: contents, processName: processName)
            }
            if var f = finding {
                f.reportName = name
                f.epochSeconds = mtime?.timeIntervalSince1970
                findings.append(f)
            }
        }
        return findings
    }

    /// Full launch-time detection: consume any pre-death marker AND scan crash
    /// logs since `since`. Returns all findings to emit as `oom` telemetry.
    public static func detectOnLaunch(
        markerURL: URL = defaultMarkerURL(),
        diagnosticReportsDir: URL = defaultDiagnosticReportsURL(),
        processName: String = "darkbloom",
        since: Date,
        fileManager: FileManager = .default
    ) -> [Finding] {
        var findings: [Finding] = []
        if let marker = readAndClearMarker(at: markerURL) {
            findings.append(Finding(
                source: .memoryPressureMarker,
                message: "provider observed critical memory pressure before exit (likely OOM)",
                peakMemoryBytes: marker.peakMemoryBytes > 0 ? marker.peakMemoryBytes : nil,
                epochSeconds: marker.epochSeconds))
        }
        findings.append(contentsOf: scanDiagnosticReports(
            dir: diagnosticReportsDir, processName: processName, since: since, fileManager: fileManager))
        return findings
    }

    // MARK: - JSON helpers

    /// The first JSON object in an `.ips` document (the one-line header).
    static func jsonHeader(from contents: String) -> [String: Any]? {
        guard let firstLine = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// The JSON body of an `.ips`: whole-file if it parses, else after line 1.
    static func jsonBody(from contents: String) -> [String: Any]? {
        if let data = contents.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              let data = parts[1].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
