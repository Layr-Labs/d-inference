import Foundation
import Darwin
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

@main struct RetirementShutdownTests {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 5 else { exit(64) }
        let owner = URL(fileURLWithPath: CommandLine.arguments[1]), worker = CommandLine.arguments[2]
        let root = URL(fileURLWithPath: CommandLine.arguments[3]), mode = CommandLine.arguments[4]
        var results: [[String: Any]] = [], error: String?
        do {
            try lateShutdown(owner, worker, root, &results)
            if mode == "corrected" {
                try rejection(owner, worker, root, "active", &results)
                try rejection(owner, worker, root, "duplicate", &results)
                try rejection(owner, worker, root, "replay", &results)
                try missingRelease(owner, worker, root, &results)
            }
        } catch let failure { error = String(describing: failure) }
        let report: [String: Any] = ["schema": "owner_retirement_shutdown_cpu_v1", "mode": mode,
            "passed": error == nil, "error": error as Any? ?? NSNull(), "cases": results,
            "nativeModelNetworkExecuted": false]
        let raw = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try FileHandle.standardOutput.write(contentsOf: raw + Data([10]))
        exit(error == nil ? 0 : 1)
    }

    static func lateShutdown(_ owner: URL, _ worker: String, _ root: URL, _ results: inout [[String: Any]]) throws {
        var peers: [RetirementOwnerConnection] = []
        defer { for peer in peers { peer.close() } }
        for rank in 0..<2 {
            peers.append(try .init(owner: owner, worker: worker,
                directory: root.appendingPathComponent("late-rank\(rank)"), rank: rank, behavior: "exhausted"))
        }
        var failures: [String] = []
        for peer in peers {
            do {
                try peer.completeRequest()
                // Delay only the command transport: the worker emits the actual
                // MTP sequence finished/retired/unavailable. Service fencing and
                // actual child wait have completed before this late shutdown.
                try peer.awaitTerminal()
                try peer.command(.shutdown, requestID: nil)
                try peer.release()
                while !peer.released { _ = try peer.receive() }
                try peer.awaitOwnerExit()
            } catch { failures.append(String(describing: error)); peer.close() }
            results.append(["case": "late_shutdown_after_exhaustion", "observed": peer.summary])
        }
        try retirementRequire(failures.isEmpty && peers.allSatisfy { $0.released && $0.journalBytes == 0
            && !$0.process.isRunning && $0.process.terminationStatus == 0
            && !$0.nativeEvents.contains { $0.event == .shutdownComplete } },
            "Late shutdown lost release ACK or synthesized shutdownComplete: \(failures)")
    }

    static func rejection(_ owner: URL, _ worker: String, _ root: URL, _ kind: String,
                          _ results: inout [[String: Any]]) throws {
        let peer = try RetirementOwnerConnection(owner: owner, worker: worker,
            directory: root.appendingPathComponent(kind), rank: 0, behavior: kind == "active" ? "hang" : "exhausted")
        defer { peer.close() }
        if kind == "active" {
            try peer.reserve()
            try peer.command(.shutdown, requestID: nil) // A live reservation forbids shutdown.
        } else {
            try peer.completeRequest(); try peer.awaitTerminal()
            try peer.command(.shutdown, requestID: nil, wireOffset: kind == "replay" ? 1 : 0)
            if kind == "duplicate" { try peer.command(.shutdown, requestID: nil) }
        }
        do { while true { _ = try peer.receive() } } catch { }
        try peer.awaitOwnerExit()
        results.append(["case": kind + "_shutdown_refused", "observed": peer.summary])
        try retirementRequire(!peer.released && peer.journalBytes > 0 && peer.process.terminationStatus != 0,
            "Invalid shutdown obtained a release or cleared journal")
    }

    static func missingRelease(_ owner: URL, _ worker: String, _ root: URL,
                               _ results: inout [[String: Any]]) throws {
        let peer = try RetirementOwnerConnection(owner: owner, worker: worker,
            directory: root.appendingPathComponent("missing-release"), rank: 1, behavior: "exhausted")
        defer { peer.close() }
        try peer.completeRequest(); try peer.awaitTerminal()
        try peer.command(.shutdown, requestID: nil)
        peer.close() // EOF is not the explicit release handshake.
        try peer.awaitOwnerExit()
        results.append(["case": "missing_release_retains_journal", "observed": peer.summary])
        try retirementRequire(!peer.released && peer.journalBytes > 0, "Shutdown/EOF fabricated device release")
    }
}
