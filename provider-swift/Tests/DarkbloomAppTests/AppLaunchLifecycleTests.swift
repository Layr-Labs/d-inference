import Foundation
import Testing
@testable import DarkbloomApp

@Suite("App launch lifecycle")
@MainActor
struct AppLaunchLifecycleTests {
    @Test("Install state is ready before application lifecycle callbacks")
    func readyStateIsResolvedDuringDelegateInitialization() {
        var coordinateCalls = 0

        let delegate = DarkbloomAppDelegate(
            destinationURL: URL(fileURLWithPath: "/tmp/Darkbloom.app"),
            coordinate: {
                coordinateCalls += 1
                return .continueLaunch
            }
        )

        #expect(coordinateCalls == 1)
        #expect(delegate.installState.isReady)
        #expect(delegate.installState.isInteractive)
    }

    @Test("Relocation is resolved before the source app receives lifecycle callbacks")
    func relocationStateIsResolvedDuringDelegateInitialization() {
        let destination = URL(fileURLWithPath: "/tmp/Darkbloom.app")

        let delegate = DarkbloomAppDelegate(
            destinationURL: destination,
            coordinate: {
                .relocated(to: destination, preservedForeignApp: nil)
            }
        )

        guard case .handingOff = delegate.installState else {
            Issue.record("expected the source app to be ready for handoff")
            return
        }
        #expect(!delegate.installState.isInteractive)
    }

    @Test("Installation failure is available to the first scene render")
    func failureStateIsResolvedDuringDelegateInitialization() {
        let destination = URL(fileURLWithPath: "/tmp/Darkbloom.app")

        let delegate = DarkbloomAppDelegate(
            destinationURL: destination,
            coordinate: {
                throw StubInstallError.failed
            }
        )

        guard case .failed(let failure) = delegate.installState else {
            Issue.record("expected an installation failure")
            return
        }
        #expect(failure.destination == destination)
        #expect(delegate.installState.isInteractive)
    }
}

private enum StubInstallError: Error {
    case failed
}
