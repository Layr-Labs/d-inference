import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding provider launch cancellation", .timeLimit(.minutes(1)))
struct OnboardingProviderLaunchCancellationTests {
    @Test("An already-cancelled task never executes the CLI")
    func alreadyCancelled() async throws {
        let marker = markerURL()
        defer { try? FileManager.default.removeItem(at: marker) }
        let gate = OnboardingOperationTestGate()
        let runner = ProcessProviderCLIRunner(locator: ShellLocator())
        let task = Task {
            await gate.wait()
            return try await runner.run(arguments: markerArguments(marker), timeout: .seconds(5))
        }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Cancellation after runner entry but before process.run cannot launch a child")
    func cancelledDuringLookup() async throws {
        let marker = markerURL()
        defer { try? FileManager.default.removeItem(at: marker) }
        let entered = OnboardingOperationTestGate()
        let locator = BlockingShellLocator(entered: entered)
        defer { locator.release() }
        let runner = ProcessProviderCLIRunner(locator: locator)
        let arguments = markerArguments(marker)
        let task = Task.detached {
            try await runner.run(arguments: arguments, timeout: .seconds(5))
        }

        await entered.wait()
        // The runner's entry cancellation check already passed. Hold lookup
        // until cancellation is set, then require the launch boundary to reject.
        task.cancel()
        locator.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("The same isolated command can execute when it is not cancelled")
    func noncancelledControl() async throws {
        let marker = markerURL()
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = ProcessProviderCLIRunner(locator: ShellLocator())
        let result = try await runner.run(arguments: markerArguments(marker), timeout: .seconds(5))
        #expect(result.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private func markerURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-launch-\(UUID().uuidString)")
    }

    private func markerArguments(_ marker: URL) -> [String] {
        ["-c", ": > \"$1\"", "onboarding-launch-test", marker.path]
    }
}

private struct ShellLocator: DarkbloomCLILocating {
    func locate() -> URL? { URL(fileURLWithPath: "/bin/sh") }
}

private final class BlockingShellLocator: DarkbloomCLILocating, @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: OnboardingOperationTestGate
    private var isReleased = false

    init(entered: OnboardingOperationTestGate) { self.entered = entered }

    func locate() -> URL? {
        Task { await entered.open() }
        condition.lock()
        defer { condition.unlock() }
        while !isReleased { condition.wait() }
        return URL(fileURLWithPath: "/bin/sh")
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
