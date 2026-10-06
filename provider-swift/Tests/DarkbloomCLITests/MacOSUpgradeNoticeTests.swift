import Foundation
import Testing
@testable import darkbloom

private final class UpgradeNoticeBundleAnchor {}

@Suite struct MacOSUpgradeNoticeTests {
    @Test("warn on every supported older macOS", arguments: [14, 15, 26])
    func olderMacOSWarns(major: Int) throws {
        var messages: [String] = []
        MacOSUpgradeNotice.emit(version: .init(majorVersion: major, minorVersion: 5, patchVersion: 2)) {
            messages.append($0)
        }
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.contains("macOS \(major).5.2"))
        #expect(message.contains("Upgrade to macOS 27 or later"))
        #expect(message.contains("deactivated soon"))
        #expect(message.contains("remains supported during the transition"))
        #expect(message.contains("Keep your Darkbloom profile installed"))
    }

    @Test("no upgrade warning at or above macOS 27", arguments: [27, 28])
    func currentMacOSDoesNotWarn(major: Int) {
        MacOSUpgradeNotice.emit(version: .init(majorVersion: major, minorVersion: 0, patchVersion: 0)) { _ in
            Issue.record("Upgrade warning was printed on a supported OS")
        }
    }

    @Test("real CLI entry warns on stderr without changing command output", arguments: [
        ["--version"], ["--help"], ["models", "--help"], ["start", "--help"], ["stop", "--help"],
    ])
    func realEntryPointKeepsStdoutClean(arguments: [String]) throws {
        let bundle = Bundle(for: UpgradeNoticeBundleAnchor.self).bundleURL
        let directory = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        let process = Process()
        process.executableURL = directory.appendingPathComponent("darkbloom")
        process.arguments = arguments
        // Help/version exits before config, network or service operations.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!output.contains("Upgrade to macOS 27"))
        if let warning = MacOSUpgradeNotice.message(for: ProcessInfo.processInfo.operatingSystemVersion) {
            #expect(errors.components(separatedBy: warning).count == 2)
        } else {
            #expect(!errors.contains("Upgrade to macOS 27"))
        }
        if arguments == ["--version"] {
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == Darkbloom.configuration.version)
        } else {
            #expect(output.contains("USAGE:"))
        }
    }
}
