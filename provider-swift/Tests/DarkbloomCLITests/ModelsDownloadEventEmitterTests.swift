import ArgumentParser
import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("models download --json NDJSON emitter")
struct ModelsDownloadEventEmitterTests {

    private final class CapturedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock(); storage.append(line); lock.unlock()
        }
        var lines: [String] {
            lock.withLock { storage }
        }
    }

    private func makeEmitter(
        interval: TimeInterval = 0.2,
        clock: TestClock = TestClock()
    ) -> (ModelsDownloadEventEmitter, CapturedLines, TestClock) {
        let captured = CapturedLines()
        let emitter = ModelsDownloadEventEmitter(
            minProgressInterval: interval,
            now: { clock.now },
            write: { captured.append($0) }
        )
        return (emitter, captured, clock)
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        var now: Date {
            lock.withLock { current }
        }
        func advance(by seconds: TimeInterval) {
            lock.lock(); current += seconds; lock.unlock()
        }
    }

    @Test("progress events serialize one compact, sorted-keys JSON object per line")
    func progressLineSchema() {
        let (emitter, captured, _) = makeEmitter()

        emitter.emit(
            ModelDownloader.DownloadEvent(
                phase: .progress, file: "model-00001-of-00002.safetensors",
                bytesDownloaded: 1_048_576, bytesTotal: 4_194_304),
            model: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        #expect(captured.lines == [
            #"{"bytes":1048576,"event":"progress","file":"model-00001-of-00002.safetensors","model":"mlx-community/Qwen2.5-7B-Instruct-4bit","total":4194304}"#
        ])
    }

    @Test("an unknown total is omitted from the progress line")
    func progressLineWithoutTotal() {
        let (emitter, captured, _) = makeEmitter()

        emitter.emit(
            ModelDownloader.DownloadEvent(
                phase: .progress, file: "model.safetensors", bytesDownloaded: 512),
            model: "org/m"
        )

        #expect(captured.lines == [
            #"{"bytes":512,"event":"progress","file":"model.safetensors","model":"org/m"}"#
        ])
    }

    @Test("verifying, done, and error lines carry the terminal schema")
    func terminalLineSchemas() {
        let (emitter, captured, _) = makeEmitter()

        emitter.emit(ModelDownloader.DownloadEvent(phase: .verifying, file: "org/m"), model: "org/m")
        emitter.done(model: "org/m")
        emitter.failure(message: "download failed: aggregate hash mismatch for org/m")

        #expect(captured.lines == [
            #"{"event":"verifying","model":"org/m"}"#,
            #"{"event":"done","model":"org/m"}"#,
            #"{"event":"error","message":"download failed: aggregate hash mismatch for org/m"}"#,
        ])
    }

    @Test("progress lines are throttled per file; first and completion lines always escape")
    func progressThrottling() {
        let (emitter, captured, clock) = makeEmitter(interval: 60)

        emitter.emit(.init(phase: .progress, file: "a.bin", bytesDownloaded: 100, bytesTotal: 1000), model: "m")
        // Immediately after: swallowed (not due, not complete).
        emitter.emit(.init(phase: .progress, file: "a.bin", bytesDownloaded: 200, bytesTotal: 1000), model: "m")
        // A DIFFERENT file is independent: its first line escapes.
        emitter.emit(.init(phase: .progress, file: "b.bin", bytesDownloaded: 50, bytesTotal: 1000), model: "m")
        // Completion always escapes the throttle.
        emitter.emit(.init(phase: .progress, file: "a.bin", bytesDownloaded: 1000, bytesTotal: 1000), model: "m")

        #expect(captured.lines.count == 3)
        #expect(captured.lines[0].contains(#""bytes":100"#))
        #expect(captured.lines[1].contains(#""file":"b.bin""#))
        #expect(captured.lines[2].contains(#""bytes":1000"#))

        // After the interval lapses, ordinary progress flows again.
        clock.advance(by: 61)
        emitter.emit(.init(phase: .progress, file: "b.bin", bytesDownloaded: 60, bytesTotal: 1000), model: "m")
        #expect(captured.lines.count == 4)
        #expect(captured.lines[3].contains(#""bytes":60"#))
    }

    @Test("--json flag parses; human output stays the default")
    func jsonFlagParsing() throws {
        let json = try Models.Download.parse(["org/m", "--json"])
        #expect(json.json)
        #expect(json.modelID == "org/m")
        #expect(json.reserveBytes == 0)

        let plain = try Models.Download.parse([
            "org/m",
            "--reserve-bytes",
            "2147483648",
        ])
        #expect(!plain.json)
        #expect(plain.reserveBytes == 2_147_483_648)

        let plan = try Models.DownloadPlan.parse([
            "org/m",
            "--json",
            "--reserve-bytes",
            "2147483648",
        ])
        #expect(plan.modelID == "org/m")
        #expect(plan.json)
        #expect(plan.reserveBytes == 2_147_483_648)
    }

    @Test("catalog download-plan flag parses only when explicitly requested")
    func catalogDownloadPlanFlagParsing() throws {
        let appCatalog = try Models.Catalog.parse([
            "--json",
            "--include-download-plans",
        ])
        #expect(appCatalog.json)
        #expect(appCatalog.includeDownloadPlans)
        #expect(!appCatalog.includeRuntimeEligibility)

        let lightweightCatalog = try Models.Catalog.parse([
            "--json", "--include-runtime-eligibility",
        ])
        #expect(lightweightCatalog.json)
        #expect(lightweightCatalog.includeRuntimeEligibility)
        #expect(!lightweightCatalog.includeDownloadPlans)

        let publicCatalog = try Models.Catalog.parse(["--json"])
        #expect(publicCatalog.json)
        #expect(!publicCatalog.includeDownloadPlans)
        #expect(!publicCatalog.includeRuntimeEligibility)
    }

    @Test("JSON downloads retain runtime capabilities and fail before I/O when ineligible")
    func jsonDownloadPreservesRuntimeCapabilities() async throws {
        let modelID = ModelRuntimeRequirements.qwen38ConcreteModelID
        let model = CatalogModel(
            id: modelID, s3Name: "gated-fixture", displayName: "Gated fixture", sizeGb: 1)
        var command = try Models.Download.parse([modelID, "--json"])
        // Deliberately stop at the next validation boundary after eligibility.
        // No case can reach a network request, cache lock, or filesystem write.
        command.reserveBytes = -1
        let cases: [Set<ProviderRuntimeCapability>] = [
            [], [.appleM5], [.mlxNAX], [.appleM5, .mlxNAX],
        ]
        for capabilities in cases {
            let (emitter, captured, _) = makeEmitter()
            do {
                try await command.runJSON(
                    entry: model,
                    downloader: ModelDownloader(runtimeCapabilities: capabilities),
                    emitter: emitter)
                Issue.record("expected a validation failure before download I/O")
            } catch let error as ExitCode {
                #expect(error == .failure)
            }
            #expect(captured.lines.count == 1)
            let line = try #require(captured.lines.first)
            let event = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
            #expect(event["event"] == "error")
            let message = try #require(event["message"])
            if capabilities == ModelRuntimeRequirements.qwen38RequiredCapabilities {
                #expect(message == "download failed: download reserve must be non-negative")
            } else {
                #expect(message.contains(ModelRuntimeIneligibleError.permanentFailureMarker))
            }
        }
    }
}
