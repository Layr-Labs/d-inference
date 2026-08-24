import Foundation
import Testing
@testable import DarkbloomApp

@Suite("App install lock")
struct AppInstallLockTests {
    @Test("concurrent installers never enter the destination commit together")
    func serializesConcurrentInstallers() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let probe = InstallLockProbe()
        let queue = DispatchQueue(
            label: "dev.darkbloom.app-install-lock-tests",
            attributes: .concurrent
        )

        queue.async {
            do {
                try AppInstallLock.withLock(in: root, timeout: 2) {
                    probe.enter()
                    firstEntered.signal()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                    probe.leave()
                }
            } catch {
                probe.record(error)
            }
            completed.signal()
        }

        #expect(firstEntered.wait(timeout: .now() + 2) == .success)
        queue.async {
            secondStarted.signal()
            do {
                try AppInstallLock.withLock(in: root, timeout: 2) {
                    probe.enter()
                    probe.leave()
                }
            } catch {
                probe.record(error)
            }
            completed.signal()
        }

        #expect(secondStarted.wait(timeout: .now() + 2) == .success)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(probe.maximumActive == 1)
        releaseFirst.signal()
        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(probe.maximumActive == 1)
        #expect(probe.errors.isEmpty)
    }

    @Test("dead owner lock is quarantined and recovered")
    func recoversDeadOwner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent(AppInstallLock.directoryName)
        try FileManager.default.createDirectory(at: lock)
        try Data("pid=2000000000\ntoken=dead\n".utf8)
            .write(to: lock.appendingPathComponent("owner"))

        var entered = false
        try AppInstallLock.withLock(in: root, timeout: 1) {
            entered = true
        }

        #expect(entered)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-app-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root)
        return root
    }
}

private final class InstallLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var recordedErrors: [String] = []

    var maximumActive: Int {
        lock.withLock { maximum }
    }

    var errors: [String] {
        lock.withLock { recordedErrors }
    }

    func enter() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func leave() {
        lock.withLock {
            active -= 1
        }
    }

    func record(_ error: Error) {
        lock.withLock {
            recordedErrors.append(error.localizedDescription)
        }
    }
}
