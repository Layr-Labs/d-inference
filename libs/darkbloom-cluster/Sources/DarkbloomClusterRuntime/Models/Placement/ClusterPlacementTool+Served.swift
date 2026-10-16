import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Speed records from served requests, and the per-request route, for the
/// plan command (`plan --served`, `route`).
extension ClusterPlacementTool {
    public static let servedUsage = """
          darkbloom-cluster-plan plan ... [--served FILE ...] [--served-ranks LABEL,LABEL]
              Adds the speed records of requests a setup served: FILE is the records file the leader keeps
              (`served-speed.json`) or its pair telemetry (`pair-telemetry.json`). They are turned into
              measurements of each Mac (`ClusterServedCalibration`) before planning. `--served-ranks` names
              the Macs in rank order when the file does not.
          darkbloom-cluster-plan route (--model-dir DIR | --layout FILE) --peer LABEL=PROFILE.json --peer ...
                                       --cut N --mode MODE --ranks LABEL,LABEL [--schedule SCHEDULE]
                                       --prompt-tokens N[,N...] [--output-tokens N] [--served FILE ...] [--json]
              For each prompt length: does the setup serve the request as placed (the pair), or does the
              member that holds the whole model serve it alone? Also the shortest prompt the pair is chosen for.
        """

    /// The two files a leader writes that carry served requests.
    struct TelemetryFile: Decodable {
        struct Record: Decodable {
            let finishedAt: Double
            let modelID: String
            let mode: String
            let cut: String
            let promptTokens: Int
            let cachedTokens: Int
            let completionTokens: Int
            let firstTokenMilliseconds: Double?
            let decodeTokensPerSecond: Double?
            let outcome: String
            let route: String?
            let ranks: [String]?
        }
        let schema: String
        let records: [Record]
    }

    /// Served samples from `files`, each with its setup. Telemetry records
    /// count only when completed and cold (nothing restored from a prefix
    /// cache: a restored prompt's first token is not its prefill).
    static func servedEntries(_ files: [String], ranks: [String]?) throws -> [ClusterServedSpeedRecords.Entry] {
        var result: [ClusterServedSpeedRecords.Entry] = []
        for file in files {
            let data = try read(file, maximumBytes: ClusterServedSpeedRecords.maximumEncodedBytes)
            if let records = try? ClusterServedSpeedRecords.decode(data) {
                result += records.entries.map { entry in
                    guard let ranks, entry.setup.ranks == nil else { return entry }
                    return .init(setup: .init(modelID: entry.setup.modelID, mode: entry.setup.mode, cut: entry.setup.cut, ranks: ranks),
                                 sample: entry.sample)
                }
                continue
            }
            let telemetry = try JSONDecoder().decode(TelemetryFile.self, from: data)
            guard ["darkbloom_pair_telemetry_v1", "darkbloom_served_speed_v1"].contains(telemetry.schema) else { throw ProbeError("\(file) is neither served records nor pair telemetry") }
            for record in telemetry.records {
                guard record.cachedTokens == 0, record.outcome == "stop" || record.outcome == "length",
                      let first = record.firstTokenMilliseconds else { continue }
                let route = record.route ?? "pair"
                let member = route.hasPrefix("alone:") ? String(route.dropFirst(6)) : nil
                let sample = ClusterServedSample(route: member == nil ? .pair : .alone, member: member,
                    promptTokens: record.promptTokens, outputTokens: record.completionTokens,
                    firstTokenSeconds: first / 1_000, decodeTokensPerSecond: record.decodeTokensPerSecond, finishedAt: record.finishedAt)
                if sample.valid {
                    result.append(.init(setup: .init(modelID: record.modelID, mode: record.mode, cut: record.cut, ranks: record.ranks ?? ranks),
                                       sample: sample))
                }
            }
        }
        return result
    }

