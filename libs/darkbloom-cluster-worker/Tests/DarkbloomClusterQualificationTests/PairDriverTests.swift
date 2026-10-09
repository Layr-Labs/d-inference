import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterQualification

/// Two copies of the fake worker stand in for the two Macs. "Rank 1 remote" is
/// reached through `/bin/sh -c`, which takes a command string the way `ssh`
/// hands one to the remote login shell, so the remote launch path is the real one.
private final class Sides {
    static let coordinator = "10.77.0.1:47000"
    let root: URL
    private(set) var sides: [PairSide] = []

    init(modes: [String], skews: [Int64] = [0, 0], evidenceTokenDelta: Int = 0, evidenceDeltaRanks: [Int] = [1],
         alterWorker: Bool = false, alterMetallib: Bool = false, removeProgressGuard: Bool = false) throws {
        let files = FileManager.default
        root = files.temporaryDirectory.appendingPathComponent("pair-check-\(UUID().uuidString.lowercased())")
        let fake = try Self.fakeWorker()
        for rank in 0...1 {
            let side = root.appendingPathComponent("side\(rank)"), model = root.appendingPathComponent("model\(rank)")
            let scratch = root.appendingPathComponent("scratch\(rank)")
            for directory in [side, model, scratch] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
            let worker = side.appendingPathComponent("darkbloom-cluster-worker")
            var bytes = try Data(contentsOf: fake)
            if alterWorker && rank == 1 { bytes.append(0) }
            if removeProgressGuard {
                // The same edit on both sides: a worker built on the stock JACCL
                // does not contain the name the guard reads. Never executed.
                let marker = Data(PairConfiguration.progressGuardMarker.utf8)
                while let range = bytes.range(of: marker) { bytes[range.lowerBound] = UInt8(ascii: "X") }
            }
            try bytes.write(to: worker)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
            try Data("metallib\(alterMetallib && rank == 1 ? "!" : "")".utf8).write(to: side.appendingPathComponent("mlx.metallib"))
            let behavior: [String: Any] = ["mode": modes[rank], "clockSkewNanoseconds": skews[rank],
                                           "evidenceTokenDelta": evidenceTokenDelta, "evidenceDeltaRanks": evidenceDeltaRanks]
            try JSONSerialization.data(withJSONObject: behavior).write(to: side.appendingPathComponent("behavior.json"))
            for name in ["config.json", "manifest.json"] { try Data("{}".utf8).write(to: model.appendingPathComponent(name)) }
            sides.append(.init(modelDirectory: model.path, workerPath: worker.path,
                rdmaDevice: rank == 0 ? "rdma_en5" : "rdma_en7", scratchDirectory: scratch.path))
        }
    }

    static func fakeWorker() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["PAIR_CHECK_FAKE_WORKER"] { return URL(fileURLWithPath: path) }
        let products = Bundle(for: Sides.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("PairCheckFakeWorker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw QualificationError("PairCheckFakeWorker is not beside the test bundle")
        }
        return url
    }

