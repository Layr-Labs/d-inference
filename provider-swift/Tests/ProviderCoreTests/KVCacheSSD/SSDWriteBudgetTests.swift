import Darwin
import Foundation
import Testing

@testable import ProviderCore

@Suite("Persistent root-wide SSD write budget")
struct SSDWriteBudgetTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-write-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("advisory checks do not consume and reopening does not refill")
    func admissionAndReopen() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        let initial = try Data(contentsOf: root.appendingPathComponent(".write-budget"))
        for _ in 0..<3 {
            #expect(budget.admit(bytes: 100, capBytesPerDay: 100, now: 0, consume: false))
        }
        #expect(try Data(contentsOf: root.appendingPathComponent(".write-budget")) == initial)
        #expect(budget.admit(bytes: 60, capBytesPerDay: 100, now: 0, consume: true))
        let reopened = try SSDWriteBudget(root: root)
        #expect(!reopened.admit(bytes: 41, capBytesPerDay: 100, now: 0, consume: true))
        #expect(reopened.admit(bytes: 40, capBytesPerDay: 100, now: 0, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 86_399, consume: true))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [".write-budget"])
    }

    @Test("hour buckets expire conservatively and storage stays bounded")
    func expiration() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        let file = root.appendingPathComponent(".write-budget")
        let size = try Data(contentsOf: file).count
        #expect(budget.admit(bytes: 40, capBytesPerDay: 100, now: 3_599, consume: true))
        #expect(budget.admit(bytes: 60, capBytesPerDay: 100, now: 3_600, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 86_400, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 89_999, consume: true))
        #expect(budget.admit(bytes: 40, capBytesPerDay: 100, now: 90_000, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 90_000, consume: false))
        #expect(budget.admit(bytes: 60, capBytesPerDay: 100, now: 93_600, consume: true))
        #expect(budget.admit(bytes: 100, capBytesPerDay: 100, now: 1_000_000, consume: true))
        #expect(try Data(contentsOf: file).count == size)
    }

    @Test("backward clock freezes expiration and timestamps new reservations conservatively")
    func backwardClock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        #expect(budget.admit(bytes: 50, capBytesPerDay: 100, now: 90_000, consume: true))
        #expect(budget.admit(bytes: 50, capBytesPerDay: 100, now: 0, consume: true))
        let reopened = try SSDWriteBudget(root: root)
        #expect(!reopened.admit(bytes: 1, capBytesPerDay: 100, now: 86_400, consume: true))
        #expect(!reopened.admit(bytes: 1, capBytesPerDay: 100, now: 179_999, consume: true))
        #expect(reopened.admit(bytes: 100, capBytesPerDay: 100, now: 180_000, consume: true))
    }

    @Test("concurrent instances share one cap, including concurrent calls on one instance")
    func concurrentReservations() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgets = try [SSDWriteBudget(root: root), SSDWriteBudget(root: root)]
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for i in 0..<64 {
                group.addTask {
                    budgets[i % 2].admit(bytes: 1, capBytesPerDay: 8, now: 0, consume: true)
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(admitted > 0)
        #expect(admitted <= 8)
        #expect(budgets[0].admit(bytes: 8 - admitted, capBytesPerDay: 8, now: 0, consume: true))
        #expect(!budgets[1].admit(bytes: 1, capBytesPerDay: 8, now: 0, consume: true))
        #expect(!budgets[0].admit(bytes: 1, capBytesPerDay: 8, now: 0, consume: false))
    }

    @Test("an independently held flock immediately denies advisory and consuming calls")
    func lockContention() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        let fd = open(root.appendingPathComponent(".write-budget").path, O_RDWR | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        // If the implementation blocks, this test cannot reach the unlock.
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        let reopened = try SSDWriteBudget(root: root)
        #expect(!reopened.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(flock(fd, LOCK_UN) == 0)
        #expect(budget.admit(bytes: 100, capBytesPerDay: 100, now: 0, consume: true))
    }

    @Test("truncated, torn, and oversized ledgers fail closed without repair", arguments: [0, 1, 2])
    func corruptLedger(kind: Int) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        let file = root.appendingPathComponent(".write-budget")
        #expect(budget.admit(bytes: 100, capBytesPerDay: 100, now: 0, consume: true))
        var damaged = try Data(contentsOf: file)
        switch kind {
        case 0: damaged = Data()
        case 1: damaged[16] ^= 1
        default: damaged.append(0)
        }
        try damaged.write(to: file)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 1_000_000, consume: false))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 1_000_000, consume: true))
        let reopened = try SSDWriteBudget(root: root)
        #expect(!reopened.admit(bytes: 1, capBytesPerDay: 100, now: 1_000_000, consume: true))
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test("symlink and hardlink ledger targets are not read or modified", arguments: [false, true])
    func linkedLedger(hardlink: Bool) throws {
        let root = try temporaryRoot()
        let other = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let budget = try SSDWriteBudget(root: root)
        _ = try SSDWriteBudget(root: other)
        let file = root.appendingPathComponent(".write-budget")
        let target = other.appendingPathComponent(".write-budget")
        let original = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: file)
        if hardlink {
            try FileManager.default.linkItem(at: target, to: file)
        } else {
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        }
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(throws: (any Error).self) { try SSDWriteBudget(root: root) }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("symlinks in root and intermediate directories are rejected")
    func linkedRoot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let nested = actual.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        #expect(throws: (any Error).self) { try SSDWriteBudget(root: alias) }
        #expect(throws: (any Error).self) {
            try SSDWriteBudget(root: alias.appendingPathComponent("nested"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test("replacing a regular accounting directory does not reset an existing budget")
    func replacedDirectory() throws {
        let root = try temporaryRoot()
        let retired = root.appendingPathExtension("retired")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: retired)
        }
        let original = try SSDWriteBudget(root: root)
        #expect(original.admit(bytes: 100, capBytesPerDay: 100, now: 0, consume: true))
        try FileManager.default.moveItem(at: root, to: retired)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacement = try SSDWriteBudget(root: root)
        #expect(!original.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(replacement.admit(bytes: 100, capBytesPerDay: 100, now: 0, consume: true))
    }

    @Test("replacing an initialized root with a symlink does not redirect reservations")
    func replacedRoot() throws {
        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("root")
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let budget = try SSDWriteBudget(root: root)
        _ = try SSDWriteBudget(root: target)
        let file = target.appendingPathComponent(".write-budget")
        let original = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("detached"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("missing, nonregular, and unwritable state never replenish an existing budget")
    func unavailableLedger() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        let file = root.appendingPathComponent(".write-budget")
        #expect(chmod(file.path, 0) == 0)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(chmod(file.path, S_IRUSR | S_IWUSR) == 0)
        try FileManager.default.removeItem(at: file)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(mkfifo(file.path, S_IRUSR | S_IWUSR) == 0)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
        #expect(throws: (any Error).self) { try SSDWriteBudget(root: root) }
    }

    @Test("invalid inputs and cap reductions deny safely without integer overflow")
    func inputBounds() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try SSDWriteBudget(root: root)
        for now in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
            #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: now, consume: true))
        }
        #expect(!budget.admit(bytes: -1, capBytesPerDay: 100, now: 0, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 0, now: 0, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: -1, now: 0, consume: true))
        #expect(budget.admit(bytes: Int.max, capBytesPerDay: Int.max, now: 0, consume: true))
        #expect(!budget.admit(bytes: Int.max, capBytesPerDay: Int.max, now: 0, consume: true))
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
    }

    #if SSD_WRITE_BUDGET_STANDALONE
    @Test("reservations survive separate process lifetimes")
    func separateProcesses() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (bytes, expectedStatus) in [(60, Int32(0)), (40, Int32(0)), (1, Int32(1))] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--reserve", root.path, String(bytes)]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == expectedStatus)
        }
        let budget = try SSDWriteBudget(root: root)
        #expect(!budget.admit(bytes: 1, capBytesPerDay: 100, now: 0, consume: false))
    }
    #endif
}

#if SSD_WRITE_BUDGET_STANDALONE
// Compile this test file against only SSDWriteBudget.swift to avoid MLX builds.
@main
enum SSDWriteBudgetTestRunner {
    static func main() async {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--reserve" {
            let budget = try? SSDWriteBudget(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            let accepted = budget?.admit(
                bytes: Int(CommandLine.arguments[3])!, capBytesPerDay: 100, now: 0, consume: true)
            exit(accepted == true ? 0 : 1)
        }
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
#endif