    /// Measurements derived from every setup the entries name whose ranks are
    /// among `devices` and whose cut fits `layout` (`ClusterServedCalibration.measurements(entries:...)`).
    static func servedMeasurements(_ entries: [ClusterServedSpeedRecords.Entry], devices: [ClusterPlacementDevice],
                                   layout: ClusterModelLayout, link: ClusterLinkCosts) throws -> (measurements: [ClusterSpeedMeasurement], lines: [String]) {
        try ClusterServedCalibration.measurements(entries: entries, devices: devices, layout: layout, link: link,
            measuredUTC: ISO8601DateFormatter().string(from: Date()))
    }

    struct RouteOutput: Encodable {
        let setup: String
        let devices: [PlanOutput.Device]
        let decisions: [ClusterRequestRoute]
        let crossoverPromptTokens: Int?
        let servedSamples: Int
    }

    static func route(_ arguments: [String]) throws -> String {
        let parsed = try Arguments(arguments, flags: ["--json"], options: ["--model-dir", "--layout", "--peer", "--speed", "--link",
            "--cut", "--mode", "--ranks", "--schedule", "--prompt-tokens", "--output-tokens", "--served", "--tolerance"])
        let layout: ClusterModelLayout
        switch (try parsed.one("--model-dir"), try parsed.one("--layout")) {
        case (let directory?, nil): layout = try ClusterPlacementArtifact.layout(directory: URL(fileURLWithPath: directory, isDirectory: true))
        case (nil, let file?): layout = try ClusterModelLayout.decode(read(file, maximumBytes: ClusterModelLayout.maximumEncodedBytes))
        default: throw ProbeError("route needs exactly one of --model-dir and --layout\n" + servedUsage)
        }
        var profiles: [(label: String, profile: ClusterDeviceProfile)] = []
        for entry in parsed.values["--peer"] ?? [] {
            guard let split = entry.firstIndex(of: "="), split != entry.startIndex else { throw ProbeError("--peer needs LABEL=PROFILE.json") }
            profiles.append((String(entry[..<split]), try ClusterDeviceProfile.decode(read(String(entry[entry.index(after: split)...]),
                maximumBytes: ClusterDeviceProfile.maximumEncodedBytes))))
        }
        guard let ranksText = try parsed.one("--ranks"), let modeText = try parsed.one("--mode"),
              let mode = ClusterGenerationMode(rawValue: modeText), let cutText = try parsed.one("--cut") else {
            throw ProbeError("route needs --ranks, --mode and --cut\n" + servedUsage)
        }
        let ranks = ranksText.split(separator: ",").map(String.init)
        let cuts = try cutText.split(separator: ",").map { text -> Int in
            guard let value = Int(text), (1..<layout.layerCount).contains(value) else { throw ProbeError("--cut is inside the model") }
            return value
        }
        guard ranks.count == cuts.count + 1, Set(ranks).count == ranks.count,
              ranks.allSatisfy({ label in profiles.contains { $0.label == label } }) else {
            throw ProbeError("--ranks names each --peer once, one more than the cuts")
        }
        let schedule = try parsed.one("--schedule").map {
            guard let value = ClusterPrefillSchedule(rawValue: $0) else { throw ProbeError("Unknown prefill schedule: \($0)") }
            return value
        } ?? (layout.prefillSchedules.contains(.oneChunkLookahead) ? .oneChunkLookahead : .serial)
        let decoder = JSONDecoder()
        let link = try parsed.one("--link").map { try decoder.decode(ClusterLinkCosts.self, from: read($0, maximumBytes: 65_536)) } ?? .unmeasured
        let measured = try (parsed.values["--speed"] ?? []).map { file -> ClusterSpeedMeasurement in
            let value = try decoder.decode(ClusterSpeedMeasurement.self, from: read(file, maximumBytes: 65_536))
            try value.validate()
            return value
        }
        let ordered = ranks.map { label in profiles.first { $0.label == label }! }
        func estimate(_ measurements: [ClusterSpeedMeasurement]) -> [ClusterPlacementDevice] {
            let speeds = ClusterSpeedEstimator.estimate(devices: ordered.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
                artifactSHA256: layout.artifactSHA256, promptTokens: layout.maximumChunkTokens, measurements: measurements,
                indices: ordered.compactMap { $0.profile.speedIndex })
            return zip(ordered, speeds).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }
        }
        let setupKey = ClusterServedSpeedRecords.Setup.cut(cuts, layerCount: layout.layerCount)
        let entries = try servedEntries(parsed.values["--served"] ?? [], ranks: ranks)
            .filter { $0.setup.cut == setupKey && $0.setup.mode == mode.rawValue }
        // The planner's estimates first, then the same with what this setup served.
        var devices = estimate(measured)
        let served = try servedMeasurements(entries, devices: devices, layout: layout, link: link)
        if !served.measurements.isEmpty { devices = estimate(measured + served.measurements) }
        var tolerance = 0.03
        if let text = try parsed.one("--tolerance") {
            guard let value = Double(text), value >= 0, value < 1 else { throw ProbeError("--tolerance is a share below 1") }
            tolerance = value
        }
        let setup = ClusterRequestRouter.Setup(devices: devices, cuts: cuts, mode: mode, schedule: schedule, layout: layout,
            link: link, tieTolerance: tolerance)
        let samples = entries.map(\.sample)
        let prompts = try (try parsed.one("--prompt-tokens") ?? "").split(separator: ",").map { text -> Int in
            guard let value = Int(text), value > 0 else { throw ProbeError("--prompt-tokens needs positive whole numbers") }
            return value
        }
        guard !prompts.isEmpty else { throw ProbeError("route needs --prompt-tokens\n" + servedUsage) }
        let requested = try parsed.integer("--output-tokens") ?? 256
        let outputs = ClusterRequestRouter.expectedOutputTokens(maximum: requested, served: samples)
        let decisions = try prompts.map { try ClusterRequestRouter.decide(setup, promptTokens: $0, outputTokens: outputs, served: samples) }
        let crossover = try ClusterRequestRouter.crossoverPromptTokens(setup, outputTokens: outputs,
            maximumPrompt: ClusterWorkerLimits.promptTokens, served: samples)
        if parsed.flags.contains("--json") {
            return try json(RouteOutput(setup: "\(mode.rawValue) cut \(setupKey) (\(ranks.joined(separator: ", ")))",
                devices: devices.map { .init(label: $0.label, profile: $0.profile, speed: $0.speed) }, decisions: decisions,
                crossoverPromptTokens: crossover, servedSamples: samples.count))
        }
        var lines = ["Setup: \(mode.rawValue), cut \(setupKey), ranks \(ranks.joined(separator: ", ")); \(layout.runtimeModelID)"]
        for device in devices {
            lines.append("  \(device.label): \(device.speed.source.rawValue): \(device.speed.explanation)")
        }
        if !served.lines.isEmpty { lines.append("Speed records from served requests"); lines += served.lines }
        let absolute = devices.allSatisfy(\.speed.absolute)
        lines.append("Routes (priced at \(outputs) output tokens" + (absolute ? ")"
            : "; times in the index's relative units: no speed of this model was measured or served yet, only their ratio decides)"))
        for d in decisions {
            var text = "  \(d.promptTokens) prompt tokens -> \(d.label): " + String(format: "pair %.3f s (first token %.3f s, %@)",
                d.pairSeconds, d.pairFirstTokenSeconds, d.pairBasis.rawValue)
            if let alone = d.aloneSeconds, let first = d.aloneFirstTokenSeconds, let member = d.aloneCandidate {
                text += String(format: ", %@ alone %.3f s (first token %.3f s, %@)", member, alone, first, d.aloneBasis?.rawValue ?? "")
            }
            lines.append(text + "; " + d.reason)
        }
        lines.append(crossover.map { "The pair is chosen from \($0) prompt tokens" } ?? "The pair is never predicted faster: every request is served alone")
        return lines.joined(separator: "\n")
    }
}
