import Foundation

/// What `darkbloom cluster status` and the console show of this Mac's cluster
/// observability files (PROD-PLAN S24), read from disk without contacting any
/// process: the open incidents with their guidance, the leader's recent pair
/// telemetry, and the other members' mirrored status with its age. Reading
/// never fails; a missing file is an absent section.
public struct ClusterObservabilitySnapshot: Codable, Sendable, Equatable {
    public static let shownIncidents = 5
    public static let shownRequests = 5

    public struct Incidents: Codable, Sendable, Equatable {
        public let epoch: String
        public let latestSeq: UInt64
        public let open: Int
        public let total: Int
        public let loadError: String?
        /// Open incidents, newest first, at most `shownIncidents`.
        public let recent: [ClusterIncident]
        /// The guidance of each code in `recent`.
        public let guidance: [ClusterGuidance]
    }

    public struct Telemetry: Codable, Sendable, Equatable {
        public let sessionID: String
        public let updatedAt: Double
        public let summary: ClusterPairTelemetrySummary
        /// Newest first, at most `shownRequests`.
        public let recent: [ClusterPairRequestTelemetry]
    }

    public struct Followers: Codable, Sendable, Equatable {
        public let updatedAt: Double
        public let entries: [ClusterLinkStatusBoard.Entry]
    }

    /// The speed records the leader kept from served requests, by route.
    public struct SpeedRecords: Codable, Sendable, Equatable {
        public let updatedAt: Double
        public let records: Int
        /// Records per route label (`pair`, `alone:<member>`).
        public let byRoute: [String: Int]
    }

    public let incidents: Incidents?
    public let telemetry: Telemetry?
    public let followers: Followers?
    public var speedRecords: SpeedRecords?

    public init(incidents: Incidents?, telemetry: Telemetry?, followers: Followers?, speedRecords: SpeedRecords? = nil) {
        self.incidents = incidents; self.telemetry = telemetry; self.followers = followers; self.speedRecords = speedRecords
    }

    /// Reads the three files under `homeDirectory/.darkbloom/cluster/`.
    public static func read(homeDirectory: URL, now: Double = Date().timeIntervalSince1970,
                            staleAfterSeconds: Double = ClusterLinkStatusBoard.defaultStaleAfterSeconds) -> ClusterObservabilitySnapshot {
        let feed = ClusterIncidentLog(file: ClusterIncidentLog.defaultFile(homeDirectory: homeDirectory)).feed()
        let incidents: Incidents?
        if feed.epoch.isEmpty && feed.loadError == nil {
            incidents = nil
        } else {
            let open = feed.open
            let recent = Array(open.prefix(shownIncidents))
            var codes: [String] = []
            for code in recent.compactMap(\.guidanceCode) where !codes.contains(code) { codes.append(code) }
            incidents = .init(epoch: feed.epoch, latestSeq: feed.latestSeq, open: open.count, total: feed.incidents.count,
                              loadError: feed.loadError, recent: recent, guidance: codes.compactMap(ClusterGuidance.guidance(code:)))
        }
        let telemetry = ClusterPairTelemetryLog.read(ClusterPairTelemetryLog.defaultFile(homeDirectory: homeDirectory)).map {
            Telemetry(sessionID: $0.sessionID, updatedAt: $0.updatedAt, summary: $0.summary,
                      recent: Array($0.records.suffix(shownRequests).reversed()))
        }
        let followers = ClusterLinkStatusBoardFile.read(ClusterLinkStatusBoardFile.defaultFile(homeDirectory: homeDirectory)).map { file in
            Followers(updatedAt: file.updatedAt, entries: file.entries.map { entry in
                let age = max(0, now - entry.receivedAt)
                return .init(status: entry.status, receivedAt: entry.receivedAt, stale: age > staleAfterSeconds,
                             ageSeconds: (age * 10).rounded() / 10)
            })
        }
        let speed = ClusterServedSpeedFile.read(ClusterServedSpeedFile.defaultFile(homeDirectory: homeDirectory)).map { file in
            SpeedRecords(updatedAt: file.updatedAt, records: file.records.count,
                byRoute: Dictionary(file.records.map { ($0.route ?? "pair", 1) }, uniquingKeysWith: +))
        }
        return .init(incidents: incidents, telemetry: telemetry, followers: followers, speedRecords: speed)
    }

