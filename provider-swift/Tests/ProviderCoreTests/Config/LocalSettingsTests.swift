import Foundation
import Testing
import TOMLKit
@testable import ProviderCore

/// `[local]` (`LocalSettings`) says how this Mac serves its owner beside, or instead of, Darkbloom. Absent, it
/// changes nothing; present, it round-trips, refuses bad values in plain words, and its writer keeps every other
/// value in the file, including keys this build does not know.
@Suite("Local-first settings ([local])")
struct LocalSettingsTests {
    private static let otherSettings = """
        [provider]
        name = "local-test"

        [backend]
        idle_timeout_mins = 37
        enabled_models = ["model-a", "model-b"]
        """

    private static let fallback = ProviderConfig(provider: ProviderSettings(name: "fallback"))

    /// The detail `parseValidating` refuses `toml` with, or nil when it decodes.
    private func refusal(_ toml: String) -> String? {
        do {
            _ = try ConfigManager.parseValidating(toml)
            return nil
        } catch ConfigError.parseFailed(let detail) {
            return detail
        } catch {
            return "unexpected error: \(error)"
        }
    }

    private func temporaryConfig(_ toml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("provider.toml")
        try toml.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Absent section

    @Test("an absent [local] keeps today's mode, port, bind and route, and other writers never add it")
    func absentSectionKeepsTodaysBehaviour() throws {
        let config = try ConfigManager.parseValidating(Self.otherSettings)
        #expect(config.local == nil)

        let local = config.local ?? LocalSettings()
        #expect(local.resolvedMode(local: false, localEndpoint: false) == .network)
        #expect(local.resolvedMode(local: true, localEndpoint: false) == .local)
        #expect(local.resolvedMode(local: false, localEndpoint: true) == .both)
        #expect(local.resolvedPort == BuildEnvironment.current.defaultLocalPort)
        #expect(local.resolvedBind == "127.0.0.1")
        #expect(local.resolvedRoute(accountKeySaved: false) == .thisMac)
        #expect(local.resolvedMeFirstIdleMinutes == 10)

        let saved = ConfigManager.serialize(config)
        #expect(try TOMLTable(string: saved)["local"] == nil)
        #expect(try ConfigManager.parseValidating(saved) == config)
    }

    @Test("me first applies only where Darkbloom and the owner share the Mac; me_first = false turns it off")
    func meFirstDefault() {
        #expect(LocalSettings().meFirstEnabled(in: .both))
        #expect(!LocalSettings().meFirstEnabled(in: .network))
        #expect(!LocalSettings().meFirstEnabled(in: .local))
        #expect(!LocalSettings(meFirst: false).meFirstEnabled(in: .both))
        #expect(LocalSettings(meFirst: true).meFirstEnabled(in: .both))
        #expect(!LocalSettings(meFirst: true).meFirstEnabled(in: .network))
    }

    @Test("a saved account key makes my-macs the default route; a saved route always wins")
    func routeDefault() {
        #expect(LocalSettings().resolvedRoute(accountKeySaved: true) == .myMacs)
        #expect(LocalSettings(route: .thisMac).resolvedRoute(accountKeySaved: true) == .thisMac)
        #expect(LocalSettings(route: .myMacsFirst).resolvedRoute(accountKeySaved: false) == .myMacsFirst)
    }

    @Test("saved values win over the launch flags and the build defaults")
    func savedValuesWin() {
        let saved = LocalSettings(mode: .local, meFirstIdleMinutes: 3, port: 8123, bind: "100.64.0.7")
        #expect(saved.resolvedMode(local: false, localEndpoint: true) == .local)
        #expect(saved.resolvedMeFirstIdleMinutes == 3)
        #expect(saved.resolvedPort == 8123)
        #expect(saved.resolvedBind == "100.64.0.7")
    }

    // MARK: - Round trip

    @Test("every key round-trips through provider.toml with the documented spelling")
    func roundTrip() throws {
        var config = try ConfigManager.parseValidating(Self.otherSettings)
        config.local = LocalSettings(mode: .both, meFirst: true, meFirstIdleMinutes: 15, route: .myMacsFirst,
                                     port: 8123, bind: "::1")
        let text = ConfigManager.serialize(config)

        let section = try #require(try TOMLTable(string: text)["local"]?.table)
        #expect(section["mode"]?.string == "both")
        #expect(section["me_first"]?.bool == true)
        #expect(section["me_first_idle_minutes"]?.int == 15)
        #expect(section["route"]?.string == "my-macs-first")
        #expect(section["port"]?.int == 8123)
        #expect(section["bind"]?.string == "::1")
        #expect(try ConfigManager.parseValidating(text) == config)
    }

    @Test("the documented example and every mode and route parse")
    func documentedValuesParse() throws {
        let config = try ConfigManager.parseValidating("""
            [local]
            mode = "both"
            me_first = true
            me_first_idle_minutes = 10
            route = "my-macs"
            port = 8000
            bind = "127.0.0.1"
            """)
        #expect(config.local == LocalSettings(mode: .both, meFirst: true, meFirstIdleMinutes: 10, route: .myMacs,
                                              port: 8000, bind: "127.0.0.1"))
        for mode in LocalSettings.Mode.allCases {
            #expect(try ConfigManager.parseValidating("[local]\nmode = \"\(mode.rawValue)\"\n").local?.mode == mode)
        }
        for route in LocalSettings.Route.allCases {
            #expect(try ConfigManager.parseValidating("[local]\nroute = \"\(route.rawValue)\"\n").local?.route == route)
        }
        #expect(try ConfigManager.parseValidating("[local]\n").local == LocalSettings())
        #expect(try ConfigManager.parseValidating("[local]\nbind = \"localhost\"\n").local?.bind == "localhost")
        #expect(try ConfigManager.parseValidating("[local]\nme_first_idle_minutes = 120\n").local?.meFirstIdleMinutes == 120)
    }

    // MARK: - Plain refusals

    private static let modeRule = #""local" (only you, on this Mac), "network" (the Darkbloom network only) or "both" (both, you first)"#
    private static let routeRule = #""this-mac" (only this Mac), "my-macs" (only your Macs) or "my-macs-first" (your Macs first, then the Darkbloom network)"#
    private static let idleRule = "a whole number of minutes from 1 to 120"
    private static let portRule = "a whole number from 1 to 65535"
    private static let bindRule = "localhost or a numeric IPv4 or IPv6 address, such as 127.0.0.1"

    @Test("an invalid value is refused with a plain message that names the key, what it takes and what it found")
    func invalidValuesRefusedPlainly() {
        let cases: [(line: String, message: String)] = [
            (#"mode = "sometimes""#, #"[local] mode must be \#(Self.modeRule), not "sometimes"."#),
            ("mode = 3", "[local] mode must be \(Self.modeRule), not 3."),
            (#"me_first = "yes""#, #"[local] me_first must be true or false, not "yes"."#),
            ("me_first = 1", "[local] me_first must be true or false, not 1."),
            ("me_first_idle_minutes = 0", "[local] me_first_idle_minutes must be \(Self.idleRule), not 0."),
            ("me_first_idle_minutes = 121", "[local] me_first_idle_minutes must be \(Self.idleRule), not 121."),
            ("me_first_idle_minutes = -5", "[local] me_first_idle_minutes must be \(Self.idleRule), not -5."),
            ("me_first_idle_minutes = 10.5", "[local] me_first_idle_minutes must be \(Self.idleRule), not 10.5."),
            (#"me_first_idle_minutes = "10""#, #"[local] me_first_idle_minutes must be \#(Self.idleRule), not "10"."#),
            (#"route = "everywhere""#, #"[local] route must be \#(Self.routeRule), not "everywhere"."#),
            ("port = 0", "[local] port must be \(Self.portRule), not 0."),
            ("port = 70000", "[local] port must be \(Self.portRule), not 70000."),
            ("port = -1", "[local] port must be \(Self.portRule), not -1."),
            (#"bind = "my laptop""#, #"[local] bind must be \#(Self.bindRule), not "my laptop"."#),
            (#"bind = """#, #"[local] bind must be \#(Self.bindRule), not ""."#),
            ("bind = [\"127.0.0.1\"]", "[local] bind must be \(Self.bindRule)."),
        ]
        for (line, message) in cases {
            #expect(refusal("[local]\n\(line)\n") == message, "\(line)")
        }
        #expect(refusal("local = 5\n")
            == #"[local] must be a section (a [local] line followed by settings such as mode = "both"), not a single value."#)
    }

    @Test("the refusal is typed, names its key, and surfaces as one plain line with no decoder internals")
    func refusalIsTyped() throws {
        do {
            _ = try TOMLDecoder().decode(ProviderConfig.self, from: "[local]\nport = 0\n")
            Issue.record("port = 0 must be refused")
        } catch let error as LocalSettingsError {
            #expect(error.key == "port")
        }
        let shown = try #require(refusal("[local]\nme_first = \"yes\"\n"))
        #expect(ConfigError.parseFailed(detail: shown).description == "failed to parse config: \(shown)")
        for decoderInternal in ["DecodingError", "codingPath", "Swift.", "Context("] {
            #expect(!shown.contains(decoderInternal))
        }
    }

    @Test("validate() refuses the same values with the same words, for settings built in code")
    func validateMatchesDecoding() {
        let cases: [(LocalSettings, String)] = [
            (LocalSettings(meFirstIdleMinutes: 0), "[local] me_first_idle_minutes must be \(Self.idleRule), not 0."),
            (LocalSettings(meFirstIdleMinutes: 121), "[local] me_first_idle_minutes must be \(Self.idleRule), not 121."),
            (LocalSettings(port: 0), "[local] port must be \(Self.portRule), not 0."),
            (LocalSettings(bind: "my laptop"), #"[local] bind must be \#(Self.bindRule), not "my laptop"."#),
        ]
        for (settings, message) in cases {
            #expect(throws: LocalSettingsError.self) { try settings.validate() }
            do {
                try settings.validate()
            } catch {
                #expect("\(error)" == message)
            }
        }
        #expect(throws: Never.self) {
            try LocalSettings(mode: .both, meFirst: false, meFirstIdleMinutes: 1, route: .myMacs, port: 65535,
                              bind: "0.0.0.0").validate()
        }
    }

    // MARK: - Write-preserving edit

    @Test("the [local] edit keeps unknown keys and every other value")
    func unknownKeysPreserved() throws {
        let original = """
            config_version = 1

            [provider]
            name = "local-test"

            [backend]
            idle_timeout_mins = 37
            enabled_models = ["model-a", "model-b"]
            future_backend_key = true

            [local]
            route = "this-mac"
            future_choice = "kept"

            [local.future_table]
            value = 1.25

            [future_extension]
            list = ["one", "two"]
            """
        let updated = try #require(try ConfigManager.updatingLocal(original, fallbackConfig: Self.fallback) {
            $0.mode = .both
            $0.meFirstIdleMinutes = 15
        })

        let before = try TOMLTable(string: original), after = try TOMLTable(string: updated)
        let section = try #require(after["local"]?.table)
        #expect(section["mode"]?.string == "both")
        #expect(section["me_first_idle_minutes"]?.int == 15)
        #expect(section["future_choice"]?.string == "kept")
        #expect(section["future_table"]?.table?["value"]?.double == 1.25)
        section.remove(at: "mode")
        section.remove(at: "me_first_idle_minutes")
        #expect(before == after)
        #expect(try ConfigManager.parseValidating(updated).local
            == LocalSettings(mode: .both, meFirstIdleMinutes: 15, route: .thisMac))
    }

    @Test("a value already in the file is a no-op; an explicit default is still written")
    func noOpAndPinning() throws {
        let original = Self.otherSettings + "\n\n[local]\nmode = \"both\"\n"
        #expect(try ConfigManager.updatingLocal(original, fallbackConfig: Self.fallback) { $0.mode = .both } == nil)

        let pinned = try #require(try ConfigManager.updatingLocal(original, fallbackConfig: Self.fallback) {
            $0.meFirstIdleMinutes = LocalSettings.defaultMeFirstIdleMinutes
        })
        #expect(try TOMLTable(string: pinned)["local"]?.table?["me_first_idle_minutes"]?.int == 10)
    }

    @Test("clearing every key removes the section, unless unknown keys remain in it")
    func clearing() throws {
        let cleared = try #require(try ConfigManager.updatingLocal(
            Self.otherSettings + "\n\n[local]\nmode = \"local\"\nport = 8123\n", fallbackConfig: Self.fallback
        ) { $0 = LocalSettings() })
        #expect(try TOMLTable(string: cleared)["local"] == nil)
        #expect(try ConfigManager.parseValidating(cleared).local == nil)

        let kept = try #require(try ConfigManager.updatingLocal(
            "[local]\nmode = \"local\"\nfuture_choice = 1\n", fallbackConfig: Self.fallback
        ) { $0.mode = nil })
        let section = try #require(try TOMLTable(string: kept)["local"]?.table)
        #expect(section["mode"] == nil)
        #expect(section["future_choice"]?.int == 1)
    }

    @Test("without a file, the caller's configuration is written with the new [local]")
    func missingFile() throws {
        let fresh = ProviderConfig(provider: ProviderSettings(name: "fresh-mac"),
                                   backend: BackendSettings(idleTimeoutMins: 45))
        let text = try #require(try ConfigManager.updatingLocal(nil, fallbackConfig: fresh) { $0.mode = .local })
        let config = try ConfigManager.parseValidating(text)
        #expect(config.provider.name == "fresh-mac")
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(config.local == LocalSettings(mode: .local))
        #expect(try ConfigManager.updatingLocal(nil, fallbackConfig: fresh) { _ in } == nil)
    }

    @Test("an invalid value is refused before anything is written")
    func refusedBeforeWriting() throws {
        let path = try temporaryConfig(Self.otherSettings)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let before = try Data(contentsOf: path)

        let changes: [(inout LocalSettings) -> Void] = [
            { $0.meFirstIdleMinutes = 0 },
            { $0.meFirstIdleMinutes = 121 },
            { $0.port = 0 },
            { $0.bind = "my laptop" },
        ]
        for change in changes {
            #expect(throws: LocalSettingsError.self) {
                try ConfigManager.updateLocal(at: path, fallbackConfig: Self.fallback, change)
            }
        }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("the file edit is owner-only and reports whether anything changed")
    func fileEdit() throws {
        let path = try temporaryConfig(Self.otherSettings)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        #expect(try ConfigManager.updateLocal(at: path, fallbackConfig: Self.fallback) { $0.mode = .both })
        let written = try Data(contentsOf: path)
        #expect(try !ConfigManager.updateLocal(at: path, fallbackConfig: Self.fallback) { $0.mode = .both })
        #expect(try Data(contentsOf: path) == written)

        let config = try ConfigManager.load(from: path)
        #expect(config.local == LocalSettings(mode: .both))
        #expect(config.backend.idleTimeoutMins == 37)
        #expect(config.backend.enabledModels == ["model-a", "model-b"])
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
