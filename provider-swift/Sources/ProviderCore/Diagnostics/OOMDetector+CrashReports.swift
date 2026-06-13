import Foundation

/// Pure `.ips` crash-report parsing for OOM detection. Split from OOMDetector
/// (which owns marker I/O + directory scanning) so the parsing logic — the
/// bulk of the test surface — stands alone. All functions are pure + tolerant:
/// malformed input returns nil, never throws.
extension OOMDetector {

    /// Parse a kernel `JetsamEvent-*.ips` (header line + JSON body with a
    /// `processes` array); finding iff OUR process was the one jetsam killed.
    ///
    /// A JetsamEvent lists the whole process table at the pressure event, not
    /// just the victim — so merely matching the name would flag a provider OOM
    /// any time darkbloom was resident during someone else's jetsam. Require a
    /// kill signal on our entry: a `reason` (carried by jetsammed processes) or
    /// being named the report's `largestProcess`.
    public static func parseJetsamReport(contents: String, processName: String) -> Finding? {
        guard let body = jsonBody(from: contents) else { return nil }
        let pageSize = (body["pageSize"] as? Int)
            ?? ((body["memoryStatus"] as? [String: Any])?["pageSize"] as? Int)
            ?? 16384
        guard let processes = body["processes"] as? [[String: Any]] else { return nil }
        let needle = processName.lowercased()
        let largest = (body["largestProcess"] as? String)?.lowercased()
        for proc in processes {
            guard let name = proc["name"] as? String, name.lowercased().contains(needle) else { continue }
            let reason = (proc["reason"] as? String) ?? (proc["killDelta"] as? String)
            let wasKilled = !(reason ?? "").isEmpty || (largest.map { name.lowercased().contains($0) } ?? false)
            guard wasKilled else { continue }   // present in the table but not the victim
            let rpages = (proc["rpages"] as? Int) ?? (proc["pages"] as? Int) ?? 0
            let bytes = UInt64(max(0, rpages)) &* UInt64(max(0, pageSize))
            return Finding(
                source: .jetsamReport,
                message: "jetsam killed \(name) (\(reason ?? "memory pressure"))",
                reason: reason,
                peakMemoryBytes: bytes > 0 ? bytes : nil)
        }
        return nil
    }

    /// Parse a process crash `.ips` for a memory kill: `EXC_RESOURCE` with a
    /// MEMORY subtype, or a JETSAM termination namespace.
    public static func parseMemoryCrashReport(contents: String, processName: String) -> Finding? {
        guard let header = jsonHeader(from: contents) else { return nil }
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
