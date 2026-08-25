import ProviderBenchmark
import Testing

@testable import darkbloom

@Suite("signed scheduler-prefill benchmark CLI")
struct BenchmarkSchedulerPrefillDecisionTests {
    private let modelHash = String(repeating: "a", count: 64)
    private let binaryHash = String(repeating: "b", count: 64)
    private let sourceSHA = String(repeating: "c", count: 40)

    private func arguments(
        model: String = "EigenLabs/Qwen3.6-35B",
        iterations: Int = 10
    ) -> [String] {
        [
            "--scheduler-prefill-decision",
            "--model", model,
            "--expected-model-aggregate-sha256", modelHash,
            "--expected-registered-binary-sha256", binaryHash,
            "--expected-version", "0.8.11",
            "--source-sha", sourceSHA,
            "--decision-iterations", String(iterations),
            "--kv-backend", "paged",
        ]
    }

    @Test("parses the complete signed mode contract")
    func parsesSignedMode() throws {
        let command = try Benchmark.parse(arguments())
        let options = try command.signedSchedulerPrefillDecisionOptions()

        #expect(command.schedulerPrefillDecision)
        #expect(options.modelID == "EigenLabs/Qwen3.6-35B")
        #expect(options.expectedModelAggregateSHA256 == modelHash)
        #expect(options.expectedRegisteredBinarySHA256 == binaryHash)
        #expect(options.expectedVersion == "0.8.11")
        #expect(options.sourceSHA == sourceSHA)
        #expect(options.iterations == 10)
        #expect(options.kvBackend == .paged)
    }

    @Test("benchmark modes conflict fail closed")
    func rejectsModeConflict() throws {
        let command = try Benchmark.parse(arguments() + ["--sweep"])
        let message = try #require(command.benchmarkModeConflict())
        #expect(message.contains("--scheduler-prefill-decision"))
        #expect(message.contains("--sweep"))
    }

    @Test("hashes, source, and minimum iterations are strict")
    func rejectsMalformedIdentityInputs() throws {
        var malformed = try Benchmark.parse(arguments())
        malformed.expectedRegisteredBinarySHA256 = binaryHash.uppercased()
        #expect(throws: Benchmark.SignedSchedulerPrefillDecisionInputError.self) {
            _ = try malformed.signedSchedulerPrefillDecisionOptions()
        }

        var shortSource = try Benchmark.parse(arguments())
        shortSource.sourceSHA = "abc"
        #expect(throws: Benchmark.SignedSchedulerPrefillDecisionInputError.self) {
            _ = try shortSource.signedSchedulerPrefillDecisionOptions()
        }

        let tooFew = try Benchmark.parse(arguments(iterations: 9))
        #expect(throws: Benchmark.SignedSchedulerPrefillDecisionInputError.self) {
            _ = try tooFew.signedSchedulerPrefillDecisionOptions()
        }
    }

    @Test("local-path-shaped model identifiers are rejected")
    func rejectsLocalModelPaths() throws {
        for model in [
            "../weights", "Users/alice", #"C:\models\qwen"#,
            "file:///tmp/qwen", "/tmp/qwen", "~/qwen", " EigenLabs/Qwen",
            "EigenLabs/Qwen\ncandidate",
        ] {
            let command = try Benchmark.parse(arguments(model: model))
            #expect(throws: Benchmark.SignedSchedulerPrefillDecisionInputError.self) {
                _ = try command.signedSchedulerPrefillDecisionOptions()
            }
        }
    }

    @Test("exit mapping distinguishes pass, policy failure, and invalid evidence")
    func exitMapping() {
        #expect(SchedulerPrefillDecisionExitStatus.value(
            evidenceClass: .signedCandidateModelFamily,
            outcome: .pass,
            signedIdentityPresent: true) == 0)
        #expect(SchedulerPrefillDecisionExitStatus.value(
            evidenceClass: .signedCandidateModelFamily,
            outcome: .fail,
            signedIdentityPresent: true) == 1)
        #expect(SchedulerPrefillDecisionExitStatus.value(
            evidenceClass: .signedCandidateModelFamily,
            outcome: .insufficientEvidence,
            signedIdentityPresent: true) == 2)
        #expect(SchedulerPrefillDecisionExitStatus.value(
            evidenceClass: .unsignedLocalHarness,
            outcome: .pass,
            signedIdentityPresent: false) == 2)
    }
}
