import ArgumentParser
import Foundation
import Testing
@testable import darkbloom

@Suite("Exact benchmark directory identity")
struct BenchmarkArtifactIdentityTests {
    private let hash = String(repeating: "a", count: 64)
    private let directory = URL(fileURLWithPath: "/tmp/exact-view", isDirectory: true)

    @Test(arguments: ["--sweep", "--scheduler-prefill", "--arrival-invariance"])
    func supportedModesRequireExplicitModelAndHash(mode: String) throws {
        let base = [mode, "--model", "target", "--model-directory", directory.path]
        #expect(try Benchmark.parse(base).modelDirectoryOptionError() != nil)
        let selected = try Benchmark.parse(base + ["--expected-model-aggregate-sha256", hash])
        #expect(selected.modelDirectoryOptionError() == nil)
        #expect(selected.exactModelDirectoryOverride() == directory)
        #expect(try Benchmark.parse([mode, "--model-directory", directory.path,
            "--expected-model-aggregate-sha256", hash]).modelDirectoryOptionError() != nil)
        for invalid in ["", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            #expect(try Benchmark.parse(base + ["--expected-model-aggregate-sha256", invalid]).modelDirectoryOptionError() != nil)
        }
    }

    @Test func unsupportedModesCannotIgnoreTheDirectory() throws {
        for mode in [[], ["--parity"], ["--scheduler-prefill-decision"]] {
            let parsed = try Benchmark.parse(mode + ["--model", "target", "--model-directory", directory.path,
                "--expected-model-aggregate-sha256", hash])
            #expect(parsed.modelDirectoryOptionError() != nil)
        }
    }

    @Test func beforeMismatchNeverStartsMeasurement() async {
        var calls = 0
        await #expect(throws: BenchmarkArtifactIdentity.Failure.beforeMismatch) {
            try await BenchmarkArtifactIdentity.measure(
                modelID: "target", modelDirectory: directory, expectedHash: hash,
                readHash: { nil }, operation: { calls += 1; return "report" })
        }
        #expect(calls == 0)
    }

    @Test func changedArtifactCannotReturnAPublishableReport() async {
        var hashes = 0, measurements = 0, reports = 0
        await #expect(throws: BenchmarkArtifactIdentity.Failure.afterMismatch) {
            let measured = try await BenchmarkArtifactIdentity.measure(
                modelID: "target", modelDirectory: directory, expectedHash: hash,
                readHash: { hashes += 1; return hashes == 1 ? hash : String(repeating: "b", count: 64) },
                operation: { measurements += 1; return "{\"status\":\"success\"}" })
            _ = try measured.json(measured.result)
            reports += 1
        }
        #expect(hashes == 2 && measurements == 1 && reports == 0)
    }

    @Test func verifiedReportCarriesTheHashBracket() async throws {
        var events: [String] = []
        let measured = try await BenchmarkArtifactIdentity.measure(
            modelID: "target", modelDirectory: directory, expectedHash: hash,
            readHash: { events.append("hash"); return hash },
            operation: { events.append("measure"); return "{\"probe\":18446744073709551615}" })
        #expect(events == ["hash", "measure", "hash"])
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(measured.json(measured.result).utf8)) as? [String: Any])
        let identity = try #require(object["artifactIdentity"] as? [String: Any])
        #expect(identity["expectedModelAggregateSHA256"] as? String == hash)
        #expect(identity["beforeModelAggregateSHA256"] as? String == hash)
        #expect(identity["afterModelAggregateSHA256"] as? String == hash)
        #expect((object["probe"] as? NSNumber)?.stringValue == "18446744073709551615")
    }

    @Test func normalDiscoveryKeepsItsExistingPublicationPath() async throws {
        let measured = try await BenchmarkArtifactIdentity.measure(
            modelID: "target", modelDirectory: directory, expectedHash: nil,
            readHash: { Issue.record("normal discovery should not add a hash pass"); return nil },
            operation: { "{\"ordinary\":true}" })
        #expect(measured.receipt == nil)
        #expect(try measured.json(measured.result) == measured.result)
    }
}
