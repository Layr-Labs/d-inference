import DarkbloomClusterRemote
import Foundation
#if canImport(Logging)
import Logging

private let clusterObservabilityLogger = Logger(label: "darkbloom.cluster.incidents")

/// One log line of the observability paths (fields are codes and counts).
func clusterObservabilityLog(_ level: ClusterObservabilityLogLevel, _ message: String, _ fields: [String: String] = [:]) {
    let metadata = fields.mapValues { Logger.MetadataValue.string($0) }
    switch level {
    case .info: clusterObservabilityLogger.info("\(message)", metadata: metadata)
    case .warning: clusterObservabilityLogger.warning("\(message)", metadata: metadata)
    case .error: clusterObservabilityLogger.error("\(message)", metadata: metadata)
    }
}
#else
/// The model-free check runners compile this file with plain swiftc, without
/// swift-log: there the lines are dropped.
func clusterObservabilityLog(_ level: ClusterObservabilityLogLevel, _ message: String, _ fields: [String: String] = [:]) {}
#endif

enum ClusterObservabilityLogLevel: Sendable { case info, warning, error }

/// This Mac's cluster observability files (PROD-PLAN S24), under
/// `~/.darkbloom/cluster/`: the durable incident log, the leader's pair
/// telemetry and the follower status the leader mirrors. Recording never
/// throws into the caller and never blocks a request: an incident that cannot
/// be written is logged and dropped.
public final class ClusterObservability: Sendable {
    public let homeDirectory: URL
    public let incidents: ClusterIncidentLog
    public let telemetryFile: URL
    public let followerStatusFile: URL
    private let localIdentifiers: ClusterDiagnosticRedaction.Identifiers

    public init(homeDirectory: URL, hostNames: [String] = ClusterObservability.localHostNames(),
                userNames: [String] = [NSUserName()]) {
        self.homeDirectory = homeDirectory
        let identifiers = ClusterDiagnosticRedaction.Identifiers(homeDirectories: [homeDirectory.path],
            userNames: userNames, hostNames: hostNames)
        localIdentifiers = identifiers
        let redaction = ClusterDiagnosticRedaction(identifiers: identifiers)
        incidents = ClusterIncidentLog(file: ClusterIncidentLog.defaultFile(homeDirectory: homeDirectory),
                                       redact: { redaction.redact($0) })
        telemetryFile = ClusterPairTelemetryLog.defaultFile(homeDirectory: homeDirectory)
        followerStatusFile = ClusterLinkStatusBoardFile.defaultFile(homeDirectory: homeDirectory)
    }

    /// For the user running this process.
    public static func current() -> ClusterObservability {
        .init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// This Mac's names, each only to be redacted from incident text.
    public static func localHostNames() -> [String] {
        let full = ProcessInfo.processInfo.hostName
        var names = [full]
        if let short = full.split(separator: ".").first { names.append(String(short)) }
        return Array(Set(names.filter { $0.count >= 3 && $0 != "localhost" }))
    }

    /// A redaction that also removes the peers' names a session's text may carry.
    public func redaction(peerHosts: [String] = [], peerUsers: [String] = []) -> ClusterDiagnosticRedaction {
        var identifiers = localIdentifiers
        identifiers.hostNames += peerHosts.filter { !$0.isEmpty }
        identifiers.userNames += peerUsers.filter { !$0.isEmpty }
        return .init(identifiers: identifiers)
    }

    /// A telemetry log for one serving session.
    public func telemetryLog(sessionID: String) -> ClusterPairTelemetryLog {
        .init(file: telemetryFile, sessionID: sessionID)
    }

    // MARK: Recording

    /// Records one classified failure. The error and the session's owner
    /// diagnostics are classified; the message is the error with the matching
    /// diagnostic line, redacted (this Mac's and the peers' names, addresses,
    /// home paths, key material) and bounded.
    @discardableResult
    public func recordFailure(_ stateCode: ClusterIncidentStateCode, source: String, error: String,
                              facts: DistributedSessionFacts?, severity: ClusterIncidentSeverity = .error,
                              rank: Int? = nil, extraDiagnostics: [String] = []) -> ClusterIncident? {
        let explanation = ClusterFailureClassifier.classify(.init(error: error,
            diagnostics: (facts?.terminations ?? []) + (facts?.diagnostics ?? []) + extraDiagnostics))
        let redaction = redaction(peerHosts: facts?.peerHosts ?? [], peerUsers: facts?.peerUsers ?? [])
        var draft = ClusterIncidentDraft(severity: severity, source: source, stateCode: stateCode,
            explanation: explanation, jobID: facts?.membershipEpoch, deploymentID: facts.map { Self.field($0.clusterID) },
            modelID: facts?.modelID, rank: rank)
        draft.message = redaction.redact(explanation.message)
        return record(draft)
    }

    /// Records a draft as given (already classified); never throws.
    @discardableResult
    public func record(_ draft: ClusterIncidentDraft) -> ClusterIncident? {
        do {
            let incident = try incidents.record(draft)
            clusterObservabilityLog(.warning, "cluster incident", ["seq": "\(incident.seq)", "state_code": incident.stateCode,
                "reason_code": incident.reasonCode ?? "none", "guidance_code": incident.guidanceCode ?? "none",
                "source": incident.source])
            return incident
        } catch {
            clusterObservabilityLog(.error, "cluster incident could not be recorded", ["error": "\(error)"])
            return nil
        }
    }

    /// The newest incidents, as a member mirrors them to the other.
    public func linkSummaries() -> (epoch: String?, incidents: [ClusterLinkIncidentSummary]) {
        let feed = incidents.feed()
        return (feed.epoch.isEmpty ? nil : feed.epoch, feed.linkSummaries())
    }

    /// A field the incident log accepts: printable ASCII, at most 128 bytes.
    static func field(_ value: String) -> String {
        let cleaned = String(value.unicodeScalars.filter { (33...126).contains($0.value) }.map(Character.init))
        return cleaned.isEmpty ? "unnamed" : String(cleaned.prefix(128))
    }
}

// MARK: - `darkbloom cluster incidents`

extension ClusterObservability {
    @discardableResult
    public func dismissIncident(id: String) throws -> Bool { try incidents.dismiss(id: id) }

