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
        includeDownloadPlans: Bool = false,
        stateFileURL: URL? = nil,
        physicalMemoryBytes: UInt64 = 32 * 1_073_741_824,
        now: @escaping @Sendable () -> Date = Date.init,
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = {
            ProcessIdentity(pid: $0, startTimeMicros: 100)
        },
        downloadAdmission: AppModelDownloadAdmissionController =
            AppModelDownloadAdmissionController()
    ) -> ProcessModelCatalogCLIRunner {
        ProcessModelCatalogCLIRunner(
            includeDownloadPlans: includeDownloadPlans,
            locator: SystemDarkbloomCLILocator(
                environment: [SystemDarkbloomCLILocator.environmentKey: script.path],
                homeDirectory: URL(fileURLWithPath: "/tmp")
            ),
            stateFileURL: stateFileURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-state-\(UUID().uuidString).json"),
            physicalMemoryBytes: physicalMemoryBytes,
            now: now,
            processIdentityReader: processIdentityReader,
            downloadAdmission: downloadAdmission
        )
    }

    /// Browsing only accepts the runtime-only catalog command and unfiltered inventory.
    private let multiCommandScript = """
        #!/bin/sh
        if [ "$2" = "catalog" ]; then
            if [ "$#" -ne 4 ] || [ "$1" != "models" ] || [ "$3" != "--json" ] || [ "$4" != "--include-runtime-eligibility" ]; then
                echo "catalog browsing must not request storage plans" >&2
                exit 9
            fi
            /bin/cat <<'EOF'
        {
          "models" : [
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
          ],
          "runtime_eligibility" : {
            "mlx-community/Qwen2.5-7B-Instruct-4bit" : {
              "status" : "eligible", "reason" : "Fixture runtime is eligible."
            }
          },
          "download_plans" : {}
        }
        EOF
            exit 0
        fi
        if [ "$2" = "list" ]; then
            if [ "$3" != "--json" ] || [ "$4" != "--all" ]; then
                echo "disk inventory requires --json --all" >&2
                exit 9
            fi
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

    private func downloadCLI(_ downloadBody: String) -> String {
        """
        #!/bin/sh
        if [ "$2" = "download-plan" ]; then
            echo '{"model_id":"org/m","download_plan":{"remaining_bytes":2048,"reserve_bytes":2147483648,"required_available_bytes":2147485696,"available_bytes":21474856960,"has_sufficient_capacity":true}}'
            exit 0
        fi
        if [ "$2" = "download" ]; then
        \(downloadBody)
        fi
        echo "unexpected args: $@" >&2
        exit 9
        """
    }

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
        #expect(snapshot.catalogError == nil)

        let catalog = try #require(snapshot.catalog.first)
        #expect(catalog.id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(catalog.displayName == "Qwen 2.5 7B")
        #expect(catalog.totalSizeBytes == 5_000_000_000)
        #expect(catalog.capabilities == ["text-generation", "tools"])
        #expect(catalog.minRamGb == 16)
        #expect(snapshot.runtimeEligibility(for: catalog.id).status == .eligible)
        #expect(snapshot.runtimeEligibility(for: catalog.id).reason == "Fixture runtime is eligible.")
        #expect(snapshot.downloadPlans.isEmpty)

        let local = try #require(snapshot.local.first)
        #expect(local.id == "mlx-community/Llama-3.2-3B-Instruct-4bit")
        #expect(local.sizeBytes == 2_000_000_000)

        #expect(snapshot.warmModelIDs == ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        #expect(snapshot.servingModelID == "mlx-community/Llama-3.2-3B-Instruct-4bit")
        #expect(snapshot.physicalMemoryGB == 32)
    }

    @Test("onboarding explicitly requests storage plans and retains storage-aware recommendations")
    func planInclusiveSnapshotSupportsOnboarding() async throws {
        let script = try makeStubCLI(contents: multiCommandScript
            .replacingOccurrences(of: "--include-runtime-eligibility", with: "--include-download-plans")
            .replacingOccurrences(of: #""download_plans" : {}"#, with: #""download_plans" : {"mlx-community/Qwen2.5-7B-Instruct-4bit":{"remaining_bytes":1000000000,"reserve_bytes":2147483648,"required_available_bytes":3147483648,"available_bytes":4000000000,"has_sufficient_capacity":true}}"#))
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let cli = runner(script: script, includeDownloadPlans: true)
        let snapshot = try await cli.fetchSnapshot()
        #expect(snapshot.catalogError == nil)
        let modelID = "mlx-community/Qwen2.5-7B-Instruct-4bit"
        let plan = try #require(snapshot.downloadPlans[modelID])
        #expect(plan.remainingBytes == 1_000_000_000)
        #expect(plan.reserveBytes == 2_147_483_648)
        #expect(plan.hasSufficientCapacity)
        let preparation = try await OnboardingPreparationService(catalog: cli).fetchPlan()
        #expect(preparation.recommendedModelID == modelID)
        #expect(preparation.choices.map(\.id) == [modelID])
        #expect(preparation.choices.first?.isInstalled == false)
    }

    @Test("runtime verdicts decode and missing or future metadata remains unknown")
    func runtimeEligibilityWireCompatibility() async throws {
        for status in ["ineligible", "unknown", "future-status"] {
            let script = try makeStubCLI(contents: multiCommandScript.replacingOccurrences(
                of: #""status" : "eligible""#, with: "\"status\" : \"\(status)\""))
            let snapshot = try await runner(script: script).fetchSnapshot()
            let model = try #require(snapshot.catalog.first)
            let expected: CLIModelRuntimeEligibility.Status = status == "ineligible" ? .ineligible : .unknown
            #expect(snapshot.runtimeEligibility(for: model.id).status == expected)
        }
        let legacy = try makeStubCLI(contents: multiCommandScript.replacingOccurrences(
            of: "runtime_eligibility", with: "future_runtime_eligibility"))
        let snapshot = try await runner(script: legacy).fetchSnapshot()
        let model = try #require(snapshot.catalog.first)
        #expect(snapshot.runtimeEligibility(for: model.id) == .unreported)
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

    @Test("Registry failure retains fresh local inventory with a typed catalog error")
    func catalogFailureRetainsLocalInventory() async throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-inventory-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeStubCLI(contents: multiCommandScript
            .replacingOccurrences(of: "#!/bin/sh", with: """
                #!/bin/sh
                echo "$@" >> "\(transcript.path)"
                """)
            .replacingOccurrences(of: #"if [ "$2" = "catalog" ]; then"#, with: """
                if [ "$2" = "catalog" ]; then
                    echo "registry unavailable" >&2
                    exit 7
                """))
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let snapshot = try await runner(script: script).fetchSnapshot()

        #expect(snapshot.catalogError == .exited(7, message: "registry unavailable"))
        #expect(snapshot.catalog.isEmpty)
        #expect(snapshot.downloadPlans.isEmpty)
        #expect(snapshot.runtimeEligibility.isEmpty)
        #expect(snapshot.local.map(\.id) == ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        #expect(snapshot.local.first?.sizeBytes == 2_000_000_000)
        #expect(snapshot.physicalMemoryGB == 32)
        let calls = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == [
            "models list --json --all",
            "models catalog --json --include-runtime-eligibility",
        ])
    }

    @Test("Malformed catalog output retains inventory but malformed inventory still throws")
    func malformedSnapshotSourcesRemainTyped() async throws {
        for phase in ["catalog", "list"] {
            let script = try makeStubCLI(contents: multiCommandScript.replacingOccurrences(
                of: "if [ \"$2\" = \"\(phase)\" ]; then", with: """
                    if [ "$2" = "\(phase)" ]; then
                        echo 'not JSON'
                        exit 0
                    """))
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

            if phase == "catalog" {
                let snapshot = try await runner(script: script).fetchSnapshot()
                #expect(snapshot.catalogError == .unreadableOutput(
                    command: "models catalog --json --include-runtime-eligibility"))
                #expect(snapshot.local.count == 1)
            } else {
                do {
                    _ = try await runner(script: script).fetchSnapshot()
                    Issue.record("Inventory decode failure must not return an offline snapshot")
                } catch let error as ModelCatalogCLIError {
                    #expect(error == .unreadableOutput(command: "models list --json --all"))
                }
            }
        }
    }

    @Test("Cancelling either inventory or catalog propagates instead of returning an offline snapshot")
    func snapshotCancellationPropagates() async throws {
        for phase in ["list", "catalog"] {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("snapshot-cancel-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let script = try makeStubCLI(contents: multiCommandScript.replacingOccurrences(
                of: "if [ \"$2\" = \"\(phase)\" ]; then", with: """
                    if [ "$2" = "\(phase)" ]; then
                        echo ready > "\(marker.path)"
                        exec /bin/sleep 30
                    """))
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            let cli = runner(script: script)
            let task = Task { try await cli.fetchSnapshot() }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancellation must not return a snapshot")
            } catch is CancellationError {
                // Expected, including when the local scan already succeeded.
            }
        }
    }

    @Test("A located CLI that cannot launch throws a typed inventory error")
    func inventoryLaunchFailureIsTyped() async throws {
        let script = try makeStubCLI(contents: "#!/nonexistent-darkbloom-test-interpreter\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        do {
            _ = try await runner(script: script).fetchSnapshot()
            Issue.record("Expected a launch failure")
        } catch let error as ModelCatalogCLIError {
            guard case .launchFailed(let command, let message) = error else {
                Issue.record("Expected typed launch failure, got \(error)")
                return
            }
            #expect(command == "models list --json --all")
            #expect(!message.isEmpty)
        }
    }

    @Test("A non-zero inventory exit surfaces the last stderr line")
    func fetchFailureSurfacesStderr() async throws {
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo "could not scan local models: permission denied" >&2
            exit 1
            """)

        do {
            _ = try await runner(script: script).fetchSnapshot()
            Issue.record("expected a non-zero exit error")
        } catch let error as ModelCatalogCLIError {
            #expect(error == .exited(1, message: "could not scan local models: permission denied"))
        }
    }

    @Test("A missing CLI throws cliNotFound before any exec attempt")
    func missingCLI() async throws {
        struct NoCLI: DarkbloomCLILocating {
            func locate() -> URL? { nil }
        }
        let runner = ProcessModelCatalogCLIRunner(locator: NoCLI(), stateFileURL: URL(fileURLWithPath: "/tmp/x"))
        await #expect(throws: ModelCatalogCLIError.self) { try await runner.fetchSnapshot() }

        await #expect(throws: ModelCatalogCLIError.self) {
            _ = try await runner.prepareDownload(modelID: "org/m")
        }
    }

    @Test("downloadEvents streams NDJSON lines, skipping malformed ones, then finishes at exit 0")
    func downloadStreamsEvents() async throws {
        let script = try makeStubCLI(contents: downloadCLI("""
            echo '{"bytes":1024,"event":"progress","file":"config.json","model":"org/m","total":2048}'
            echo 'this is not json and must be skipped'
            echo '{"event":"verifying","model":"org/m"}'
            echo '{"event":"done","model":"org/m"}'
            exit 0
            """))

        var events: [ModelDownloadStreamEvent] = []
        let preparation = try await runner(script: script).prepareDownload(modelID: "org/m")
        let stream = try preparation.start()
        for try await event in stream {
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
        let script = try makeStubCLI(contents: downloadCLI("""
            echo '{"bytes":7,"event":"progress","file":"a.bin","model":"org/m","total":99}'
            echo '{"event":"error","message":"download failed: model gone"}'
            echo '{"error":"irrelevant","note":"should never arrive"}'
            exit 1
            """))

        var events: [ModelDownloadStreamEvent] = []
        do {
            let preparation = try await runner(script: script).prepareDownload(modelID: "org/m")
            let stream = try preparation.start()
            for try await event in stream {
                events.append(event)
            }
            Issue.record("expected the stream to throw")
        } catch let error as ModelCatalogCLIError {
            #expect(error == .downloadFailed("download failed: model gone"))
        }
        #expect(events == [.progress(file: "a.bin", bytes: 7, total: 99)])
    }

    @Test("app preflight and download both pass the explicit 2 GiB reserve")
    func appDownloadArgumentsPinReserveContract() async throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-argv-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeStubCLI(contents: """
            #!/bin/sh
            echo "$@" >> "\(transcript.path)"
            if [ "$2" = "download-plan" ]; then
                echo '{"model_id":"org/m","download_plan":{"remaining_bytes":9,"reserve_bytes":2147483648,"required_available_bytes":2147483657,"available_bytes":2147483657,"has_sufficient_capacity":true}}'
                exit 0
            fi
            if [ "$2" = "download" ]; then
                echo '{"event":"done","model":"org/m"}'
                exit 0
            fi
            exit 9
            """)

        let preparation = try await runner(
            script: script,
            downloadAdmission: AppModelDownloadAdmissionController()
        ).prepareDownload(modelID: "org/m")
        let stream = try preparation.start()
        for try await _ in stream {}

        let calls = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(calls == [
            "models download-plan org/m --json --reserve-bytes 2147483648",
            "models download org/m --json --reserve-bytes 2147483648",
        ])
    }

    @Test("Cancelling the consumer task terminates the child and unblocks the stream")
    func downloadCancellationTerminatesChild() async throws {
        // Emits one event then keeps stdout OPEN for 30s (sleep inherits the
        // write fd): if cancel didn't terminate the child, this test hangs.
        let script = try makeStubCLI(contents: downloadCLI("""
            echo '{"bytes":10,"event":"progress","file":"big.bin","model":"org/m","total":100}'
            exec sleep 30
            """))

        final class ConsumedCount: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            func current() -> Int { lock.withLock { value } }
        }
        let consumed = ConsumedCount()

        let preparation = try await runner(script: script).prepareDownload(modelID: "org/m")
        let stream = try preparation.start()
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
