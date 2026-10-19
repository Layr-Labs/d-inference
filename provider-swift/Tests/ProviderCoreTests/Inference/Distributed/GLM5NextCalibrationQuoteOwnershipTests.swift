import Darwin
import Foundation
import Testing
import DarkbloomClusterProcess
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

@Suite(.serialized) struct GLM5NextCalibrationQuoteOwnershipTests {
    final class Fixture {
        let root: URL
        let device: URL
        let epoch = UUID()
        let leaseID = UUID(), incarnation = UUID(), launchID = UUID()
        let child = Process(), exit = ClusterProcessExit(), input = Pipe()
        var launched = false
        var quotes: [GLM5NextCalibrationQuoteProcess] = []

        init() throws {
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            try #require(realpath(NSTemporaryDirectory(), &path) != nil)
            let temporary = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            root = URL(fileURLWithPath: temporary).appendingPathComponent(UUID().uuidString, isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            device = home.appendingPathComponent(".darkbloom/cluster-device", isDirectory: true)
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", "import sys; sys.stdin.buffer.read()", "--membership-epoch",
                epoch.uuidString.lowercased()]
            child.environment = [:]
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
        }

        var journal: URL { device.appendingPathComponent("native-device.lease") }
        func bytes() throws -> Data { try Data(contentsOf: journal) }
        func record(_ owner: ClusterDeviceLease, clusterID: String = "cpu-quote",
                    peerID: String = "cpu-member", rank: Int = 0) throws {
            try owner.record(clusterID: clusterID, peerID: peerID, rank: rank,
                membershipEpoch: epoch, leaseID: leaseID, ownerIncarnation: incarnation,
                nativeLaunchID: launchID)
        }
        func launch() throws {
            try exit.run(child); launched = true
            try input.fileHandleForReading.close()
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if ClusterProcessTable.arguments(of: child.processIdentifier)?.contains(epoch.uuidString.lowercased()) == true {
                    return
                }
                usleep(5000)
            }
            throw GLM5NextCalibrationDocument.invalid("CPU child epoch was not visible")
        }
        func finish() throws {
            try input.fileHandleForWriting.close()
            try #require(exit.wait(untilUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
            #expect(child.terminationReason == .exit)
            #expect(child.terminationStatus == 0)
        }
        func cleanup() {
            try? input.fileHandleForWriting.close()
            var settled = true
            if launched {
                settled = exit.wait(untilUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
                if !settled && child.isRunning {
                    child.terminate()
                    settled = exit.wait(untilUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
                }
                #expect(settled, "CPU child must be observed exited before removing its fixture")
            }
            for quote in quotes {
                quote.cancel()
                let observed = quote.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 4_000_000_000)
                #expect(observed, "Quotation CPU child must be observed exited")
                settled = settled && observed
            }
            try? input.fileHandleForReading.close()
            if settled { try? FileManager.default.removeItem(at: root) }
        }
    }

    @Test func droppedOwnerLeavesRecoverableJournalUntilActualEpochChildExits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var owner: ClusterDeviceLease? = try ClusterDeviceLease(directoryURL: f.device)
        try f.record(try #require(owner))
        let recorded = try f.bytes()
        #expect(!recorded.isEmpty)
        #expect(try ClusterDeviceLeaseRecovery.recover(directoryURL: f.device) == .refusedLiveOwner)
        try f.launch()
        owner = nil

        #expect(try f.bytes() == recorded)
        #expect(throws: (any Error).self) { _ = try ClusterDeviceLease(directoryURL: f.device) }
        let outcome = try ClusterDeviceLeaseRecovery.recover(directoryURL: f.device)
        guard case .refusedLiveWorker(let pid, let record) = outcome else {
            Issue.record("Recovery must refuse the actual live CPU child"); return
        }
        #expect(pid == f.child.processIdentifier)
        #expect(record.clusterID == "cpu-quote")
        #expect(record.peerID == "cpu-member")
        #expect(record.rank == 0)
        #expect(record.membershipEpoch == f.epoch.uuidString.lowercased())
        #expect(record.leaseID == f.leaseID.uuidString.lowercased())
        #expect(record.ownerIncarnation == f.incarnation.uuidString.lowercased())
        #expect(record.nativeLaunchID == f.launchID.uuidString.lowercased())
        #expect(try f.bytes() == recorded)

        try f.finish()
        #expect(try ClusterDeviceLeaseRecovery.recover(directoryURL: f.device) == .cleared(record))
        #expect(try f.bytes().isEmpty)
        let fresh = try ClusterDeviceLease(directoryURL: f.device)
        withExtendedLifetime(fresh) {
            #expect(throws: (any Error).self) { _ = try ClusterDeviceLease(directoryURL: f.device) }
        }
    }