    /// The feed after `since` as sorted JSON (the oMLX schema plus reason codes).
    public func incidentFeedJSON(since: UInt64) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(incidents.feed(since: since)), as: UTF8.self)
    }

    /// Plain lines: each incident newest first, with its guidance.
    public func incidentLines(since: UInt64, includeClosed: Bool) -> [String] {
        let feed = incidents.feed(since: since)
        var lines: [String] = []
        if let error = feed.loadError { lines.append("The incident log could not be read: \(error)") }
        let shown = includeClosed ? Array(feed.incidents.reversed()) : feed.open
        lines.append("Incident log: \(shown.count) shown, \(feed.incidents.count) recorded after #\(since); "
            + "epoch \(feed.epoch.isEmpty ? "none" : feed.epoch); latest #\(feed.latestSeq)")
        let formatter = ISO8601DateFormatter()
        for incident in shown {
            var flags: [String] = []
            if incident.dismissedAt != nil { flags.append("dismissed") }
            if let by = incident.supersededBy { flags.append("superseded by \(by.prefix(8))") }
            lines.append("#\(incident.seq) \(formatter.string(from: Date(timeIntervalSince1970: incident.ts))) "
                + "\(incident.severity.rawValue) \(incident.stateCode)" + (incident.reasonCode.map { " reason=\($0)" } ?? "")
                + " [\(incident.source)]" + (incident.rank.map { " rank \($0)" } ?? "")
                + (flags.isEmpty ? "" : " (" + flags.joined(separator: ", ") + ")"))
            lines.append("  id \(incident.id)" + (incident.modelID.map { " · model \($0)" } ?? "")
                + (incident.jobID.map { " · session \($0)" } ?? ""))
            lines.append("  \(incident.message)")
            if let code = incident.guidanceCode, let guidance = ClusterGuidance.guidance(code: code) {
                lines.append("  What to do (\(guidance.code)): \(guidance.title)")
                for step in guidance.steps { lines.append("    - \(step)") }
            }
        }
        return lines
    }
}

extension DistributedInstalledPlan {
    /// A plan's identifiers, mode and cut for incidents and telemetry of a
    /// session this process does not own (a coordinator-committed start).
    func observabilityFacts(membershipEpoch: UUID?, diagnostics: [String] = []) -> DistributedSessionFacts {
        .init(clusterID: configuration.clusterID, memberID: configuration.memberID, modelID: configuration.publicModelID,
              mode: configuration.selectedGenerationMode.rawValue,
              cut: DistributedSessionFacts.cut(partition.stages.map { ($0.rank, $0.sourceLayerStart, $0.sourceLayerEnd) },
                  mode: configuration.selectedGenerationMode, tensorShares: configuration.tensorShares),
              membershipEpoch: membershipEpoch?.uuidString.lowercased(), diagnostics: diagnostics, terminations: [],
              peerHosts: configuration.peers.map(\.host), peerUsers: configuration.peers.map(\.user),
              ranks: configuration.peers.sorted { $0.rank < $1.rank }.map(\.id))
    }
}
