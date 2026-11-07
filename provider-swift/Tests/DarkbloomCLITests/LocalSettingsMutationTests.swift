import ArgumentParser
import Foundation
import ProviderCore
import Testing
import TOMLKit

@testable import darkbloom

/// `setLocalSettings` is the CLI's writer of `[local]`, shaped like `setIdleUnloadMinutes`: the config path the other
/// commands use, a no-op when the file already says it, and a plain refusal before anything is written.
@Suite("[local] writer")
struct LocalSettingsMutationTests {
    private func makeTempConfig(_ toml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("writes [local] at the given path, keeps other and unknown keys, and repeats as a no-op")
    func writesAndRepeats() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "local-test"

            [backend]
            idle_timeout_mins = 45
            future_backend_key = "kept"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try setLocalSettings(configPath: url.path) {
            $0.mode = .both
            $0.meFirstIdleMinutes = 5
        }
        #expect(first.changed)
        #expect(first.path == url)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(tomlKeyPresent(written, section: "local", key: "mode"))
        #expect(try TOMLTable(string: written)["backend"]?.table?["future_backend_key"]?.string == "kept")
        let config = try ConfigManager.load(from: url)
        #expect(config.local == LocalSettings(mode: .both, meFirstIdleMinutes: 5))
        #expect(config.backend.idleTimeoutMins == 45)

        let second = try setLocalSettings(configPath: url.path) { $0.mode = .both }
        #expect(second.changed == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == written)
    }

    @Test("an invalid value is a plain validation error and leaves the file as it was")
    func refusal() throws {
        let url = try makeTempConfig("[local]\nmode = \"local\"\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        do {
            try setLocalSettings(configPath: url.path) { $0.meFirstIdleMinutes = 0 }
            Issue.record("me_first_idle_minutes = 0 must be refused")
        } catch let error as ValidationError {
            #expect(error.message
                == "[local] me_first_idle_minutes must be a whole number of minutes from 1 to 120, not 0.")
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
