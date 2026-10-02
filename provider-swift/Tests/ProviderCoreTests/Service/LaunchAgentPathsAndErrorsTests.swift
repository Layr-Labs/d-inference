import Foundation
import Testing

@testable import ProviderCore

/// Pure parts of `LaunchAgent` that need no launchd: the paths it computes,
/// the errors it reports, and the plist allowance rewrite on a temp file.
/// Nothing here calls launchctl or writes under the home folder.
@Suite("LaunchAgent paths and errors")
struct LaunchAgentPathsAndErrorsTests {

    @Test("the plist lives in the user LaunchAgents folder under the service label")
    func plistPathShape() {
        let path = LaunchAgent.plistPath()
        #expect(path.lastPathComponent == "io.darkbloom.provider.plist")
        #expect(path.deletingLastPathComponent().lastPathComponent == "LaunchAgents")
        #expect(path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library")
        #expect(path.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("the log file is provider.log in the .darkbloom folder")
    func logPathShape() {
        let path = LaunchAgent.logPath()
        #expect(path.lastPathComponent == "provider.log")
        #expect(path.deletingLastPathComponent().lastPathComponent == ".darkbloom")
        #expect(path.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("bootstrap and bootout errors name the launchctl verb and keep the detail")
    func bootstrapAndBootoutDescriptions() {
        #expect(LaunchAgentError.bootstrapFailed("detail-a").description
            == "launchctl bootstrap failed: detail-a")
        #expect(LaunchAgentError.bootoutFailed("detail-b").description
            == "launchctl bootout failed: detail-b")
    }

    @Test("a plist whose root is not a dictionary is refused and left as it was")
    func allowanceRefusesNonDictionaryPlist() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-agent-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0)
        try original.write(to: path)

        do {
            try LaunchAgent.refreshTerminationAllowance(at: path)
            Issue.record("expected a bootstrapFailed error")
        } catch let error as LaunchAgentError {
            guard case .bootstrapFailed(let detail) = error else {
                Issue.record("expected bootstrapFailed, got \(error)")
                return
            }
            #expect(detail == "invalid provider plist")
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("a missing plist file throws and creates no file")
    func allowanceThrowsForMissingFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-agent-missing-\(UUID().uuidString).plist")
        #expect(throws: (any Error).self) {
            try LaunchAgent.refreshTerminationAllowance(at: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("bytes that are not a plist throw and stay unchanged")
    func allowanceThrowsForGarbage() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-agent-garbage-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: path) }
        let garbage = Data("this is not a property list".utf8)
        try garbage.write(to: path)

        #expect(throws: (any Error).self) {
            try LaunchAgent.refreshTerminationAllowance(at: path)
        }
        #expect(try Data(contentsOf: path) == garbage)
    }

    @Test("an existing ExitTimeOut is raised to the drain allowance")
    func allowanceOverwritesShortTimeout() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-agent-timeout-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: path) }
        let original: [String: Any] = ["Label": LaunchAgent.label, "ExitTimeOut": 20]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: path)

        try LaunchAgent.refreshTerminationAllowance(at: path)

        let updated = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
                as? [String: Any])
        #expect(updated["ExitTimeOut"] as? Int == 3660)
        #expect(updated["Label"] as? String == LaunchAgent.label)
    }
}
