import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The `darkbloom-cluster-plan` command without its process: arguments in,
/// text out. The command supplies the sampler that reads this Mac; a check
/// can run the rest without one. Nothing here loads a model or touches a GPU.
public enum ClusterPlacementTool {
    public static let usage = """
        usage:
          darkbloom-cluster-plan glm-calibration-candidates --input FILE [--speed FILE ...]
              Exact local finite-calibration cut quotes from current device bounds; no model load or serving authority.
          darkbloom-cluster-plan device [--json] [--index]
              What this Mac detects about itself, and what its load gate would admit now. `--index`
              adds the model-free speed index (about a second of GPU work), which relates two Macs'
              speeds when no speed was measured for a model.
          darkbloom-cluster-plan index
              A model-free speed index of this Mac as JSON: about a second of GPU work, no model.
              An experiment; see the design. Needs the Metal library beside the binary.
          darkbloom-cluster-plan layout --model-dir DIR [--json] [--runtime-profile PROFILE]
              What an artifact is made of, from its tensor headers and config.json.
          darkbloom-cluster-plan plan (--model-dir DIR | --layout FILE)
                                      [--local LABEL] --peer LABEL=PROFILE.json [--peer LABEL=PROFILE.json ...]
                                      [--speed MEASUREMENT.json ...] [--index INDEX.json ...] [--link LINK.json]
                                      [--prompt-tokens N] [--output-tokens N] [--regime rested|sustained (default rested)]
                                      [--modes MODE,MODE] [--alternatives N] [--leader LABEL] [--hand-off-modes] [--json]
              How the model is divided between the devices, and why. `--local` samples this Mac
              and names it LABEL; every other device is a profile file made by `device --json`
              on that Mac. Without `--local` at least two `--peer` profiles are needed. `--leader`
              keeps only placements whose rank 0 is that device (the Mac a session is started from).
              A plan shards the model (tensor parallel or pipeline); `--hand-off-modes` is the opt-in
              that also considers phase split, phase split + MTP and the pipeline-prefill/tensor-decode
              hybrid (off by default; such a plan is the earlier planner's, byte for byte).
        """

    struct Arguments {
        var values: [String: [String]] = [:]
        var flags = Set<String>()
        init(_ arguments: [String], flags known: Set<String>, options: Set<String>) throws {
            var index = 0
            while index < arguments.count {
                let name = arguments[index]
                if known.contains(name) { flags.insert(name); index += 1; continue }
                guard options.contains(name), index + 1 < arguments.count else {
                    throw ProbeError("Unknown or incomplete argument: \(name)\n" + ClusterPlacementTool.usage)
                }
                values[name, default: []].append(arguments[index + 1]); index += 2
            }
        }
        func one(_ name: String) throws -> String? {
            guard let all = values[name] else { return nil }
            guard all.count == 1 else { throw ProbeError("\(name) may be given once") }
            return all[0]
        }
        func integer(_ name: String) throws -> Int? {
            guard let text = try one(name) else { return nil }
            guard let value = Int(text), value > 0 else { throw ProbeError("\(name) needs a positive whole number") }
            return value
        }
    }

