import Foundation
import ProviderCore
@_spi(Diagnostics) import MLXLMCommon

struct BenchmarkOptions: Sendable {
    let modelDirectory: URL
    let inputURL: URL
    let outputURL: URL
    let cacheEnabled: Bool
    let mtpEnabled: Bool
    let backend: EngineV2KVBackendSelection
    let cacheMode: String
    let requirePersistentKey: Bool
    let concurrency: Int
    let kvBudgetBytes: Int
    let nativeKVProbeOnly: Bool
    let productionKVGrant: Bool
    let assistantDirectory: URL?
    let gemmaMTPVerification: String?
    let gemmaProjectionTokens: [Int]?
    let expectedModelSHA256: String?
    let logitDiagnostic: CBv2LogitDiagnosticConfig?
    let attentionMetadata: CBv2AttentionMetadataConfig?
    let attentionPacket: CBv2AttentionPacketConfig?
    let persistentTestKeys: BenchmarkPersistentTestKeys?

    init(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let positional = Array(arguments.prefix { !$0.hasPrefix("--") })
        var concurrency = 1
        var kvBudgetGiB = 16
        var nativeKVProbeOnly = false
        var productionKVGrant = false
        var assistantDirectory: URL?
        var gemmaMTPVerification: String?
        var gemmaProjectionTokens: [Int]?
        var expectedModelSHA256: String?
        var diagnosticPosition: Int?
        var diagnosticCandidates: [Int]?
        var attentionMetadataPosition: Int?
        var attentionPacketPosition: Int?
        var attentionPacketLayer: Int?
        var persistentNamespace: String?
        var persistentAccessGroup: String?
        var seen = Set<String>()
        var index = positional.count
        while index < arguments.count {
            let flag = arguments[index]
            if ["--native-kv-probe-only", "--production-kv-grant"].contains(flag), seen.insert(flag).inserted {
                if flag == "--native-kv-probe-only" { nativeKVProbeOnly = true }
                else { productionKVGrant = true }
                index += 1
                continue
            }
            guard index + 1 < arguments.count, seen.insert(flag).inserted else {
                throw RadixBenchmark.Failure.message("missing, duplicate or invalid benchmark option: \(flag)")
            }
            let raw = arguments[index + 1]
            switch flag {
            case "--concurrency" where [1, 2, 4].contains(Int(raw) ?? 0): concurrency = Int(raw)!
            case "--kv-budget-gib" where (1...128).contains(Int(raw) ?? 0): kvBudgetGiB = Int(raw)!
            case "--assistant-directory" where !raw.isEmpty:
                assistantDirectory = URL(fileURLWithPath: raw)
            case "--gemma-mtp-verification":
                guard ["automatic", "serial_target"].contains(raw) else {
                    throw RadixBenchmark.Failure.message("Gemma verifier must be automatic or serial_target")
                }
                gemmaMTPVerification = raw
            case "--gemma-projection-tokens":
                let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                let tokens = parts.compactMap { Int($0) }
                guard tokens.count == 2, tokens.allSatisfy({ (0...Int(Int32.max)).contains($0) }),
                    tokens.map(String.init).joined(separator: ",") == raw else {
                    throw RadixBenchmark.Failure.message("Gemma projection requires exactly two canonical token IDs")
                }
                gemmaProjectionTokens = tokens
            case "--expected-model-sha256" where raw.count == 64
                && raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }):
                expectedModelSHA256 = raw
            case "--logit-diagnostic-position" where Int(raw) != nil:
                diagnosticPosition = Int(raw)
            case "--attention-metadata-position" where Int(raw) != nil:
                attentionMetadataPosition = Int(raw)
            case "--attention-packet-position" where Int(raw) != nil:
                attentionPacketPosition = Int(raw)
            case "--attention-packet-layer" where Int(raw) != nil:
                attentionPacketLayer = Int(raw)
            case "--logit-diagnostic-candidates":
                let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                let ids = parts.compactMap { Int($0) }
                guard ids.count == parts.count else {
                    throw RadixBenchmark.Failure.message("invalid diagnostic candidate IDs")
                }
                diagnosticCandidates = ids
            case "--persistent-test-namespace": persistentNamespace = raw
            case "--persistent-test-access-group": persistentAccessGroup = raw
            default: throw RadixBenchmark.Failure.message("unsupported benchmark option: \(flag)")
            }
            index += 2
        }
        let arguments = positional
        guard (5...9).contains(arguments.count),
            ["cache-on", "cache-off"].contains(arguments[4]),
            arguments.count < 6 || ["mtp-on", "mtp-off"].contains(arguments[5]),
            let backend = EngineV2KVBackendSelection(rawValue: arguments.count < 7 ? "auto" : arguments[6]),
            arguments.count < 8 || ["ssd", "resident"].contains(arguments[7]),
            arguments.count < 9 || ["persistent-key", "ephemeral-key"].contains(arguments[8])
        else {
            throw RadixBenchmark.Failure.message(
                "usage: radix-engine MODEL_DIRECTORY HTTP_REPORT_JSON OUTPUT_JSON cache-on|cache-off [mtp-on|mtp-off] [auto|paged|contiguous] [ssd|resident] [persistent-key|ephemeral-key] [--concurrency 1|2|4] [--kv-budget-gib 1...128 | --production-kv-grant] [--assistant-directory DIRECTORY] [--expected-model-sha256 SHA256] [--native-kv-probe-only] [--persistent-test-namespace UUID --persistent-test-access-group GROUP]")
        }
        modelDirectory = URL(fileURLWithPath: arguments[1])
        inputURL = URL(fileURLWithPath: arguments[2])
        outputURL = URL(fileURLWithPath: arguments[3])
        cacheEnabled = arguments[4] == "cache-on"
        mtpEnabled = arguments.count > 5 && arguments[5] == "mtp-on"
        self.backend = backend
        cacheMode = arguments.count < 8 ? "ssd" : arguments[7]
        requirePersistentKey = arguments.count < 9 || arguments[8] == "persistent-key"
        self.concurrency = concurrency
        kvBudgetBytes = kvBudgetGiB * 1_073_741_824
        self.nativeKVProbeOnly = nativeKVProbeOnly
        self.productionKVGrant = productionKVGrant
        guard !productionKVGrant || (cacheMode == "ssd" && !nativeKVProbeOnly && !seen.contains("--kv-budget-gib")) else {
            throw RadixBenchmark.Failure.message("production grant requires the serving SSD path and excludes explicit KV/probe-only options")
        }
        guard cacheMode == "ssd" || (assistantDirectory == nil && expectedModelSHA256 == nil) else {
            throw RadixBenchmark.Failure.message("artifact verification options require the production SSD path")
        }
        self.assistantDirectory = assistantDirectory
        self.gemmaMTPVerification = gemmaMTPVerification
        self.gemmaProjectionTokens = gemmaProjectionTokens
        #if !RADIX_CANDIDATE
        guard gemmaMTPVerification == nil else {
            throw RadixBenchmark.Failure.message("Gemma verifier control requires the candidate artifact")
        }
        #endif
        guard gemmaMTPVerification == nil || (mtpEnabled && concurrency == 1
            && productionKVGrant && !cacheEnabled && cacheMode == "ssd" && !nativeKVProbeOnly
            && backend != .auto && expectedModelSHA256 != nil) else {
            throw RadixBenchmark.Failure.message(
                "Gemma verifier control requires B1 MTP-on, cache-off, pinned model, explicit backend and production grant")
        }
        guard gemmaProjectionTokens == nil || (gemmaMTPVerification != nil && diagnosticPosition == nil
            && attentionMetadataPosition == nil && attentionPacketPosition == nil) else {
            throw RadixBenchmark.Failure.message("Gemma projection requires an explicit verifier and excludes other numerical diagnostics")
        }
        self.expectedModelSHA256 = expectedModelSHA256
        persistentTestKeys = try BenchmarkPersistentTestKeys.parse(
            identifier: persistentNamespace, accessGroup: persistentAccessGroup,
            cacheMode: cacheMode, requirePersistentKey: requirePersistentKey,
            nativeKVProbeOnly: nativeKVProbeOnly, environment: environment)
        guard (diagnosticPosition == nil) == (diagnosticCandidates == nil),
            diagnosticPosition == nil || (concurrency == 1 && !nativeKVProbeOnly)
        else {
            throw RadixBenchmark.Failure.message(
                "diagnostic requires both position and candidate IDs, serial requests, and the serving path")
        }
        if let diagnosticPosition, let diagnosticCandidates {
            logitDiagnostic = try CBv2LogitDiagnosticConfig(
                requestID: 2, outputIndex: diagnosticPosition, candidateIDs: diagnosticCandidates)
        } else { logitDiagnostic = nil }
        if let attentionMetadataPosition {
            guard concurrency == 1, !nativeKVProbeOnly, !mtpEnabled, cacheMode == "ssd" else {
                throw RadixBenchmark.Failure.message(
                    "attention metadata requires the B1, MTP-off serving SSD path")
            }
            attentionMetadata = try CBv2AttentionMetadataConfig(
                requestID: 2, outputIndex: attentionMetadataPosition)
        } else { attentionMetadata = nil }
        guard (attentionPacketPosition == nil) == (attentionPacketLayer == nil) else {
            throw RadixBenchmark.Failure.message("attention packet requires both position and storage layer")
        }
        if let attentionPacketPosition, let attentionPacketLayer {
            guard concurrency == 1, !nativeKVProbeOnly, !mtpEnabled, cacheMode == "ssd" else {
                throw RadixBenchmark.Failure.message("attention packet requires the B1, MTP-off serving SSD path")
            }
            attentionPacket = try CBv2AttentionPacketConfig(
                requestID: 2, outputIndex: attentionPacketPosition, storageLayerIndex: attentionPacketLayer)
        } else { attentionPacket = nil }
    }
}
