import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("models download --json NDJSON parsing")
struct ModelDownloadNDJSONTests {
    @Test("progress lines decode file, cumulative bytes, and optional total")
    func progressLines() {
        #expect(
            ModelDownloadNDJSON.parse(
                #"{"bytes":1048576,"event":"progress","file":"a.safetensors","model":"org/m","total":4194304}"#)
            == .progress(file: "a.safetensors", bytes: 1_048_576, total: 4_194_304))
        #expect(
            ModelDownloadNDJSON.parse(
                #"{"bytes":512,"event":"progress","file":"model.safetensors","model":"org/m"}"#)
            == .progress(file: "model.safetensors", bytes: 512, total: nil))
    }

    @Test("terminal event lines decode")
    func terminalLines() {
        #expect(ModelDownloadNDJSON.parse(#"{"event":"verifying","model":"org/m"}"#) == .verifying)
        #expect(ModelDownloadNDJSON.parse(#"{"event":"done","model":"org/m"}"#) == .done)
        #expect(ModelDownloadNDJSON.parse(#"{"event":"error","message":"boom"}"#) == .error("boom"))
        // An error line without a message still decodes to something honest.
        #expect(ModelDownloadNDJSON.parse(#"{"event":"error"}"#) == .error("The download failed."))
    }

    @Test("malformed, noisy, and forward-compatible lines are skipped, never fatal")
    func malformedTolerance() {
        let junk = [
            "",
            "   ",
            "not json at all",
            "  ✓ model.safetensors  64.0 MB",       // human renderer bleed
            "[1,2,3]",
            #"{"unexpected":"object"}"#,
            #"{"event":"progress"}"#,              // missing file/bytes
            #"{"event":"progress","file":"a"}"#,   // missing bytes
            #"{"event":"whathefutureholds","x":1}"#, // forward-compat
            #"{"event":"progress","file":"a","bytes":"NaN"}"#, // wrong type
            #"{"model":"org/m"}"#,                 // missing event kind
        ]
        for line in junk {
            #expect(ModelDownloadNDJSON.parse(line) == nil, "line should be nil: \(line)")
        }
    }
}

@Suite("ProcessModelCatalogCLIRunner against a stub CLI")
struct ModelCatalogCLIRunnerTests {

    // MARK: Stub CLI scripts

