import Foundation
import Darwin
import Testing
@testable import ProviderCore

@Suite("Provider termination signals")
struct ProviderSignalTests {
    @Test func sigtermRunsAsyncDrainInARealProcess() async {
        await #expect(processExitsWith: .success) {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let handler = ProviderSignalHandler {
                // Accepted work can finish asynchronously after real SIGTERM;
                // the process does not exit at the signal boundary.
                try? await Task.sleep(nanoseconds: 100_000_000)
                try? Data("drained".utf8).write(to: marker)
            }
            _ = kill(getpid(), SIGTERM)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            withExtendedLifetime(handler) {}
            let success = (try? Data(contentsOf: marker)) == Data("drained".utf8)
            try? FileManager.default.removeItem(at: marker)
            exit(success ? 0 : 1)
        }
    }
}