    @Test func actualSpawnFailureCanResolveRecordedNoChildOwnership() throws {
        let f = try Fixture(); defer { f.cleanup() }
        do {
            let owner = try ClusterDeviceLease(directoryURL: f.device)
            let quote = try GLM5NextCalibrationQuoteProcess(launch: .init(
                executable: f.root.appendingPathComponent("missing-worker"),
                arguments: ["--membership-epoch", f.epoch.uuidString.lowercased()],
                environment: [:], initialInput: Data("credential-fixture\n".utf8)),
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000, preflight: {})
            try f.record(owner)
            #expect(throws: (any Error).self) { try quote.start() }
            #expect(!quote.observedExit)
            #expect(throws: (any Error).self) { try quote.response() }
            #expect(try !f.bytes().isEmpty)
            try owner.resolve()
            #expect(try f.bytes().isEmpty)
        }
        #expect(try ClusterDeviceLeaseRecovery.inspect(directoryURL: f.device) == .absentOrEmpty)
        _ = try ClusterDeviceLease(directoryURL: f.device)
    }

    @Test func observedFailedExitAllowsJournalResolution() throws {
        let f = try Fixture(); defer { f.cleanup() }
        do {
            let owner = try ClusterDeviceLease(directoryURL: f.device)
            let quote = try GLM5NextCalibrationQuoteProcess(launch: .init(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import sys; sys.stdin.buffer.read(); sys.exit(7)",
                    "--membership-epoch", f.epoch.uuidString.lowercased()],
                environment: [:], initialInput: Data("credential-fixture\n".utf8)),
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000, preflight: {})
            try f.record(owner)
            try quote.start(); f.quotes.append(quote)
            try #require(quote.waitUntilExited(deadline: quote.deadline + 2_000_000_000))
            #expect(quote.observedExit)
            #expect(throws: (any Error).self) { try quote.response() }
            #expect(try !f.bytes().isEmpty)
            try owner.resolve()
            #expect(try f.bytes().isEmpty)
        }
        _ = try ClusterDeviceLease(directoryURL: f.device)
    }

    @Test func invalidTypedRecordsDoNotWriteOrConsumeTheJournal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let owner = try ClusterDeviceLease(directoryURL: f.device)
        let invalid: [(String, String, Int)] = [
            ("", "peer", 0), (String(repeating: "c", count: 129), "peer", 0),
            ("bad cluster", "peer", 0), ("cluster\n", "peer", 0),
            ("cluster", "", 0), ("cluster", String(repeating: "p", count: 129), 0),
            ("cluster", "peer\0", 0), ("cluster", "peer\u{7f}", 0),
            ("cluster", "peer", -1), ("cluster", "peer", 2)
        ]
        for (cluster, peer, rank) in invalid {
            #expect(throws: (any Error).self) { try f.record(owner, clusterID: cluster, peerID: peer, rank: rank) }
            #expect(try f.bytes().isEmpty)
        }
        try f.record(owner)
        #expect(try !f.bytes().isEmpty)
        try owner.resolve()
    }

    @Test(arguments: ["Mac Studio", "東京", "Studio 🧪"])
    func existingBoundedPeerIdentifierSyntaxRemainsValid(peerID: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let owner = try ClusterDeviceLease(directoryURL: f.device)
        try f.record(owner, peerID: peerID)
        try owner.resolve()
        #expect(try f.bytes().isEmpty)
    }
}
