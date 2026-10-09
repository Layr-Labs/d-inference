import Foundation
import Testing

@testable import ProviderCore

/// Pure parts of `LaunchAgent` that need no launchd: the paths it computes,
/// the errors it reports, and the plist allowance rewrite on a temp file.
/// Nothing here calls launchctl or writes under the home folder.
@Suite("LaunchAgent paths and errors")
struct LaunchAgentPathsAndErrorsTests {

    @Test("SSD capacity and endurance overrides reach the launchd provider")
    func cacheBudgetsAreForwarded() {
        let environment = [
            "DARKBLOOM_PREFIX_CACHE_DISK_GB": "50",
            "DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "25",
        ]
        let forwarded = LaunchAgent.passthroughEnvironment(from: environment)
        for (key, value) in environment { #expect(forwarded[key] == value) }
        #expect(LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "0",
        ])["DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY"] == "0")
    }

    @Test("lossless compression opt-in survives provider plist serialization and restart refresh")
    func compressionOptInSurvivesServicePlist() throws {
        let key = SSDPrefixCachePolicy.compressionEnvironmentFlag
        let arguments = LaunchAgent.serviceProgramArguments(binaryPath: "/test/darkbloom",
            coordinatorURL: "https://coordinator.invalid", models: ["gpt-oss-20b"], configPath: nil)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-agent-compression-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: path) }
        let settings: [String?] = [nil, "", "off", "lz4"]
        for input in settings {
            var environment = ["UNRELATED_SECRET": "excluded"]
            environment[key] = input
            let plist = LaunchAgent.makeServicePlist(label: "io.darkbloom.provider.test",
                programArguments: arguments, logPath: "/test/provider.log", environment: environment)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path)
            try LaunchAgent.refreshTerminationAllowance(at: path)
            let restored = try #require(PropertyListSerialization.propertyList(
                from: Data(contentsOf: path), format: nil) as? [String: Any])
            let variables = restored["EnvironmentVariables"] as? [String: String] ?? [:]
            let expected = input?.isEmpty == false ? input : nil
            #expect(variables[key] == expected)
            #expect(variables["UNRELATED_SECRET"] == nil)
            #expect(restored["ProgramArguments"] as? [String] == arguments)
            for model in ["gemma-4-26b-qat-4bit", "gpt-oss-20b"] {
                #expect(SSDPrefixCachePolicy.losslessCompressionEnabled(modelId: model,
                    environment: variables) == (input == "lz4"))
            }
            #expect(!SSDPrefixCachePolicy.losslessCompressionEnabled(modelId: "mimo-v2.6-flash",
                environment: variables))
        }
    }

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
        } catch LaunchAgentError.bootstrapFailed(let detail) {
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