    static func read(_ path: String, maximumBytes: Int) throws -> Data {
        try BoundedProbeInput.data(URL(fileURLWithPath: path), maximumBytes: maximumBytes)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Runs one subcommand and returns what it prints.
    public static func run(_ arguments: [String], sampleDevice: () throws -> ClusterDeviceProfile,
                           glmCandidates: (Data, [ClusterSpeedMeasurement], ClusterDeviceProfile) throws -> String = { _, _, _ in
                               throw ProbeError("This build has no GLM calibration candidate scanner")
                           },
                           measureIndex: () throws -> ClusterDeviceIndex = {
                               throw ProbeError("This build has no device index benchmark")
                           }) throws -> String {
        guard let command = arguments.first else { throw ProbeError(usage) }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "glm-calibration-candidates":
            let parsed = try Arguments(rest, flags: [], options: ["--input", "--speed"])
            guard let input = try parsed.one("--input") else { throw ProbeError("GLM candidates need --input") }
            let measurements = try (parsed.values["--speed"] ?? []).map {
                let value = try JSONDecoder().decode(ClusterSpeedMeasurement.self, from: read($0, maximumBytes: 65_536))
                try value.validate()
                return value
            }
            return try glmCandidates(read(input, maximumBytes: 256 << 10), measurements, sampleDevice())
        case "device":
            let parsed = try Arguments(rest, flags: ["--json", "--index"], options: [])
            var profile = try sampleDevice()
            // The index is an addition: a Mac whose benchmark cannot run still
            // answers with its profile, and is planned as before (by memory).
            if parsed.flags.contains("--index"), let index = try? measureIndex() {
                var indexed = profile
                indexed.speedIndex = index
                if (try? indexed.validate()) != nil { profile = indexed }
            }
            if parsed.flags.contains("--json") { return String(decoding: try profile.encoded(), as: UTF8.self) }
            return ClusterPlacementExplanation.device("This Mac", profile).joined(separator: "\n")
        case "index":
            _ = try Arguments(rest, flags: [], options: [])
            return try json(try measureIndex())
        case "layout":
            let parsed = try Arguments(rest, flags: ["--json"], options: ["--model-dir","--runtime-profile"])
            guard let directory = try parsed.one("--model-dir") else { throw ProbeError("layout needs --model-dir\n" + usage) }
            let layout = try ClusterPlacementArtifact.layout(directory: URL(fileURLWithPath: directory, isDirectory: true),
                runtimeProfile: parsed.one("--runtime-profile"))
            if parsed.flags.contains("--json") { return String(decoding: try layout.encoded(), as: UTF8.self) }
            return ClusterPlacementExplanation.layout(layout).joined(separator: "\n")
        case "plan":
            return try plan(rest, sampleDevice: sampleDevice)
        case "route":
            return try route(rest)
        default:
            throw ProbeError("Unknown subcommand: \(command)\n" + usage + "\n" + servedUsage)
        }
    }

    struct PlanOutput: Encodable {
        struct Device: Encodable { let label: String; let profile: ClusterDeviceProfile; let speed: ClusterDeviceSpeed }
        let devices: [Device]
        let layout: ClusterModelLayout
        let link: ClusterLinkCosts
        let result: ClusterPlacementResult
        let explanation: [String]
    }

