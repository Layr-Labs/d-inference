import AppKit
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

        let presentation = AppInstallScenePresentation(
            installState: delegate.installState
        )
        guard case .product = presentation.mainContent else {
            Issue.record("expected product scene content")
            return
        }
        #expect(presentation.showsProductContent)
        #expect(presentation.showsProviderCommands)
        #expect(presentation.showsProductSettings)
        #expect(presentation.showsProviderMenuControls)
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

    @Test("Committed relaunch failure exposes only the managed recovery action")
    func committedRelaunchFailureUsesManagedDestination() {
        let destination = URL(
            fileURLWithPath: "/Users/test/.darkbloom/Darkbloom.app"
        )
        let source = URL(
            fileURLWithPath: "/Users/test/Downloads/Darkbloom.app"
        )

        let delegate = DarkbloomAppDelegate(
            destinationURL: destination,
            coordinate: {
                .relaunchRequired(
                    at: destination,
                    preservedForeignApp: nil
                )
            }
        )

        guard case .relaunchRequired(let recovery) = delegate.installState else {
            Issue.record("expected focused managed-install recovery")
            return
        }
        #expect(!delegate.installState.isReady)
        #expect(delegate.installState.isInteractive)
        #expect(recovery.destination == destination)
        #expect(
            recovery.managedCLIURL
                == destination.appendingPathComponent(
                    "Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
                )
        )
        #expect(
            recovery.managedCLIURL
                != source.appendingPathComponent(
                    "Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
                )
        )

        let presentation = AppInstallScenePresentation(
            installState: delegate.installState
        )
        guard case .recovery = presentation.mainContent else {
            Issue.record("expected recovery scene content")
            return
        }
        #expect(!presentation.showsProductContent)
        #expect(!presentation.showsProviderCommands)
        #expect(!presentation.showsProductSettings)
        #expect(!presentation.showsProviderMenuControls)

        let opener = RecordingInstalledApplicationOpener()
        recovery.openInstalledApp(using: opener)
        #expect(opener.openedURL == destination)
        #expect(opener.createsNewApplicationInstance)
        #expect(!opener.allowsRunningApplicationSubstitution)
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

@MainActor
private final class RecordingInstalledApplicationOpener:
    InstalledApplicationOpening
{
    private(set) var openedURL: URL?
    private(set) var createsNewApplicationInstance = false
    private(set) var allowsRunningApplicationSubstitution = true

    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) {
        openedURL = applicationURL
        createsNewApplicationInstance =
            configuration.createsNewApplicationInstance
        allowsRunningApplicationSubstitution =
            configuration.allowsRunningApplicationSubstitution
    }
}