    func configuration(outputCount: Int = 5, recording: Bool = true, lifetime: Int = 30, startup: Int = 10,
                       schedule: String = "serial_v1", progress: Int? = 60_000,
                       keepRunFiles: Bool = true) throws -> PairConfiguration {
        let request = try QualificationRequest(requestID: UUID(), promptTokenIDs: Array(1...40), chunkSize: 16,
            outputCount: outputCount, stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "test"))
        return try PairConfiguration(request: request, stageCut: 8, local: sides[0], remote: sides[1],
            remoteTransport: ["/bin/sh", "-c"], coordinator: Self.coordinator, prefillSchedule: schedule,
            recording: recording, lifetimeSeconds: lifetime, startupSeconds: startup, requestSeconds: 10,
            rankOneDelaySeconds: 0, progressTimeoutMilliseconds: progress, keepRunFiles: keepRunFiles,
            sensitive: ["operator@peer-mac.example"])
    }

    func runDirectory(_ configuration: PairConfiguration, _ rank: Int) -> URL {
        URL(fileURLWithPath: configuration.runDirectory(rank))
    }
    func observed(_ configuration: PairConfiguration, _ rank: Int) throws -> [String: Any] {
        let data = try Data(contentsOf: runDirectory(configuration, rank).appendingPathComponent("observed.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    /// The fake creates this file if it is ever sent SIGTERM.
    func signalled(_ configuration: PairConfiguration) -> Bool {
        (0...1).contains { FileManager.default.fileExists(atPath: runDirectory(configuration, $0).appendingPathComponent("signalled").path) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: PairReport?
    func set(_ value: PairReport) { lock.lock(); report = value; lock.unlock() }
    var value: PairReport? { lock.lock(); defer { lock.unlock() }; return report }
}

final class PairDriverTests: XCTestCase {
    private func assertEndedByItself(_ report: PairReport, _ sides: Sides, _ configuration: PairConfiguration,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(sides.signalled(configuration), "a worker received a signal", file: file, line: line)
        XCTAssertTrue(report.bothExitsObserved, file: file, line: line)
        XCTAssertEqual(report.noWorkerProcessLeft, true, file: file, line: line)
        for rank in report.ranks {
            XCTAssertNil(rank.exitSignal, "\(rank.role) ended by a signal", file: file, line: line)
            XCTAssertEqual(rank.signalsSentByDriver, 0, file: file, line: line)
            XCTAssertEqual(rank.workerProcessesLeft, 0, file: file, line: line)
        }
    }

    func testCompletedRunRelaysTokensCollectsBothRanksAndShutsDownCleanly() throws {
        // Each fake keeps its own clock, far from this process's and from each other's.
        let sides = try Sides(modes: ["ok", "ok"], skews: [-90_000_000_000, 500_000_000_000])
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "completed", report.failure ?? "")
        XCTAssertEqual(report.evidence?.selectedTokenIDs, [100, 101, 102, 103, 104])
        XCTAssertEqual(report.evidence?.finishReason, "length")
        XCTAssertEqual(report.ranksAgreeOnTokens, true)
        XCTAssertEqual(report.workerHashesIdentical, true)
        XCTAssertEqual(report.metallibHashesIdentical, true)
        XCTAssertEqual(report.ranks.map(\.role), ["rank 0 local", "rank 1 remote"])
        for rank in report.ranks {
            XCTAssertTrue(rank.launched && rank.readyObserved && rank.shutdownCommandSent && rank.shutdownCompleteObserved)
            XCTAssertTrue(rank.exitObserved); XCTAssertEqual(rank.exitStatus, 0)
            XCTAssertEqual(rank.admitted, true)
            XCTAssertTrue(rank.evidenceCollected)
            XCTAssertEqual(rank.evidenceSelectedTokenIDs, [100, 101, 102, 103, 104])
            XCTAssertEqual(rank.events.last, "shutdownComplete")
            XCTAssertEqual(rank.workerHasProgressGuard, true)
            // Wired memory of the Mac, before the launch and after the last exit.
            XCTAssertGreaterThan(rank.wiredBytesBefore ?? 0, 1 << 28); XCTAssertGreaterThan(rank.wiredBytesAfter ?? 0, 1 << 28)
        }
        XCTAssertEqual(report.ranks[0].events, ["ready", "admitted", "committedToken x5", "finished:length", "retired:clean", "shutdownComplete"])
        XCTAssertEqual(report.ranks[1].events, ["ready", "admitted", "finished:length", "retired:clean", "shutdownComplete"])
        assertEndedByItself(report, sides, configuration)
        // Rank 1's final row and both ranks' state, joined.
        XCTAssertEqual(try report.evidence?.finalLogits?.values(), [0.5, 1.5, -2.0, 9.0, 8.5, 0.0, -0.25, 3.0])
        XCTAssertEqual(report.evidence?.stateEntries?.map(\.globalLayerIndex), [0, 8])
        XCTAssertEqual(report.identity?.stageCut, 8)
        XCTAssertNotNil(report.identity?.requestFingerprint)
        XCTAssertEqual(report.timing.firstTokenSeconds.map { $0 > 0 }, true)

        // What each worker was actually started with.
        for rank in 0...1 {
            let observed = try sides.observed(configuration, rank)
            var environment = try XCTUnwrap(observed["environment"] as? [String: String])
            // CoreFoundation adds this to its own process; the launcher did not pass it.
            environment.removeValue(forKey: "__CF_USER_TEXT_ENCODING")
            XCTAssertEqual(environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
                "JACCL_RANK": String(rank), "JACCL_COORDINATOR": Sides.coordinator, "JACCL_PROGRESS_TIMEOUT_MS": "60000",
                "JACCL_IBV_DEVICES": configuration.runDirectory(rank) + "/devices.json"])
            XCTAssertEqual(observed["matrix"] as? String, "[[null,\"rdma_en5\"],[\"rdma_en7\",null]]\n")
            // An interrupted driver or a closed terminal must not take a worker down.
            XCTAssertEqual(observed["ignoresInterrupt"] as? Bool, true); XCTAssertEqual(observed["ignoresHangup"] as? Bool, true)
            XCTAssertEqual(observed["ignoresTerminate"] as? Bool, false)
            let arguments = try XCTUnwrap(observed["arguments"] as? [String])
            XCTAssertEqual(Array(arguments.prefix(6)), ["--model-dir", sides.sides[rank].modelDirectory, "--rank", String(rank), "--stage-cut", "8"])
            XCTAssertTrue(arguments.contains("--evidence-directory"))
            XCTAssertFalse(arguments.contains("--prefill-schedule"))
            let builds = ["--peer0-build-sha256", "--peer1-build-sha256"].map { arguments[arguments.firstIndex(of: $0)! + 1] }
            XCTAssertEqual(builds, [report.ranks[0].workerSHA256, report.ranks[1].workerSHA256].compactMap { $0 })
        }
        // A report names roles, never a place or a person.
        let text = String(decoding: try QualificationReportFiles.encode(report), as: UTF8.self)
        for secret in ["10.77.0.1", NSUserName(), sides.root.path, "peer-mac", "operator@"] {
            XCTAssertFalse(text.contains(secret), "report contains \(secret)")
        }
    }

    func testRunFilesAreRemovedFromBothSidesUnlessKept() throws {
        let sides = try Sides(modes: ["ok", "ok"])
        let configuration = try sides.configuration(keepRunFiles: false)
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "completed", report.failure ?? "")
        // The records were read before the directories went away.
        XCTAssertEqual(report.ranks.map(\.evidenceCollected), [true, true])
        XCTAssertEqual(report.ranks.map(\.runFilesRemoved), [true, true])
        for rank in 0...1 {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sides.sides[rank].scratchDirectory), [])
        }
        // A failed run cleans up too, after its workers have ended.
        let failing = try Sides(modes: ["ok", "exit-before-ready"])
        let failed = PairDriver(configuration: try failing.configuration(keepRunFiles: false)).run()
        XCTAssertEqual(failed.outcome, "failed")
        XCTAssertEqual(failed.ranks.map(\.runFilesRemoved), [true, true])
        for rank in 0...1 {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: failing.sides[rank].scratchDirectory), [])
        }
    }

    func testOptionalWorkerSettingsReachBothRanks() throws {
        let sides = try Sides(modes: ["ok", "ok"])
        let configuration = try sides.configuration(outputCount: 1, recording: false,
            schedule: "one_chunk_lookahead_v1", progress: 5000)
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "completed", report.failure ?? "")
        XCTAssertEqual(report.evidence?.selectedTokenIDs, [100])
        // Without recording there is no final row and no rank-1 history.
        XCTAssertNil(report.evidence?.finalLogits); XCTAssertNil(report.ranksAgreeOnTokens)
        XCTAssertEqual(report.ranks.map(\.evidenceCollected), [false, false])
        for rank in 0...1 {
            let observed = try sides.observed(configuration, rank)
            XCTAssertEqual((observed["environment"] as? [String: String])?["JACCL_PROGRESS_TIMEOUT_MS"], "5000")
            let arguments = try XCTUnwrap(observed["arguments"] as? [String])
            XCTAssertFalse(arguments.contains("--evidence-directory"))
            XCTAssertEqual(arguments.firstIndex(of: "--prefill-schedule").map { arguments[$0 + 1] }, "one_chunk_lookahead_v1")
        }
        assertEndedByItself(report, sides, configuration)
    }

    func testRefusesDifferentWorkerBinariesBeforeLaunchingAnything() throws {
        let sides = try Sides(modes: ["ok", "ok"], alterWorker: true)
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "refused")
        XCTAssertEqual(report.workerHashesIdentical, false)
        XCTAssertTrue(report.failure?.contains("worker binaries differ") == true, report.failure ?? "")
        XCTAssertNotEqual(report.ranks[0].workerSHA256, report.ranks[1].workerSHA256)
        XCTAssertEqual(report.ranks.map(\.launched), [false, false])
        // Nothing was started and nothing was written on either side.
        for rank in 0...1 {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sides.sides[rank].scratchDirectory), [])
        }
        XCTAssertEqual(report.noWorkerProcessLeft, true)
    }

    func testPreflightInspectsBothSidesAndLaunchesNothing() throws {
        let sides = try Sides(modes: ["ok", "ok"])
        var configuration = try sides.configuration()
        configuration.preflightOnly = true
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "preflight", report.failure ?? "")
        XCTAssertEqual(report.workerHashesIdentical, true); XCTAssertEqual(report.metallibHashesIdentical, true)
        XCTAssertEqual(report.identity?.stageCut, 8); XCTAssertNotNil(report.identity?.planSHA256)
        XCTAssertEqual(report.ranks.map(\.launched), [false, false])
        XCTAssertEqual(report.ranks.compactMap(\.chip).count, 2)
        XCTAssertEqual(report.noWorkerProcessLeft, true); XCTAssertNil(report.evidence)
        for rank in 0...1 {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sides.sides[rank].scratchDirectory), [])
        }
        // A preflight is not a run and cannot be compared.
        let file = sides.root.appendingPathComponent("preflight.json")
        try QualificationFiles.writeNew(QualificationReportFiles.encode(report), to: file)
        XCTAssertThrowsError(try QualificationReportFiles.subject(file))
    }

    func testRefusesAWorkerWithoutTheProgressGuardBeforeLaunchingAnything() throws {
        let sides = try Sides(modes: ["ok", "ok"], removeProgressGuard: true)
        let report = PairDriver(configuration: try sides.configuration()).run()
        XCTAssertEqual(report.outcome, "refused")
        XCTAssertTrue(report.failure?.contains("no JACCL progress guard") == true, report.failure ?? "")
        // Identical on both sides, so only the missing guard stands in the way.
        XCTAssertEqual(report.workerHashesIdentical, true)
        XCTAssertEqual(report.ranks.map(\.workerHasProgressGuard), [false, false])
        XCTAssertEqual(report.ranks.map(\.launched), [false, false])
        for rank in 0...1 {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sides.sides[rank].scratchDirectory), [])
        }
    }

    func testRefusesDifferentMetalLibraries() throws {
        let sides = try Sides(modes: ["ok", "ok"], alterMetallib: true)
        let report = PairDriver(configuration: try sides.configuration()).run()
        XCTAssertEqual(report.outcome, "refused")
        XCTAssertEqual(report.workerHashesIdentical, true); XCTAssertEqual(report.metallibHashesIdentical, false)
        XCTAssertEqual(report.ranks.map(\.launched), [false, false])
    }

    func testRefusesWhileAWorkerFromThisPathIsStillRunningAndCountsIt() throws {
        // A first run whose rank 1 stays alive until its 10-second lifetime ends.
        let sides = try Sides(modes: ["ok", "never-ready"])
        let first = try sides.configuration(lifetime: 10, startup: 3)
        let ended = expectation(description: "first run ended")
        let firstReport = ReportBox()
        DispatchQueue.global().async { firstReport.set(PairDriver(configuration: first).run()); ended.fulfill() }
        let launched = sides.runDirectory(first, 1).appendingPathComponent("observed.json").path
        let limit = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: launched), Date() < limit { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: launched))

        let second = try sides.configuration()
        let report = PairDriver(configuration: second).run()
        XCTAssertEqual(report.outcome, "refused")
        XCTAssertTrue(report.failure?.contains("already running") == true, report.failure ?? "")
        XCTAssertEqual(report.ranks.map(\.launched), [false, false])
        // The count at the end of the refused run still sees the first run's worker.
        XCTAssertEqual(report.ranks[1].workerProcessesLeft, 1)
        XCTAssertEqual(report.noWorkerProcessLeft, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sides.runDirectory(second, 0).path))

        wait(for: [ended], timeout: 60)
        XCTAssertEqual(firstReport.value?.ranks[1].exitStatus, 124)
        XCTAssertEqual(firstReport.value?.noWorkerProcessLeft, true)
        XCTAssertFalse(sides.signalled(first))
    }

    func testWorkerThatExitsBeforeReadyFailsTheRunAndThePeerEndsByItself() throws {
        let sides = try Sides(modes: ["ok", "exit-before-ready"])
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertTrue(report.failure?.contains("rank 1 remote exited before the pair was ready (status 7)") == true, report.failure ?? "")
        XCTAssertEqual(report.ranks[1].exitStatus, 7); XCTAssertFalse(report.ranks[1].readyObserved)
        // Rank 0 lost its input, released and exited; it was not shut down cleanly.
        XCTAssertEqual(report.ranks[0].exitStatus, 1); XCTAssertFalse(report.ranks[0].shutdownCommandSent)
        XCTAssertNil(report.evidence)
        assertEndedByItself(report, sides, configuration)
    }

    func testWorkerThatNeverBecomesReadyIsLeftToItsOwnLifetime() throws {
        let sides = try Sides(modes: ["ok", "never-ready"])
        let configuration = try sides.configuration(lifetime: 10, startup: 3)
        let started = Date()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertTrue(report.failure?.contains("not ready within 3 s: rank 1 remote") == true, report.failure ?? "")
        // It ignored its input and ended at the lifetime it was launched with.
        XCTAssertEqual(report.ranks[1].exitStatus, 124)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(report.ranks[0].exitStatus, 1)
        assertEndedByItself(report, sides, configuration)
    }

    func testRefusedReservationStartsNothingAndBothWorkersEnd() throws {
        let sides = try Sides(modes: ["ok", "refuse"])
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "refused")
        XCTAssertTrue(report.failure?.contains("rank 1 remote refused the reservation (capacity)") == true, report.failure ?? "")
        XCTAssertEqual(report.ranks[0].admitted, true); XCTAssertEqual(report.ranks[1].admitted, false)
        XCTAssertEqual(report.ranks[1].refusal, "capacity")
        // The admitted rank was cancelled; neither saw a start, so no token exists.
        XCTAssertFalse(report.ranks[0].events.contains { $0.hasPrefix("committedToken") })
        XCTAssertNil(report.evidence)
        assertEndedByItself(report, sides, configuration)
    }

    func testWorkerThatExitsDuringTheRequestCancelsThePeer() throws {
        let sides = try Sides(modes: ["exit-on-start", "stall-on-start"])
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertEqual(report.ranks[0].exitStatus, 9)
        // Rank 1 was waiting on its peer: it was cancelled, said so and exited.
        XCTAssertEqual(report.ranks[1].events.last, "failed:runtimeError")
        XCTAssertEqual(report.ranks[1].exitStatus, 1)
        XCTAssertNil(report.evidence)
        assertEndedByItself(report, sides, configuration)
    }

    func testRanksThatRecordDifferentHistoriesFailTheRun() throws {
        let sides = try Sides(modes: ["ok", "ok"], evidenceTokenDelta: 1)
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertTrue(report.failure?.contains("different histories") == true, report.failure ?? "")
        XCTAssertEqual(report.ranksAgreeOnTokens, false)
        XCTAssertEqual(report.ranks[0].evidenceSelectedTokenIDs, [100, 101, 102, 103, 104])
        XCTAssertEqual(report.ranks[1].evidenceSelectedTokenIDs, [100, 101, 102, 103, 105])
        XCTAssertNil(report.evidence)
        assertEndedByItself(report, sides, configuration)
    }

    func testRecordedHistoryThatDiffersFromTheRelayedTokensFailsTheRun() throws {
        // Both ranks agree with each other, but not with what rank 0 published.
        let sides = try Sides(modes: ["ok", "ok"], evidenceTokenDelta: 1, evidenceDeltaRanks: [0, 1])
        let configuration = try sides.configuration()
        let report = PairDriver(configuration: configuration).run()
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertTrue(report.failure?.contains("differs from the run the driver observed") == true, report.failure ?? "")
        XCTAssertEqual(report.ranksAgreeOnTokens, false)
        XCTAssertEqual(report.ranks.map(\.evidenceSelectedTokenIDs), [[100, 101, 102, 103, 105], [100, 101, 102, 103, 105]])
        XCTAssertNil(report.evidence)
        assertEndedByItself(report, sides, configuration)
    }

    func testConfigurationRefusesUnsafeOrUnsupportedInputs() throws {
        let sides = try Sides(modes: ["ok", "ok"])
        let valid = try sides.configuration()
        func changed(_ edit: (inout PairConfiguration) -> Void) -> PairConfiguration { var copy = valid; edit(&copy); return copy }
        XCTAssertNoThrow(try valid.validate())
        let invalid: [(String, PairConfiguration)] = [
            ("cut", changed { $0.stageCut = 6 }),
            ("relative worker", changed { $0.local.workerPath = "worker" }),
            ("quote in path", changed { $0.remote.workerPath = "/tmp/a'b" }),
            ("space in path", changed { $0.remote.modelDirectory = "/tmp/a b" }),
            ("command substitution", changed { $0.remote.scratchDirectory = "/tmp/$(id)" }),
            ("parent component", changed { $0.local.modelDirectory = "/tmp/../etc" }),
            ("device with separator", changed { $0.local.rdmaDevice = "rdma_en5;id" }),
            ("empty device", changed { $0.remote.rdmaDevice = "" }),
            ("host name coordinator", changed { $0.coordinator = "peer.local:47000" }),
            ("coordinator without port", changed { $0.coordinator = "10.0.0.1" }),
            ("multicast coordinator", changed { $0.coordinator = "224.0.0.1:47000" }),
            ("padded port", changed { $0.coordinator = "10.0.0.1:047000" }),
            ("lifetime", changed { $0.lifetimeSeconds = 301 }),
            ("startup beyond lifetime", changed { $0.startupSeconds = 31 }),
            ("schedule", changed { $0.prefillSchedule = "eager" }),
            ("progress timeout", changed { $0.progressTimeoutMilliseconds = 10 }),
            ("guard required without a timeout", changed { $0.progressTimeoutMilliseconds = nil }),
            ("relative transport", changed { $0.remoteTransport = ["ssh", "peer"] }),
            ("empty transport", changed { $0.remoteTransport = [] }),
        ]
        for (name, configuration) in invalid {
            XCTAssertThrowsError(try configuration.validate(), name)
        }
    }

    func testSSHTransportIsNonInteractiveAndRefusesShellCharacters() throws {
        let transport = try PairConfiguration.sshTransport(destination: "operator@peer-mac",
            options: ["Port=2222", "IdentityFile=/Users/operator/.ssh/id_ed25519"])
        XCTAssertEqual(Array(transport.prefix(2)), ["/usr/bin/ssh", "-T"])
        XCTAssertEqual(Array(transport.suffix(2)), ["--", "operator@peer-mac"])
        // The caller's options precede the fixed ones, so they take effect.
        XCTAssertEqual(Array(transport[2...5]), ["-o", "Port=2222", "-o", "IdentityFile=/Users/operator/.ssh/id_ed25519"])
        for option in ["BatchMode=yes", "ServerAliveInterval=5", "ConnectTimeout=10", "ForwardAgent=no"] {
            XCTAssertTrue(transport.contains(option))
        }
        for destination in ["-oProxyCommand=id", "peer mac", "a@b@c", "peer;id", "", "user@"] {
            XCTAssertThrowsError(try PairConfiguration.sshTransport(destination: destination, options: []), destination)
        }
        for option in ["ProxyCommand=sh -c id", "LocalCommand=`id`", "NoValue", "=x", "Key=a;b"] {
            XCTAssertThrowsError(try PairConfiguration.sshTransport(destination: "peer", options: [option]), option)
        }
    }

    func testRedactionRemovesNamesAddressesAndHomeDirectories() {
        let redact = PairRedactor(sensitive: ["operator@peer-mac.example", "10.77.0.1:47000"])
        let text = redact("ssh: connect to host peer-mac.example port 22: operator@10.77.0.2 refused; "
            + "/Users/someone/models and fe80::1c2b:3aff:fe4d:5e6f for \(NSUserName())")
        for secret in ["peer-mac", "operator", "10.77.0.2", "/Users/someone", "fe80", NSUserName()] {
            XCTAssertFalse(text.contains(secret), "\(secret) survived in: \(text)")
        }
        XCTAssertTrue(text.contains("connect to host"))
    }

    func testLaunchLineParsing() {
        let line = PairLaunchPreamble(line: "darkbloom-pair-launch-v1 pid=4242 uptime=1000 deadline=5000")
        XCTAssertEqual(line?.processID, 4242); XCTAssertEqual(line?.uptimeNanoseconds, 1000)
        XCTAssertEqual(line?.deadlineUptimeNanoseconds, 5000)
        for bad in ["darkbloom-pair-launch-v1 pid=1 uptime=1 deadline=2", "other pid=4 uptime=1 deadline=2",
                    "darkbloom-pair-launch-v1 pid=4 uptime=9 deadline=2", "darkbloom-pair-launch-v1 pid=4 uptime=1"] {
            XCTAssertNil(PairLaunchPreamble(line: bad), bad)
        }
    }
}
