import AppKit
import Foundation
import ProviderCore

/// Hidden physical qualification mode. Deliberately bypasses Start, installed
/// authentication, APNs registration, launch agents, update and fan services.
enum NativeServeQualificationCommand {
    static let argument = "--native-serve-qualification-v1"
    @MainActor private static var retainedDelegate: Delegate?

    @MainActor static func runHosted(_ arguments: [String]) -> Never {
        guard arguments.count == 3,
              ProcessInfo.processInfo.environment[NativeServeQualification.environmentKey] == "1" else { exit(78) }
        let app = NSApplication.shared
        let delegate = Delegate(url: arguments[1], directory: arguments[2])
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(78)
    }

    @MainActor private final class Delegate: NSObject, NSApplicationDelegate {
        let url: String
        let directory: String
        var task: Task<Void, Never>?
        var signals: ProviderSignalHandler?

        init(url: String, directory: String) { self.url = url; self.directory = directory }

        func applicationDidFinishLaunching(_: Notification) {
            signals = ProviderSignalHandler { _ = await ProviderTermination.shared.request() }
            task = Task {
                do {
                    try await NativeServeQualification.run(coordinatorURL: url, directory: directory)
                    exit(0)
                } catch {
                    // Errors can contain model/template data. Keep output fixed;
                    // the coordinator's typed evidence diagnoses verification.
                    FileHandle.standardError.write(Data("native serving qualification failed\n".utf8))
                    exit(78)
                }
            }
        }
    }
}
