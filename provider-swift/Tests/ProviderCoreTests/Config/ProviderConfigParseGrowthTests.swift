import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// Round 6c, case 5 and the f17 runs: both Macs' cluster services grew about 1 MiB a minute; a heap of one after 26
/// minutes held 39,504 `toml::v3::table` and 39,369 `toml::v3::value<std::string>`, about 25 a second. The service's
/// member sync reads the saved cache settings from `provider.toml` every tick (`ConfigManager.parseValidating`), and
/// TOMLKit never frees the C++ table a parse builds (`TOMLTable` has no deinit). Parsing the same text again keeps the
/// bytes in use flat; a changed file still parses to its own values. A string in memory only: no file, no service.
@Suite(.serialized) struct ProviderConfigParseGrowthTests {
    static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    static func text(name: String) -> String {
        var config = ConfigManager.parse("[provider]\nname = \"\(name)\"\n")
        config.provider.name = name
        return ConfigManager.serialize(config)
    }

    @Test func parsingTheSameProviderConfigurationAgainKeepsBytesFlat() throws {
        let text = Self.text(name: "growth-fixture")
        _ = try ConfigManager.parseValidating(text)
        let parses = 3_000
        let before = Self.bytesInUse()
        for _ in 0..<parses { _ = try ConfigManager.parseValidating(text) }
        let grown = Self.bytesInUse() - before
        // Before the fix: every parse left its whole TOML tree behind (several KB for this text).
        #expect(grown < 1024 * 1024, "\(grown / 1024) KiB still in use after \(parses) parses of one provider.toml (\(grown / parses) bytes a parse)")
    }

    @Test func aChangedProviderConfigurationParsesToItsOwnValues() throws {
        let first = Self.text(name: "first-name"), second = Self.text(name: "second-name")
        #expect(try ConfigManager.parseValidating(first).provider.name == "first-name")
        #expect(try ConfigManager.parseValidating(second).provider.name == "second-name")
        #expect(try ConfigManager.parseValidating(first).provider.name == "first-name")
        #expect(ConfigManager.parse(second).provider.name == "second-name")
        #expect(throws: (any Error).self) { try ConfigManager.parseValidating("[provider\nname = 1") }
    }
}
