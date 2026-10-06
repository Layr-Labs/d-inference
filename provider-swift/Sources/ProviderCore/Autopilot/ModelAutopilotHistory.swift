import Foundation

/// Bounded history remains available after a model is unloaded and after a
/// daemon restart. Exact build + verified weight hash scopes every measurement.
public struct ModelAutopilotHistory: Codable, Sendable {
    public var loads: [ModelAutopilotLoadTiming] = []
    public init() {}
    public mutating func record(_ timing: ModelAutopilotLoadTiming) {
        guard timing.loadMs > 0, timing.loadMs <= 1_800_000, !timing.weightHash.isEmpty else { return }
        loads.removeAll { $0.modelId == timing.modelId }
        loads.append(timing)
        if loads.count > 64 { loads.removeFirst(loads.count - 64) }
    }
    public static func read(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), data.count <= 131_072,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var result = Self()
        for timing in decoded.loads.suffix(64) { result.record(timing) }
        return result
    }
    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension ProviderLoop {
    var autopilotHistoryURL: URL? {
        loopConfig.configPath?.deletingLastPathComponent().appendingPathComponent("autopilot-load-history.json")
    }
    func loadAutopilotTimingHistory() {
        guard !autopilotTimingLoaded else { return }
        autopilotTimingLoaded = true
        if let url = autopilotHistoryURL { autopilotTimingHistory = .read(from: url) }
    }
    func recordAutopilotLoadTime(model: String, milliseconds: Int64) {
        loadAutopilotTimingHistory()
        autopilotTimingHistory.record(.init(modelId: model, loadMs: milliseconds,
            measuredAtMs: Int64(Date().timeIntervalSince1970 * 1_000), weightHash: liveModelHashes[model] ?? ""))
        if let url = autopilotHistoryURL {
            do { try autopilotTimingHistory.write(to: url) }
            catch { logger.warning("Could not persist Autopilot load timings") }
        }
    }
}