    static func plan(_ arguments: [String], sampleDevice: () throws -> ClusterDeviceProfile) throws -> String {
        let parsed = try Arguments(arguments, flags: ["--json", "--hand-off-modes"], options: ["--model-dir", "--layout", "--local", "--peer",
            "--speed", "--index", "--link", "--prompt-tokens", "--output-tokens", "--regime", "--modes", "--alternatives",
            "--leader", "--served", "--served-ranks"])
        let layout: ClusterModelLayout
        switch (try parsed.one("--model-dir"), try parsed.one("--layout")) {
        case (let directory?, nil): layout = try ClusterPlacementArtifact.layout(directory: URL(fileURLWithPath: directory, isDirectory: true))
        case (nil, let file?): layout = try ClusterModelLayout.decode(read(file, maximumBytes: ClusterModelLayout.maximumEncodedBytes))
        default: throw ProbeError("plan needs exactly one of --model-dir and --layout\n" + usage)
        }
        var profiles: [(label: String, profile: ClusterDeviceProfile)] = []
        if let label = try parsed.one("--local") { profiles.append((label, try sampleDevice())) }
        for entry in parsed.values["--peer"] ?? [] {
            guard let split = entry.firstIndex(of: "="), split != entry.startIndex else {
                throw ProbeError("--peer needs LABEL=PROFILE.json")
            }
            let file = String(entry[entry.index(after: split)...])
            profiles.append((String(entry[..<split]),
                             try ClusterDeviceProfile.decode(read(file, maximumBytes: ClusterDeviceProfile.maximumEncodedBytes))))
        }
        guard profiles.count >= 2 else { throw ProbeError("plan needs two or more devices\n" + usage) }
        var policy = ClusterPlacementPolicy()
        policy.promptTokens = try parsed.integer("--prompt-tokens")
        policy.outputTokens = try parsed.integer("--output-tokens")
        // A requested context beyond the layout's planned request: plan it at
        // that context (the family's charge there).
        let requested = (policy.promptTokens ?? layout.maximumPromptTokens) + (policy.outputTokens ?? layout.maximumOutputTokens)
        if requested > layout.maximumContextTokens, let directory = try parsed.one("--model-dir"),
           let answer = try ClusterPlacementArtifact.requestedContext(directory: URL(fileURLWithPath: directory, isDirectory: true),
               contextTokens: requested) {
            policy.largestContextTokens = answer.largest
            policy.requestChargeEveryRankBytes = answer.charge
        }
        if let alternatives = try parsed.integer("--alternatives") { policy.alternatives = min(alternatives, 256) }
        policy.leader = try parsed.one("--leader")
        policy.handOffModes = parsed.flags.contains("--hand-off-modes")
        if let regime = try parsed.one("--regime") {
            guard let value = ClusterPlacementPolicy.Regime(rawValue: regime) else { throw ProbeError("--regime is sustained or rested") }
            policy.regime = value
        }
        if let modes = try parsed.one("--modes") {
            policy.modes = try modes.split(separator: ",").map {
                guard let mode = ClusterGenerationMode(rawValue: String($0)) else { throw ProbeError("Unknown generation mode: \($0)") }
                return mode
            }
        }
        let decoder = JSONDecoder()
        let measurements = try (parsed.values["--speed"] ?? []).map { file -> ClusterSpeedMeasurement in
            let value = try decoder.decode(ClusterSpeedMeasurement.self, from: read(file, maximumBytes: 65_536))
            try value.validate()
            return value
        }
        let indices = try (parsed.values["--index"] ?? []).map {
            let value = try decoder.decode(ClusterDeviceIndex.self, from: read($0, maximumBytes: 65_536))
            try value.validate()
            return value
        }
        let link = try parsed.one("--link").map { try decoder.decode(ClusterLinkCosts.self, from: read($0, maximumBytes: 65_536)) } ?? .unmeasured
        let speeds = ClusterSpeedEstimator.estimate(
            devices: profiles.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: policy.promptTokens ?? layout.maximumPromptTokens,
            measurements: measurements, indices: indices + profiles.compactMap { $0.profile.speedIndex })
        var devices = zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }
        // Requests a setup served on these devices are measurements too: the
        // next plan starts from them (`ClusterServedCalibration`).
        var servedLines: [String] = []
        if let files = parsed.values["--served"] {
            let ranks = try parsed.one("--served-ranks").map { $0.split(separator: ",").map(String.init) }
            let served = try servedMeasurements(try servedEntries(files, ranks: ranks), devices: devices, layout: layout, link: link)
            servedLines = ["Speed records from served requests"] + served.lines
            if !served.measurements.isEmpty {
                let again = ClusterSpeedEstimator.estimate(
                    devices: profiles.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
                    artifactSHA256: layout.artifactSHA256, promptTokens: policy.promptTokens ?? layout.maximumPromptTokens,
                    measurements: measurements + served.measurements, indices: indices + profiles.compactMap { $0.profile.speedIndex })
                devices = zip(profiles, again).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }
            }
        }
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        let explanation = servedLines + ClusterPlacementExplanation.describe(result, devices: devices, layout: layout, link: link)
        if parsed.flags.contains("--json") {
            return try json(PlanOutput(devices: devices.map { .init(label: $0.label, profile: $0.profile, speed: $0.speed) },
                layout: layout, link: link, result: result, explanation: explanation))
        }
        return explanation.joined(separator: "\n")
    }
}
