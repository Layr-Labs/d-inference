import Foundation
import ProviderCore

/// Environment contract used by the opt-in `swift test` evaluation harness.
///
/// Keeping parsing here prevents the test body from becoming a second,
/// drifting command-line implementation.
enum SchedulerPrefillDecisionCLI {
    static let enableKey = "DARKBLOOM_QWEN_FCFS_LIVE"
    static let modelPathKey = "DARKBLOOM_QWEN_FCFS_MODEL_PATH"
    static let modelIDKey = "DARKBLOOM_QWEN_FCFS_MODEL_ID"
    static let expectedModelHashKey = "DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH"
    static let sourceSHAKey = "DARKBLOOM_QWEN_FCFS_SOURCE_SHA"
    static let iterationsKey = "DARKBLOOM_QWEN_FCFS_ITERATIONS"
    static let kvBackendKey = "DARKBLOOM_QWEN_FCFS_KV_BACKEND"
    static let outputPathKey = "DARKBLOOM_QWEN_FCFS_OUTPUT"

    struct LiveOptions {
        let modelID: String
        let modelDirectory: URL
        let expectedModelHash: String
        let sourceSHA: String?
        let iterations: Int
        let kvBackend: EngineV2KVBackendSelection
    }

    static func liveEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[enableKey] == "1"
    }

    static func liveOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveOptions {
        guard let modelPath = environment[modelPathKey], !modelPath.isEmpty else {
            throw SchedulerPrefillDecisionCLIError.missingModelPath
        }
        guard let modelID = environment[modelIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !modelID.isEmpty
        else {
            throw SchedulerPrefillDecisionCLIError.missingModelID
        }
        guard SchedulerPrefillDecisionMetadata.isReportSafeModelID(modelID) else {
            throw SchedulerPrefillDecisionCLIError.invalidModelID
        }
        guard let expectedModelHash = environment[expectedModelHashKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            isHex(expectedModelHash, lengths: [64])
        else {
            throw SchedulerPrefillDecisionCLIError.invalidExpectedModelHash
        }

        let sourceSHA = environment[sourceSHAKey] ?? environment["GITHUB_SHA"]
        if let sourceSHA, !isHex(sourceSHA, lengths: [40, 64]) {
            throw SchedulerPrefillDecisionCLIError.invalidSourceSHA(sourceSHA)
        }

        let iterations = environment[iterationsKey].flatMap(Int.init)
            ?? SchedulerPrefillDecisionEvaluator.thresholds.minimumLiveIterations
        guard iterations > 0 else {
            throw SchedulerPrefillDecisionCLIError.invalidIterations(iterations)
        }

        let backendName = (environment[kvBackendKey] ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let kvBackend: EngineV2KVBackendSelection
        switch backendName {
        case "auto":
            kvBackend = .auto
        case "contiguous":
            kvBackend = .contiguous
        case "paged":
            kvBackend = .paged
        default:
            throw SchedulerPrefillDecisionCLIError.invalidKVBackend(backendName)
        }

        return LiveOptions(
            modelID: modelID,
            modelDirectory: URL(
                fileURLWithPath: modelPath,
                isDirectory: true
            ).resolvingSymlinksInPath(),
            expectedModelHash: expectedModelHash,
            sourceSHA: sourceSHA?.lowercased(),
            iterations: iterations,
            kvBackend: kvBackend)
    }

    static func writeOutputIfRequested(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let outputPath = environment[outputPathKey], !outputPath.isEmpty else {
            return
        }
        try data.write(
            to: URL(fileURLWithPath: outputPath),
            options: .atomic)
    }

    private static func isHex(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}

enum SchedulerPrefillDecisionCLIError: Error, CustomStringConvertible {
    case missingModelPath
    case missingModelID
    case invalidModelID
    case invalidExpectedModelHash
    case invalidSourceSHA(String)
    case invalidIterations(Int)
    case invalidKVBackend(String)

    var description: String {
        switch self {
        case .missingModelPath:
            return "\(SchedulerPrefillDecisionCLI.modelPathKey) must be set and non-empty"
        case .missingModelID:
            return "\(SchedulerPrefillDecisionCLI.modelIDKey) must be set and non-empty"
        case .invalidModelID:
            return "\(SchedulerPrefillDecisionCLI.modelIDKey) must be a canonical "
                + "registry label, not a path, URI, or traversal"
        case .invalidExpectedModelHash:
            return "\(SchedulerPrefillDecisionCLI.expectedModelHashKey) must be a "
                + "64-character SHA-256 digest"
        case .invalidSourceSHA(let value):
            return "\(SchedulerPrefillDecisionCLI.sourceSHAKey) must be a 40- or "
                + "64-character hexadecimal commit SHA; got \(value)"
        case .invalidIterations(let value):
            return "\(SchedulerPrefillDecisionCLI.iterationsKey) must be positive; got \(value)"
        case .invalidKVBackend(let value):
            return "\(SchedulerPrefillDecisionCLI.kvBackendKey) must be auto, "
                + "contiguous, or paged; got \(value)"
        }
    }
}
