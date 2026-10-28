import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
#if canImport(MLX)
import MLX
#endif

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
          darkbloom-cluster-plan tensor-batch-scope --model-dir DIR --prompt-tokens N --output-tokens N --batch-lanes N --chunk-size N [--mtp-depth N] [--tp-mtp-verification singleton_ready_set_v1|admitted_target_cohort_v1]
          darkbloom-cluster-plan batch-scope --model-dir DIR --prompt-tokens N --output-tokens N --batch-lanes N --chunk-size N
              Complete native batch state and shared workspace, bound to width and original chunk.
          darkbloom-cluster-plan request-scope --model-dir DIR --prompt-tokens N --output-tokens N
              Registered request bounds and conservative memory charge as JSON; metadata only.
          darkbloom-cluster-plan plan (--model-dir DIR | --layout FILE)
                                      [--local LABEL] --peer LABEL=PROFILE.json [--peer LABEL=PROFILE.json ...]
                                      [--speed MEASUREMENT.json ...] [--index INDEX.json ...] [--link LINK.json | --link-probes FILE]
                                      [--share-probes FILE]
                                      [--prompt-tokens N] [--output-tokens N] [--regime rested|sustained (default rested)]
                                      [--modes MODE,MODE] [--alternatives N] [--leader LABEL] [--hand-off-modes]
                                      [--tensor-parallel-first] [--json]
              How the model is divided between the devices, and why. `--local` samples this Mac
              and names it LABEL; every other device is a profile file made by `device --json`
              on that Mac. Without `--local` at least two `--peer` profiles are needed. `--leader`
              keeps only placements whose rank 0 is that device (the Mac a session is started from).
              A plan shards the model (tensor parallel or pipeline); `--hand-off-modes` is the opt-in
              that also considers phase split, phase split + MTP and the pipeline-prefill/tensor-decode
              hybrid (off by default; such a plan is the earlier planner's, byte for byte).
              `--tensor-parallel-first` plans as the product does: tensor parallel wherever it fits
              (owner rule), on an assumed reduction until a load measures the link.
              Without `--link`, two devices are planned on the link probes the setup saved for them
              (~/.darkbloom/cluster/link-probes.json, or FILE): the median of the pair's last loads,
              found by the two labels, which are member IDs there. The plan says what it found.
              Each device's share steps, as its tensor-parallel loads timed them, come from the
              setup's ~/.darkbloom/cluster/share-probes.json (or --share-probes FILE), by label.
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

    /// The link probes the setup saves (`ClusterLinkProbeHistory`), which
    /// `plan` reads when it is given no `--link`.
    public static var defaultLinkProbes: URL {
        ClusterLinkProbeHistory.defaultFile(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The share probes the setup saves (`ClusterShareProbeHistory`), which
    /// `plan` reads when it is given no `--share-probes`.
    public static var defaultShareProbes: URL {
        ClusterShareProbeHistory.defaultFile(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Runs one subcommand and returns what it prints. `savedLinkProbes`: the
    /// file `plan` reads the pair's link from when it is given no `--link`;
    /// nil (a check's default) reads none, and such a plan is unmeasured.
    /// `savedShareProbes`: the same for each device's share probes.
    public static func run(_ arguments: [String], sampleDevice: () throws -> ClusterDeviceProfile,
                           glmCandidates: (Data, [ClusterSpeedMeasurement], ClusterDeviceProfile) throws -> String = { _, _, _ in
                               throw ProbeError("This build has no GLM calibration candidate scanner")
                           },
                           measureIndex: () throws -> ClusterDeviceIndex = {
                               throw ProbeError("This build has no device index benchmark")
                           },
                           savedLinkProbes: URL? = nil, savedShareProbes: URL? = nil) throws -> String {
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
        case "tensor-batch-scope":
            let parsed = try Arguments(rest, flags: [], options: ["--model-dir", "--prompt-tokens", "--output-tokens", "--batch-lanes", "--chunk-size", "--mtp-depth", ClusterQwenTensorAssistantPolicy.verificationArgument])
            guard let directory = try parsed.one("--model-dir"), let prompt = try parsed.integer("--prompt-tokens"),
                  let output = try parsed.integer("--output-tokens"), let lanes = try parsed.integer("--batch-lanes"),
                  let chunk = try parsed.integer("--chunk-size") else {
                throw ProbeError("tensor-batch-scope needs model directory, prompt/output, batch lanes and chunk size")
            }
            let verification: ClusterQwenTensorAssistantPolicy.Verification
            if let text = try parsed.one(ClusterQwenTensorAssistantPolicy.verificationArgument) {
                guard let value = ClusterQwenTensorAssistantPolicy.Verification(rawValue: text),
                      try parsed.integer("--mtp-depth") != nil else {
                    throw ProbeError("Tensor assistant verification needs a supported policy and explicit depth")
                }
                verification = value
            } else { verification = .singleton }
            #if canImport(MLX)
            return try json(ClusterPlacementArtifact.requestedTensorBatchQuote(directory: URL(fileURLWithPath: directory, isDirectory: true),
                promptTokens: prompt, outputTokens: output, chunkTokens: chunk, lanes: lanes,
                assistantDepth: parsed.integer("--mtp-depth"), assistantVerification: verification, allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) }))
            #else
            _ = (directory, prompt, output, lanes, chunk, verification)
            throw ProbeError("Tensor batch quotation requires the native allocator metadata helper")
            #endif
        case "batch-scope":
            let parsed = try Arguments(rest, flags: [], options: ["--model-dir", "--prompt-tokens", "--output-tokens", "--batch-lanes", "--chunk-size"])
            guard let directory = try parsed.one("--model-dir"), let prompt = try parsed.integer("--prompt-tokens"),
                  let output = try parsed.integer("--output-tokens"), let lanes = try parsed.integer("--batch-lanes"),
                  let chunk = try parsed.integer("--chunk-size") else {
                throw ProbeError("batch-scope needs model directory, prompt/output, batch lanes and chunk size")
            }
            #if canImport(MLX)
            return try json(ClusterPlacementArtifact.requestedBatchQuote(directory: URL(fileURLWithPath: directory, isDirectory: true),
                promptTokens: prompt, outputTokens: output, chunkTokens: chunk, lanes: lanes,
                allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) }))
            #else
            _ = (directory, prompt, output, lanes, chunk)
            throw ProbeError("Native batch quotation requires the native allocator metadata helper")
            #endif
        case "request-scope":
            let parsed = try Arguments(rest, flags: [], options: ["--model-dir", "--prompt-tokens", "--output-tokens"])
            guard let directory = try parsed.one("--model-dir"), let prompt = try parsed.integer("--prompt-tokens"),
                  let output = try parsed.integer("--output-tokens") else {
                throw ProbeError("request-scope needs --model-dir, --prompt-tokens and --output-tokens")
            }
            return try json(ClusterPlacementArtifact.requestedScope(directory: URL(fileURLWithPath: directory, isDirectory: true),
                promptTokens: prompt, outputTokens: output))
        case "plan":
            return try plan(rest, sampleDevice: sampleDevice, savedLinkProbes: savedLinkProbes, savedShareProbes: savedShareProbes)
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

    static func plan(_ arguments: [String], sampleDevice: () throws -> ClusterDeviceProfile,
                     savedLinkProbes: URL? = nil, savedShareProbes: URL? = nil) throws -> String {
        let parsed = try Arguments(arguments, flags: ["--json", "--hand-off-modes", "--tensor-parallel-first"], options: ["--model-dir", "--layout",
            "--local", "--peer", "--speed", "--index", "--link", "--link-probes", "--share-probes", "--prompt-tokens", "--output-tokens",
            "--regime", "--modes", "--alternatives", "--leader", "--served", "--served-build", "--served-ranks"])
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
        let prompt = policy.promptTokens ?? layout.maximumPromptTokens
        let output = policy.outputTokens ?? layout.maximumOutputTokens
        // Each axis matters: a longer completion may fit inside the old
        // combined reservation and still require the registered family scope.
        if prompt > layout.maximumPromptTokens || output > layout.maximumOutputTokens,
           let directory = try parsed.one("--model-dir") {
            let scope = try ClusterPlacementArtifact.requestedScope(directory: URL(fileURLWithPath: directory, isDirectory: true),
                promptTokens: prompt, outputTokens: output)
            try scope.apply(to: &policy, layout: layout)
        }
        if let alternatives = try parsed.integer("--alternatives") { policy.alternatives = min(alternatives, 256) }
        policy.leader = try parsed.one("--leader")
        policy.handOffModes = parsed.flags.contains("--hand-off-modes")
        // As the provider's first placement: tensor parallel first, on the assumed keyed reduction until a load measures the link.
        policy.tensorParallelFirst = parsed.flags.contains("--tensor-parallel-first")
        policy.tensorParallelAssumesUnmeasuredLink = policy.tensorParallelFirst
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
        let link: ClusterLinkCosts
        var linkLines: [String] = []
        if let file = try parsed.one("--link") {
            guard try parsed.one("--link-probes") == nil else { throw ProbeError("Give --link or --link-probes, not both") }
            link = try decoder.decode(ClusterLinkCosts.self, from: read(file, maximumBytes: 65_536))
        } else {
            // As the setup plans: the pair's saved probes, their median (`ClusterLinkProbeHistory`).
            let named = try parsed.one("--link-probes").map(URL.init(fileURLWithPath:))
            let saved = try savedLink(named ?? savedLinkProbes, named: named != nil, labels: profiles.map { $0.label },
                now: Date().timeIntervalSince1970)
            link = saved.costs ?? .unmeasured
            linkLines = saved.lines
        }
        let speeds = ClusterSpeedEstimator.estimate(
            devices: profiles.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: policy.promptTokens ?? layout.maximumPromptTokens,
            measurements: measurements, indices: indices + profiles.compactMap { $0.profile.speedIndex })
        // As the setup plans: each device's own share probes of this model (`ClusterShareProbeHistory`, by label), on
        // its own index estimate when its speed is only a ratio, before served requests correct them.
        let namedShares = try parsed.one("--share-probes").map(URL.init(fileURLWithPath:))
        let shares = try savedShares(namedShares ?? savedShareProbes, named: namedShares != nil, labels: profiles.map { $0.label },
            artifactSHA256: layout.artifactSHA256, now: Date().timeIntervalSince1970)
        func probed(_ devices: [ClusterPlacementDevice]) -> [ClusterPlacementDevice] {
            shares.rates.isEmpty ? devices
                : ClusterHardwarePrior.absolute(devices, layout: layout, link: link).map { $0.addingShareRates(shares.rates) }
        }
        var devices = probed(zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) })
        // Requests a setup served on these devices are measurements too: the
        // next plan starts from them (`ClusterServedCalibration`), only those
        // the plan's worker build served (`--served-build`).
        var servedLines: [String] = []
        guard parsed.values["--served"] != nil || parsed.values["--served-build"] == nil else {
            throw ProbeError("--served-build names the worker build of the --served records to use; give --served too")
        }
        if let files = parsed.values["--served"] {
            let ranks = try parsed.one("--served-ranks").map { $0.split(separator: ",").map(String.init) }
            let scoped = try servedScope(try servedEntries(files, ranks: ranks), build: try parsed.one("--served-build"),
                labels: profiles.map { $0.label })
            let served = try servedMeasurements(scoped.entries, devices: devices, layout: layout, link: link)
            servedLines = ["Speed records from served requests"] + served.lines + scoped.lines
            if !served.measurements.isEmpty {
                let again = ClusterSpeedEstimator.estimate(
                    devices: profiles.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
                    artifactSHA256: layout.artifactSHA256, promptTokens: policy.promptTokens ?? layout.maximumPromptTokens,
                    measurements: measurements + served.measurements, indices: indices + profiles.compactMap { $0.profile.speedIndex })
                devices = probed(zip(profiles, again).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) })
            }
        }
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        let explanation = linkLines + shares.lines + servedLines
            + ClusterPlacementExplanation.describe(result, devices: devices, layout: layout, link: link)
        if parsed.flags.contains("--json") {
            return try json(PlanOutput(devices: devices.map { .init(label: $0.label, profile: $0.profile, speed: $0.speed) },
                layout: layout, link: link, result: result, explanation: explanation))
        }
        return explanation.joined(separator: "\n")
    }

    /// The pair's link as the setup saved it (`ClusterLinkProbeHistory`: the
    /// median of its last loads' probes), for a plan given no `--link`, and
    /// what was found, in words. The two devices' labels name the pair (the
    /// setup keys it by member ID). The default file counts only as the setup
    /// reads it (owner-only) and is otherwise reported and left out; a file
    /// named with `--link-probes` must hold the pair, or the plan stops.
    static func savedLink(_ file: URL?, named: Bool, labels: [String], now: Double) throws
        -> (costs: ClusterLinkCosts?, lines: [String]) {
        guard let file else { return (nil, []) }
        let unmeasured = "transfers are counted as free and tensor parallel is not predicted"
        func said(_ text: String) -> (costs: ClusterLinkCosts?, lines: [String]) { (nil, ["Link costs", "  No --link given: \(text)."]) }
        guard labels.count == 2 else {
            if named { throw ProbeError("--link-probes needs exactly two devices: probes are saved per pair") }
            return said("saved link probes are kept per pair of Macs and this plan has \(labels.count) devices, so \(unmeasured)")
        }
        let path = file.path, pair = "\(labels[0]) and \(labels[1])"
        let data: Data
        if named {
            data = try read(path, maximumBytes: ClusterLinkProbeHistory.maximumBytes)
        } else {
            do {
                guard let saved = try readSavedLinkProbes(file) else {
                    return said("no link probes are saved at \(path) (the pair's first load over the cable measures the link), so \(unmeasured)")
                }
                data = saved
            } catch { return said("\(path) is not used: \(error); so \(unmeasured)") }
        }
        guard let history = ClusterLinkProbeHistory.decode(data) else {
            if named { throw ProbeError("\(path) is not a link probe history (\(ClusterLinkProbeHistory.schemaName))") }
            return said("\(path) is not a link probe history the setup reads, so \(unmeasured)")
        }
        let measurements = history.measurements(members: labels, now: now)
        guard let costs = ClusterLinkCosts(measurements: measurements) else {
            let held = history.pairs[ClusterLinkProbeHistory.key(members: labels)] != nil
            let why = held ? "the probes saved for \(pair) in \(path) are more than 30 days old (or dated ahead)"
                : "\(path) holds no probe for \(pair) (the setup saves pairs by member ID: \(history.pairs.keys.sorted().joined(separator: ", ")))"
            if named { throw ProbeError("--link-probes: " + why) }
            return said("\(why), so \(unmeasured)")
        }
        // The keyed probes when there are any (`ClusterLinkCosts(measurements:)`).
        let keyed = measurements.filter(\.probe.keyed)
        let used = keyed.isEmpty ? measurements : keyed
        let formatter = ISO8601DateFormatter()
        let when = used.map { formatter.string(from: Date(timeIntervalSince1970: $0.measuredAt)) }
        return (costs, ["Link costs", "  No --link given: "
            + (used.count == 1 ? "the one link probe saved for \(pair) in \(path) (measured \(when[0]))"
                : "the median of the \(used.count) link probes saved for \(pair) in \(path) (measured \(when.last!) to \(when[0]))")
            + ", as the setup plans with \(used.count == 1 ? "it" : "them")" + (keyed.isEmpty ? "; plaintext only, so tensor parallel is not chosen" : "") + "."])
    }

    /// Each device's share probes of this model as the setup saved them
    /// (`ClusterShareProbeHistory`), for a plan given no `--share-probes`, and
    /// what was found, in words. The labels name the members (the setup keys
    /// them by member ID). The default file counts only as the setup reads it
    /// (owner-only) and is otherwise reported and left out; a file named with
    /// `--share-probes` must be a history.
    static func savedShares(_ file: URL?, named: Bool, labels: [String], artifactSHA256: String, now: Double) throws
        -> (rates: [String: [ClusterShareRate]], lines: [String]) {
        guard let file else { return ([:], []) }
        func said(_ text: String) -> (rates: [String: [ClusterShareRate]], lines: [String]) { ([:], ["Share probes", "  \(text)."]) }
        let data: Data
        if named {
            data = try read(file.path, maximumBytes: ClusterShareProbeHistory.maximumBytes)
        } else {
            do {
                guard let saved = try readSavedLinkProbes(file, maximumBytes: ClusterShareProbeHistory.maximumBytes) else { return ([:], []) }
                data = saved
            } catch { return said("\(file.path) is not used: \(error); every share is predicted as before") }
        }
        guard let history = ClusterShareProbeHistory.decode(data) else {
            if named { throw ProbeError("\(file.path) is not a share probe history (\(ClusterShareProbeHistory.schemaName))") }
            return said("\(file.path) is not a share probe history the setup reads; every share is predicted as before")
        }
        let rates = history.shareRates(artifactSHA256: artifactSHA256, members: labels, now: now)
        guard !rates.isEmpty else {
            return named ? said("\(file.path) holds no share probe of this model for \(labels.joined(separator: ", ")) from the last 30 days")
                : ([:], [])
        }
        let found = labels.compactMap { label in rates[label].map { points in
            "\(label) " + points.map { "\(Int((Double($0.sharePerMille) / 10).rounded()))% in \(String(format: "%.2f", 1000 / $0.decodeTokensPerSecond)) ms" }
                .joined(separator: ", ")
        } }
        return (rates, ["Share probes", "  The share steps saved in \(file.path), as the setup plans with them: \(found.joined(separator: "; "))."])
    }

    /// The setup's saved probe file as the setup reads it, nil when there is
    /// none: a regular file of this user's, readable by this user only,
    /// within the bound.
    static func readSavedLinkProbes(_ file: URL, maximumBytes: Int = ClusterLinkProbeHistory.maximumBytes) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let opened = errno
        if descriptor < 0 && opened == ENOENT { return nil }
        guard descriptor >= 0 else { throw ProbeError("it cannot be opened (errno \(opened))") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw ProbeError("it is not a file of this user's that only this user can read, as the setup requires")
        }
        guard info.st_size > 0, info.st_size <= Int64(maximumBytes),
              let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: maximumBytes + 1),
              !data.isEmpty, data.count <= maximumBytes else {
            throw ProbeError("it is empty or larger than \(maximumBytes) bytes")
        }
        return data
    }
}