    public var isEmpty: Bool { incidents == nil && telemetry == nil && followers == nil && speedRecords == nil }

    /// Plain lines for a terminal: what each section says, newest first.
    public var lines: [String] {
        var result: [String] = []
        if let incidents {
            result.append("Incidents: \(incidents.open) open of \(incidents.total) recorded (log epoch \(incidents.epoch.isEmpty ? "none" : incidents.epoch))"
                + (incidents.loadError.map { "; the log could not be read: \($0)" } ?? ""))
            for incident in incidents.recent {
                let when = ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: incident.ts), timeZone: .init(identifier: "UTC")!,
                                                       formatOptions: [.withInternetDateTime])
                result.append("  #\(incident.seq) \(when) \(incident.severity.rawValue) \(incident.stateCode)"
                    + (incident.reasonCode.map { " reason=\($0)" } ?? "") + (incident.guidanceCode.map { " guidance=\($0)" } ?? "")
                    + (incident.rank.map { " rank=\($0)" } ?? "") + " [\(incident.source)]")
                result.append("    \(incident.message)")
            }
            for guidance in incidents.guidance {
                result.append("  \(guidance.code): \(guidance.title). " + (guidance.steps.first ?? ""))
            }
        }
        if let telemetry {
            let s = telemetry.summary
            var line = "Pair requests (this session): \(s.requests), completed \(s.completed)"
            if let value = s.medianFirstTokenMilliseconds { line += "; median first token \(format(value)) ms" }
            if let value = s.medianDecodeTokensPerSecond { line += "; median decode \(format(value)) tok/s" }
            if let value = s.medianHandoffMilliseconds { line += "; median hand-off \(format(value)) ms" }
            if let value = s.mtpAcceptance { line += "; MTP acceptance \(format(value * 100))%" }
            line += "; cached prompt tokens \(s.cachedTokens) over \(s.requestsWithCacheHit) request\(s.requestsWithCacheHit == 1 ? "" : "s")"
            result.append(line)
            for record in telemetry.recent {
                var text = "  \(record.mode) cut \(record.cut)" + (record.route.map { " route \($0)" } ?? "")
                    + ": \(record.promptTokens) prompt (\(record.cachedTokens) cached), \(record.completionTokens) out, \(record.outcome)"
                if let value = record.firstTokenMilliseconds { text += "; first token \(format(value)) ms" }
                if let value = record.decodeTokensPerSecond { text += "; decode \(format(value)) tok/s" }
                if let value = record.handoffMilliseconds { text += "; hand-off \(format(value)) ms" }
                if let value = record.mtpAcceptance { text += "; MTP \(record.mtpAccepted ?? 0)/\(record.mtpDrafted ?? 0) (\(format(value * 100))%)" }
                result.append(text)
                if let reason = record.routeReason { result.append("    route: " + reason) }
            }
        }
        if let speedRecords {
            result.append("Speed records from served requests (the next plan and every route use them): \(speedRecords.records), "
                + speedRecords.byRoute.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if let followers {
            for entry in followers.entries {
                let s = entry.status
                var text = "Rank \(s.rank) (mirrored over the link): \(s.state.rawValue)\(entry.stale ? ", STALE" : "") \(format(entry.ageSeconds)) s ago"
                if let model = s.modelID { text += "; model \(model)" }
                if let free = s.freeMemoryBytes { text += "; free \(gib(free)) GiB" }
                if let wired = s.wiredMemoryBytes { text += "; wired \(gib(wired)) GiB" }
                if let thermal = s.thermalState { text += "; thermal \(thermal)" }
                if let served = s.requestsServed { text += "; requests \(served)" }
                text += s.linkReady ? "; link ready" : "; link NOT ready"
                if !s.detail.isEmpty { text += "; \(s.detail)" }
                result.append(text)
                for incident in s.incidents ?? [] {
                    result.append("    its incident #\(incident.seq) \(incident.stateCode)" + (incident.reasonCode.map { " reason=\($0)" } ?? ""))
                }
            }
        }
        return result
    }

    private func format(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    private func gib(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / Double(1 << 30)) }
}
