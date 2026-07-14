import Foundation
import MLX
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

enum MTPProductionLiveFixtures {
    static let liveEnvironment = "DARKBLOOM_LIVE_MLX_MTP"
    static let supervisorEnvironment = "DARKBLOOM_MTP_EXTERNAL_SUPERVISOR"
    static let supervisorContract = "run-mtp-benchmark-v1"
    static let defaultTargetID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    static let defaultAssistantID = "mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit"

    static var enabled: Bool {
        LiveInferenceFixtures.gemmaTestsEnabled
            && truthy(environment[liveEnvironment])
            && environment[supervisorEnvironment] == supervisorContract
    }

    static let disabledReason = Comment(
        rawValue: "run through scripts/run-mtp-benchmark.py; synchronous MLX work cannot be safely cancelled by a Swift task deadline and requires its external process-group timeout")

    static var targetID: String {
        environment["DARKBLOOM_MTP_TARGET_ID"] ?? defaultTargetID
    }

    static var assistantID: String {
        environment["DARKBLOOM_MTP_ASSISTANT_ID"] ?? defaultAssistantID
    }

    static func loadBundle() async throws -> MTPProductionModelBundle {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw MTPProductionLivePrerequisiteError.missingMetallib
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)
        let target = try targetSnapshot()
        let assistant = try assistantSnapshot()
        return try await MTPProductionModelBundle.load(
            targetID: targetID,
            targetDirectory: target,
            assistantID: assistantID,
            assistantDirectory: assistant)
    }

    static func targetSnapshot() throws -> URL {
        try requiredSnapshot(
            modelID: targetID, pathEnvironment: "DARKBLOOM_MTP_TARGET_PATH")
    }

    static func assistantSnapshot() throws -> URL {
        try requiredSnapshot(
            modelID: assistantID, pathEnvironment: "DARKBLOOM_MTP_ASSISTANT_PATH")
    }

    static func prompts(bundle: MTPProductionModelBundle) throws -> [MTPBenchmarkPrompt] {
        try [
            bundle.tokenizeChat(
                name: "code",
                userPrompt: "Write a Swift function that returns the larger of two integers."),
            bundle.tokenizeChat(
                name: "reasoning",
                userPrompt: "A train travels 120 km in 90 minutes. State its average speed in km/h."),
            bundle.tokenizeChat(
                name: "arithmetic",
                userPrompt: "What is 17 multiplied by 23? Reply with only the number."),
        ]
    }

    static func toolPrompt(bundle: MTPProductionModelBundle) throws -> MTPBenchmarkPrompt {
        let tools: [[String: any Sendable]] = [[
            "type": "function",
            "function": [
                "name": "lookup_weather",
                "description": "Look up current weather for a city.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "city": ["type": "string"] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": ["city"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]]
        return try bundle.tokenize(
            name: "tool",
            messages: [["role": "user", "content": "What is the weather in Paris? Use the tool."]],
            tools: tools)
    }

    static func benchmarkOutput() throws -> MTPBenchmarkReportDestination {
        guard let value = environment["DARKBLOOM_MTP_BENCHMARK_OUTPUT"], !value.isEmpty else {
            throw MTPProductionLivePrerequisiteError.missingBenchmarkOutput
        }
        guard let runDirectoryValue = environment["DARKBLOOM_MTP_BENCHMARK_RUN_DIRECTORY"],
              let expectedDeviceValue = environment["DARKBLOOM_MTP_BENCHMARK_RUN_DEVICE"],
              let expectedInodeValue = environment["DARKBLOOM_MTP_BENCHMARK_RUN_INODE"],
              let expectedDevice = UInt64(expectedDeviceValue),
              let expectedInode = UInt64(expectedInodeValue)
        else {
            throw MTPProductionLivePrerequisiteError.missingSecureOutputContract
        }
        let output = URL(fileURLWithPath: value).standardizedFileURL
        let runDirectory = URL(fileURLWithPath: runDirectoryValue).standardizedFileURL
        guard output.deletingLastPathComponent() == runDirectory else {
            throw MTPProductionLivePrerequisiteError.unsafeBenchmarkOutput(output.path)
        }
        let systemTemp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let package = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let repoTemp = package.lastPathComponent == "provider-swift"
            ? package.deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
            : package.appendingPathComponent("tmp", isDirectory: true)
        let resolvedRoots = [systemTemp, repoTemp.resolvingSymlinksInPath().standardizedFileURL]
        guard resolvedRoots.contains(where: { isDescendant(runDirectory, of: $0) }) else {
            throw MTPProductionLivePrerequisiteError.unsafeBenchmarkOutput(output.path)
        }
        return try MTPBenchmarkReportDestination.open(
            directoryURL: runDirectory,
            fileName: output.lastPathComponent,
            expectedDevice: expectedDevice,
            expectedInode: expectedInode)
    }

    static var benchmarkMaxTokens: Int {
        environment["DARKBLOOM_MTP_BENCHMARK_MAX_TOKENS"].flatMap(Int.init) ?? 64
    }

    static var benchmarkDeadline: Duration {
        let seconds = environment["DARKBLOOM_MTP_BENCHMARK_DEADLINE_SECONDS"]
            .flatMap(Int.init) ?? 3600
        return .seconds(max(1, seconds))
    }

    static var benchmarkPurpose: MTPBenchmarkPurpose {
        switch environment["DARKBLOOM_MTP_BENCHMARK_MODE"] {
        case "production-performance": return .productionPerformance
        case "production-correctness": return .productionCorrectness
        default: return .rawParityStress
        }
    }

    static var benchmarkMTPExpectation: MTPBenchmarkMTPExpectation {
        truthy(environment["DARKBLOOM_MTP_BENCHMARK_EXPECT_MTP_INACTIVE"])
            ? .m5HardwareSafetyGate
            : .active
    }

    static func benchmarkStopPolicy(
        bundle: MTPProductionModelBundle
    ) -> MTPBenchmarkStopPolicy {
        benchmarkPurpose == .rawParityStress
            ? .rawFixedLength
            : .production(tokenIDs: bundle.productionStopTokenIDs)
    }

    static var benchmarkWarmupIterations: Int {
        max(0, environment["DARKBLOOM_MTP_BENCHMARK_WARMUP"].flatMap(Int.init) ?? 0)
    }

    static var benchmarkRepetitions: Int {
        max(1, environment["DARKBLOOM_MTP_BENCHMARK_REPETITIONS"].flatMap(Int.init) ?? 1)
    }

    static var benchmarkModeOrderSeed: UInt64 {
        environment["DARKBLOOM_MTP_BENCHMARK_SEED"].flatMap(UInt64.init) ?? 0x4d545032
    }

    static func benchmarkRunFingerprint() throws -> String {
        guard let value = environment["DARKBLOOM_MTP_BENCHMARK_RUN_FINGERPRINT"],
              !value.isEmpty
        else { throw MTPProductionLivePrerequisiteError.missingRunFingerprint }
        guard environment["DARKBLOOM_MTP_BENCHMARK_BUILD_CONFIGURATION"]
                == MTPBenchmarkBuildConfiguration.current.rawValue
        else { throw MTPProductionLivePrerequisiteError.buildConfigurationMismatch }
        return value
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func isDescendant(_ path: URL, of root: URL) -> Bool {
        let normalizedPath = path.standardizedFileURL.path
        let normalizedRoot = root.standardizedFileURL.path
        return normalizedPath == normalizedRoot
            || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func requiredSnapshot(
        modelID: String,
        pathEnvironment: String
    ) throws -> URL {
        if let path = environment[pathEnvironment], !path.isEmpty {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(
                atPath: url.appendingPathComponent("config.json").path)
            else {
                throw MTPProductionLivePrerequisiteError.incompleteSnapshot(
                    modelID: modelID, path: url.path)
            }
            return url
        }
        guard let url = ModelScanner.resolveLocalPath(modelID: modelID) else {
            throw MTPProductionLivePrerequisiteError.modelNotInCache(modelID)
        }
        return url.resolvingSymlinksInPath()
    }
}

enum MTPProductionLivePrerequisiteError: Error, CustomStringConvertible {
    case missingMetallib
    case modelNotInCache(String)
    case incompleteSnapshot(modelID: String, path: String)
    case missingBenchmarkOutput
    case missingSecureOutputContract
    case missingRunFingerprint
    case buildConfigurationMismatch
    case unsafeBenchmarkOutput(String)

    var description: String {
        switch self {
        case .missingMetallib:
            return "mlx.metallib is unavailable; run scripts/fetch-metallib.sh debug"
        case .modelNotInCache(let id):
            return "required cached model is missing: \(id); this test never downloads"
        case .incompleteSnapshot(let id, let path):
            return "cached snapshot for \(id) is incomplete at \(path)"
        case .missingBenchmarkOutput:
            return "DARKBLOOM_MTP_BENCHMARK_OUTPUT must name the supervised run report"
        case .missingSecureOutputContract:
            return "the supervised benchmark run-directory descriptor identity is missing"
        case .missingRunFingerprint:
            return "DARKBLOOM_MTP_BENCHMARK_RUN_FINGERPRINT is required"
        case .buildConfigurationMismatch:
            return "benchmark build configuration does not match the compiled Swift target"
        case .unsafeBenchmarkOutput(let path):
            return "refusing tracked MTP benchmark output path: \(path)"
        }
    }
}
