import Foundation
import Testing
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
@_spi(Diagnostics) import MLXLMCommon
#endif
@testable import radix_engine

struct BenchmarkPersistentTestKeysTests {
    private let base = ["radix-engine", "/nonexistent-model", "/nonexistent-input", "/nonexistent-output",
                        "cache-on", "mtp-on", "paged", "ssd", "persistent-key"]
    private let identifier = "F6AD7F58-BF43-4F6D-A6F2-A9D719E68490"
    private let group = "TESTTEAM.io.darkbloom.test"
    private var flags: [String] {
        ["--persistent-test-namespace", identifier, "--persistent-test-access-group", group]
    }
    private var environment: [String: String] {
        ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
         "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
         "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": "/tmp/darkbloom-namespace-option-test"]
    }

    @Test func noNamespaceKeepsDefaultInvocationWithoutTestContext() throws {
        #expect(try BenchmarkOptions(base, environment: [:]).persistentTestKeys == nil)
    }

    #if RADIX_CANDIDATE
    @Test func pairedFlagsSelectOneTypedNamespaceAndPreserveServingOptions() throws {
        let options = try BenchmarkOptions(base + flags, environment: environment)
        let keys = try #require(options.persistentTestKeys)
        #expect(keys.namespace.identifier == UUID(uuidString: identifier))
        #expect(keys.namespace.accessGroup == group)
        #expect(keys.provenance["namespace"] == identifier.lowercased())
        #expect(keys.provenance["access_group"] == group)
        #expect(keys.provenance["isolated_root"] == environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"])
        #expect(keys.provenance["enclave_label"] == keys.namespace.enclaveLabel)
        #expect(keys.provenance["wrapped_kek_service"] == keys.namespace.wrappedKEKService)
        #expect(keys.provenance["wrapped_kek_account"] == keys.namespace.wrappedKEKAccount)
        #expect(options.cacheEnabled && options.mtpEnabled && options.requirePersistentKey)
        #expect(options.backend.rawValue == "paged")
    }

    @Test func partialInvalidOrConflictingSelectionFailsAtArgumentParsing() {
        let invalid = [
            Array(flags.prefix(2)), Array(flags.suffix(2)), flags + Array(flags.prefix(2)),
            ["--persistent-test-namespace", "not-a-uuid", "--persistent-test-access-group", group],
            ["--persistent-test-namespace", identifier, "--persistent-test-access-group", "TESTTEAM.*"],
            flags + ["--native-kv-probe-only"],
        ]
        for selected in invalid {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + selected, environment: environment) }
        }
        for (index, value) in [(7, "resident"), (8, "ephemeral-key")] {
            var changed = base
            changed[index] = value
            #expect(throws: (any Error).self) { try BenchmarkOptions(changed + flags, environment: environment) }
        }
        for missing in environment.keys {
            var incomplete = environment
            incomplete.removeValue(forKey: missing)
            #expect(throws: SSDPersistentTestKeyNamespace.Failure.self) {
                try BenchmarkOptions(base + flags, environment: incomplete)
            }
        }
    }

    @Test func loaderRefusesChangedContextBeforeReadingMissingModelConfig() async throws {
        let options = try BenchmarkOptions(base + flags, environment: environment)
        let input = Data("""
            {"rows":[{"case":{"id":"first","kind":"first"},"request":{"model":"fixture","max_tokens":8}}]}
            """.utf8)
        let report = try JSONDecoder().decode(HTTPReport.self, from: input)
        var missing = environment
        missing.removeValue(forKey: "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY")
        await #expect(throws: SSDPersistentTestKeyNamespace.Failure.persistentModeRequired) {
            try await BenchmarkLoader.load(options: options, report: report, modelID: "fixture", environment: missing)
        }
        var moved = environment
        moved["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] = "/tmp/darkbloom-namespace-moved-root"
        do {
            _ = try await BenchmarkLoader.load(options: options, report: report, modelID: "fixture", environment: moved)
            Issue.record("changed persistent root reached model loading")
        } catch let error as RadixBenchmark.Failure {
            switch error {
            case .message(let message):
                #expect(message == "persistent test key context changed after argument validation")
            }
        }
    }

    @Test func observedModeIsRecordedWithoutInventingPersistentSuccess() throws {
        let keys = try #require(BenchmarkOptions(base + flags, environment: environment).persistentTestKeys)
        let observed = keys.observedProvenance(keyMode: "persistent")
        #expect(Set(observed.keys) == Set(keys.provenance.keys).union(["actual_key_mode"]))
        #expect(observed["actual_key_mode"] as? String == "persistent")
        try keys.requireObservedMode("persistent", cacheEnabled: true)
        for mode in [nil, "ephemeral"] as [String?] {
            #expect(throws: RadixBenchmark.Failure.self) { try keys.requireObservedMode(mode, cacheEnabled: true) }
        }
        try keys.requireObservedMode(nil, cacheEnabled: false)
        #expect(keys.observedProvenance(keyMode: nil)["actual_key_mode"] is NSNull)
    }

    @Test func namespaceOptionsComposeWithAttentionAndLogitDiagnostics() throws {
        var ordinaryDecode = base
        ordinaryDecode[5] = "mtp-off"
        let options = try BenchmarkOptions(ordinaryDecode + flags + ["--logit-diagnostic-position", "62",
            "--logit-diagnostic-candidates", "1928,6829", "--attention-metadata-position", "62",
            "--attention-packet-position", "62", "--attention-packet-layer", "9"],
            environment: environment)
        #expect(options.persistentTestKeys?.provenance["namespace"] == identifier.lowercased())
        #expect(options.logitDiagnostic?.outputIndex == 62)
        #expect(options.logitDiagnostic?.candidateIDs == [1928, 6829])
        #expect(options.attentionMetadata?.outputIndex == 62)
        #expect(options.attentionPacket?.outputIndex == 62)
        #expect(options.attentionPacket?.storageLayerIndex == 9)
        let packet = ["--attention-packet-position", "62", "--attention-packet-layer", "9"]
        for mixed in [flags + Array(packet.prefix(2)), Array(flags.prefix(2)) + packet,
                      flags + packet + ["--concurrency", "2"]] {
            #expect(throws: (any Error).self) {
                try BenchmarkOptions(ordinaryDecode + mixed, environment: environment)
            }
        }
    }
    #else
    @Test func archivedBuildRejectsNamespacedKeysInsteadOfIgnoringThem() {
        #expect(throws: (any Error).self) { try BenchmarkOptions(base + flags, environment: environment) }
    }
    #endif
}