    private func makeStubCLI(named name: String = "stub-darkbloom", contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-catalog-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent(name)
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func runner(
        script: URL,
        stateFileURL: URL? = nil,
        physicalMemoryBytes: UInt64 = 32 * 1_073_741_824,
        now: @escaping @Sendable () -> Date = Date.init,
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = {
            ProcessIdentity(pid: $0, startTimeMicros: 100)
        }
    ) -> ProcessModelCatalogCLIRunner {
        ProcessModelCatalogCLIRunner(
            locator: SystemDarkbloomCLILocator(
                environment: [SystemDarkbloomCLILocator.environmentKey: script.path],
                bundleURL: URL(fileURLWithPath: "/tmp")
            ),
            stateFileURL: stateFileURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-state-\(UUID().uuidString).json"),
            physicalMemoryBytes: physicalMemoryBytes,
            now: now,
            processIdentityReader: processIdentityReader
        )
    }

    /// A stubs double duty: discriminates catalog vs list on $2, both exit 0.
    private let multiCommandScript = """
        #!/bin/sh
        if [ "$2" = "catalog" ]; then
            /bin/cat <<'EOF'
        [
          {
            "id" : "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "s3_name" : "mlx-community__Qwen2.5-7B-Instruct-4bit/abc",
            "display_name" : "Qwen 2.5 7B",
            "model_type" : "text",
            "size_gb" : 4.7,
            "description" : "Balanced generalist.",
            "min_ram_gb" : 16,
            "family" : "Qwen",
            "quantization" : "4-bit",
            "max_context_length" : 32768,
            "capabilities" : ["text-generation","tools"],
            "total_size_bytes" : 5000000000
          }
        ]
        EOF
            exit 0
        fi
        if [ "$2" = "list" ]; then
            /bin/cat <<'EOF'
        {
          "cacheDirectory" : "/Users/x/.cache/huggingface/hub",
          "filteredByConfig" : false,
          "models" : [
            {
              "id" : "mlx-community/Llama-3.2-3B-Instruct-4bit",
              "model_type" : "text",
              "quantization" : "4-bit",
              "size_bytes" : 2000000000,
              "estimated_memory_gb" : 2.4
            }
          ]
        }
        EOF
            exit 0
        fi
        echo "unexpected args: $@" >&2
        exit 9
        """

    @Test("fetchSnapshot merges catalog, local list, daemon warmth, and machine memory")
    func fetchSnapshotMergesSources() async throws {
        let script = try makeStubCLI(contents: multiCommandScript)

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-state-\(UUID().uuidString).json")
        DaemonStateFile.write(
            DaemonState(
                pid: 4711,
                processIdentity: ProcessIdentity(pid: 4711, startTimeMicros: 100),
                version: "0.8.0",
                writtenAt: Date().timeIntervalSince1970,
                startedAt: Date().timeIntervalSince1970 - 60,
                currentModel: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                warmModels: ["mlx-community/Llama-3.2-3B-Instruct-4bit"],
                inferenceActive: true
            ),
            to: stateURL
        )
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let snapshot = try await runner(script: script, stateFileURL: stateURL).fetchSnapshot()

        let catalog = try #require(snapshot.catalog.first)
        #expect(catalog.id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(catalog.displayName == "Qwen 2.5 7B")
        #expect(catalog.totalSizeBytes == 5_000_000_000)
        #expect(catalog.capabilities == ["text-generation", "tools"])
        #expect(catalog.minRamGb == 16)

        let local = try #require(snapshot.local.first)
        #expect(local.id == "mlx-community/Llama-3.2-3B-Instruct-4bit")
        #expect(local.sizeBytes == 2_000_000_000)

        #expect(snapshot.warmModelIDs == ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        #expect(snapshot.servingModelID == "mlx-community/Llama-3.2-3B-Instruct-4bit")
        #expect(snapshot.physicalMemoryGB == 32)
    }

    @Test("stale, identity-less, and PID-reused daemon records never keep models warm")
    func inactiveRuntimeStateIsDiscounted() async throws {
        let script = try makeStubCLI(contents: multiCommandScript)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let staleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-daemon-state-\(UUID().uuidString).json")
        DaemonStateFile.write(
            DaemonState(
                pid: 4711,
                processIdentity: ProcessIdentity(pid: 4711, startTimeMicros: 100),
                version: "0.8.0",
                writtenAt: now.timeIntervalSince1970 - 91,
                startedAt: now.timeIntervalSince1970 - 120,
                currentModel: "local-model",
                warmModels: ["local-model"],
                inferenceActive: true
            ),
            to: staleURL
        )
        defer { try? FileManager.default.removeItem(at: staleURL) }
        let stale = try await runner(
            script: script,
            stateFileURL: staleURL,
            now: { now }
        ).fetchSnapshot()
        #expect(stale.warmModelIDs.isEmpty)
        #expect(stale.servingModelID == nil)

        let deadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dead-daemon-state-\(UUID().uuidString).json")
        DaemonStateFile.write(
            DaemonState(
                pid: 4711,
                version: "0.8.0",
                writtenAt: now.timeIntervalSince1970 - 1,
                startedAt: now.timeIntervalSince1970 - 120,
                currentModel: "local-model",
                warmModels: ["local-model"],
                inferenceActive: true
            ),
            to: deadURL
        )
        defer { try? FileManager.default.removeItem(at: deadURL) }
        let dead = try await runner(
            script: script,
            stateFileURL: deadURL,
            now: { now }
        ).fetchSnapshot()
        #expect(dead.warmModelIDs.isEmpty)
        #expect(dead.servingModelID == nil)

        let recorded = ProcessIdentity(pid: 4711, startTimeMicros: 100)
        let reusedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reused-daemon-state-\(UUID().uuidString).json")
        DaemonStateFile.write(
            DaemonState(
                pid: 4711,
                processIdentity: recorded,
                version: "0.8.0",
                writtenAt: now.timeIntervalSince1970 - 1,
                startedAt: now.timeIntervalSince1970 - 120,
                currentModel: "local-model",
                warmModels: ["local-model"],
                inferenceActive: true
            ),
            to: reusedURL
        )
        defer { try? FileManager.default.removeItem(at: reusedURL) }
        let reused = try await runner(
            script: script,
            stateFileURL: reusedURL,
            now: { now },
            processIdentityReader: {
                _ in ProcessIdentity(pid: 4711, startTimeMicros: 200)
            }
        ).fetchSnapshot()
        #expect(reused.warmModelIDs.isEmpty)
        #expect(reused.servingModelID == nil)
    }

    @Test("A non-zero CLI exit surfaces the last stderr line")
    func fetchFailureSurfacesStderr() async throws {
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo "could not fetch catalog: coordinator unreachable (connection refused)" >&2
            exit 1
            """)

        do {
            _ = try await runner(script: script).fetchSnapshot()
            Issue.record("expected a non-zero exit error")
        } catch let error as ModelCatalogCLIError {
            #expect(error == .exited(1, message: "could not fetch catalog: coordinator unreachable (connection refused)"))
        }
    }

    @Test("A missing CLI throws cliNotFound before any exec attempt")
    func missingCLI() async throws {
        struct NoCLI: DarkbloomCLILocating {
            func locate() -> URL? { nil }
        }
        let runner = ProcessModelCatalogCLIRunner(locator: NoCLI(), stateFileURL: URL(fileURLWithPath: "/tmp/x"))
        await #expect(throws: ModelCatalogCLIError.self) { try await runner.fetchSnapshot() }

        // And the download stream must fail identically, not hang.
        do {
            for try await _ in runner.downloadEvents(modelID: "org/m") {
                Issue.record("no events expected without a CLI")
            }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? ModelCatalogCLIError == .cliNotFound)
        }
    }

    @Test("downloadEvents streams NDJSON lines, skipping malformed ones, then finishes at exit 0")
    func downloadStreamsEvents() async throws {
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo '{"bytes":1024,"event":"progress","file":"config.json","model":"org/m","total":2048}'
            echo 'this is not json and must be skipped'
            echo '{"event":"verifying","model":"org/m"}'
            echo '{"event":"done","model":"org/m"}'
            exit 0
            """)

        var events: [ModelDownloadStreamEvent] = []
        for try await event in runner(script: script).downloadEvents(modelID: "org/m") {
            events.append(event)
        }

        #expect(events == [
            .progress(file: "config.json", bytes: 1024, total: 2048),
            .verifying,
            .done,
        ])
    }

    @Test("A terminal error event fails the stream with the CLI's message")
    func downloadErrorEvent() async throws {
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo '{"bytes":7,"event":"progress","file":"a.bin","model":"org/m","total":99}'
            echo '{"event":"error","message":"download failed: model gone"}'
            echo '{"error":"irrelevant","note":"should never arrive"}'
            exit 1
            """)

        var events: [ModelDownloadStreamEvent] = []
        do {
            for try await event in runner(script: script).downloadEvents(modelID: "org/m") {
                events.append(event)
            }
            Issue.record("expected the stream to throw")
        } catch let error as ModelCatalogCLIError {
            #expect(error == .downloadFailed("download failed: model gone"))
        }
        #expect(events == [.progress(file: "a.bin", bytes: 7, total: 99)])
    }

    @Test("Cancelling the consumer task terminates the child and unblocks the stream")
    func downloadCancellationTerminatesChild() async throws {
        // Emits one event then keeps stdout OPEN for 30s (sleep inherits the
        // write fd): if cancel didn't terminate the child, this test hangs.
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo '{"bytes":10,"event":"progress","file":"big.bin","model":"org/m","total":100}'
            exec sleep 30
            """)

        final class ConsumedCount: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            func current() -> Int { lock.withLock { value } }
        }
        let consumed = ConsumedCount()

        let stream = runner(script: script).downloadEvents(modelID: "org/m")
        let collector = Task { () -> [ModelDownloadStreamEvent] in
            var events: [ModelDownloadStreamEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                    consumed.increment()
                }
            } catch {
                // Cancellation must surface, not the 30s sleep.
            }
            return events
        }

        // Handshake ON CONSUMPTION, not wallclock: cancelling only becomes
        // meaningful once the emitted event has actually been collected —
        // a fixed sleep races the scheduler and intermittently cancels
        // before the buffered event is consumed, dropping it.
        let handshakeDeadline = ContinuousClock.now + .seconds(10)
        while consumed.current() == 0, ContinuousClock.now < handshakeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        collector.cancel()

        // Cancel must have killed the child long before the 30s sleep ends.
        var events: [ModelDownloadStreamEvent] = []
        let elapsed = await ContinuousClock().measure {
            events = await collector.value
        }
        #expect(events == [.progress(file: "big.bin", bytes: 10, total: 100)])
        #expect(elapsed < .seconds(20))
    }

    @Test("removeModel passes --force so the CLI never blocks on its prompt")
    func removeModelForces() async throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("remove-transcript-\(UUID().uuidString).txt")
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo "$@" > \(transcript.path)
            exit 0
            """)

        try await runner(script: script).removeModel(modelID: "org/gone")
        let argv = try String(contentsOf: transcript, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(argv == "models remove org/gone --force")
        try? FileManager.default.removeItem(at: transcript)
    }
}
