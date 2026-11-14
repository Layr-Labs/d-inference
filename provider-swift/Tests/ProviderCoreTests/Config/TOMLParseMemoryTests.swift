import Darwin
import Foundation
import Testing
import TOMLKit
@testable import ProviderCore

/// TOMLKit 0.6.0 never freed the C++ tree a parse builds, nor the buffers its value reads and `convert` return, so each
/// parse stayed in memory for the life of the process. A paired leader's setup deliveries make the other Mac parse its
/// `provider.toml` again (`ClusterConfigurationStore.updatingProviderData`), as every reader and writer of the file
/// does. Parsing the same text again must keep the bytes in use flat. In memory only: no file, no service.
@Suite(.serialized) struct TOMLParseMemoryTests {
    /// About 2,000 parses, in rounds: another allocation can land inside one round, but a parse that keeps its memory
    /// grows every round, so the smallest round decides.
    static let rounds = 3, callsPerRound = 700, limit = 1024 * 1024

    static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The smallest growth of the bytes in use over one round of `callsPerRound` calls of `body`.
    static func smallestGrowth(_ body: () throws -> Void) throws -> Int {
        // First calls allocate what stays for the process (caches, metadata), not per parse.
        for _ in 0..<10 { try autoreleasepool { try body() } }
        var smallest = Int.max
        for _ in 0..<rounds {
            let before = bytesInUse()
            for _ in 0..<callsPerRound { try autoreleasepool { try body() } }
            smallest = min(smallest, bytesInUse() - before)
        }
        return smallest
    }

    static func report(_ growth: Int) -> Comment {
        "\(growth / 1024) KiB still in use after \(callsPerRound) calls (\(growth / callsPerRound) bytes a call)"
    }

    /// A `provider.toml` of a few KB: a whole serialized configuration with enabled models, and a table this build
    /// does not know holding every TOML value type.
    static let providerTOML: String = {
        var config = ConfigManager.parse("[provider]\nname = \"memory-fixture\"\n")
        config.backend.enabledModels = (0..<24).map { "mlx-community/fixture-model-\($0)-4bit" }
        var text = ConfigManager.serialize(config) + """


            [future_extension]
            released = 2026-11-13T19:03:00-08:00
            day = 2026-11-13
            alarm = 04:27:05.000000294
            ratio = 50.10475
            mask = 0xEA64
            enabled = true
            notes = '''
            first
            second'''
            inline = { name = 'nested', size = 3 }

            """
        for peer in 0..<24 {
            text += """

                [[future_extension.peers]]
                name = 'peer-\(peer)'
                port = \(9000 + peer)
                seen = 2026-11-\(10 + peer % 9)T08:15:00Z
                links = ['thunderbolt-\(peer)', 'ethernet-\(peer)']

                """
        }
        return text
    }()

    @Test func theFixtureIsAFewKilobytesOfValidConfiguration() throws {
        #expect((3_000...16_000).contains(Self.providerTOML.utf8.count))
        let config = try ConfigManager.parseValidating(Self.providerTOML)
        #expect(config.provider.name == "memory-fixture")
        #expect(config.backend.enabledModels.count == 24)
    }

    @Test func parsingOneTextAgainKeepsBytesFlat() throws {
        let growth = try Self.smallestGrowth {
            let table = try TOMLTable(string: Self.providerTOML)
            let peer = table["future_extension"]?["peers"]?[3]
            _ = (peer?["name"]?.string, peer?["port"]?.int, peer?["seen"]?.dateTime)
            _ = (table["future_extension"]?["ratio"]?.double, table["future_extension"]?["enabled"]?.bool)
            _ = (table["future_extension"]?["day"]?.date, table["future_extension"]?["alarm"]?.time)
            _ = (table.keys, table.values.count)
            for (_, value) in table { _ = value.type }
            let text = table.convert()
            guard try TOMLTable(string: text) == table else { throw TOMLRoundTripMismatch() }
        }
        #expect(growth < Self.limit, Self.report(growth))
    }

    @Test func decodingAndEncodingOneConfigurationAgainKeepsBytesFlat() throws {
        // `ConfigManager.parseValidating` remembers recent texts; this is the TOMLKit work under it.
        let growth = try Self.smallestGrowth {
            let config = try TOMLDecoder().decode(ProviderConfig.self, from: Self.providerTOML)
            _ = ConfigManager.serialize(config)
        }
        #expect(growth < Self.limit, Self.report(growth))
    }

    @Test func savingAClusterSetupAgainKeepsBytesFlat() throws {
        let original = Data(Self.providerTOML.utf8)
        let reference = try ClusterConfigurationReference(
            configuration: "/Users/fixture/.config/darkbloom/clusters/fixture.cluster.json",
            sha256: String(repeating: "a", count: 64))
        let saved = try ClusterConfigurationStore.updatingProviderData(original, reference: reference)
        #expect(try ConfigManager.parseValidating(String(decoding: saved, as: UTF8.self)).cluster == reference)
        let growth = try Self.smallestGrowth {
            _ = try ClusterConfigurationStore.updatingProviderData(original, reference: reference)
        }
        #expect(growth < Self.limit, Self.report(growth))
    }
}

private struct TOMLRoundTripMismatch: Error {}

/// What TOMLKit reads, writes and refuses is unchanged by freeing its trees: the expected texts are the ones TOMLKit
/// 0.6.0 produced. A value read from a table stays usable after the table itself is gone, edits through a nested
/// table still change the document it came from (`LocalSettings.updatingLocal` relies on that), and inserting copies,
/// so the two trees are freed independently.
@Suite struct TOMLTableBehaviorTests {
    static let document = #"""
        title = "fixture"
        count = 0xEA64
        octal = 0o755
        binary = 0b1101
        ratio = 50.10475
        negative = -17
        enabled = true
        disabled = false
        day = 2021-05-20
        alarm = 04:27:05.000000294
        utc = 1979-05-27T07:32:00Z
        local = 1979-05-27T00:32:00.999999-07:00
        floating = 1979-05-27T07:32:00
        multiline = """
        first
        second"""
        literal = 'C:\path\to'
        list = [1, 2, "three", [4.5, false]]
        inline = { name = "nested", size = 3 }

        [provider]
        name = "memory-fixture"

        [[models]]
        id = "first"
        weight = 1

        [[models]]
        id = "second"
        weight = 2
        """#

    /// `document` as TOMLKit 0.6.0 converts it.
    static let converted = #"""
        alarm = 04:27:05.000000294
        binary = 0b1101
        count = 0xEA64
        day = 2021-05-20
        disabled = false
        enabled = true
        floating = 1979-05-27T07:32:00
        inline = { name = 'nested', size = 3 }
        list = [ 1, 2, 'three', [ 4.5, false ] ]
        literal = 'C:\path\to'
        local = 1979-05-27T00:32:00.999999-07:00
        multiline = '''first
        second'''
        negative = -17
        octal = 0o755
        ratio = 50.104750000000003
        title = 'fixture'
        utc = 1979-05-27T07:32:00Z

        [provider]
        name = 'memory-fixture'

        [[models]]
        id = 'first'
        weight = 1

        [[models]]
        id = 'second'
        weight = 2
        """#

    @Test func everyValueTypeReadsConvertsAndComparesAsBefore() throws {
        let table = try TOMLTable(string: Self.document)
        #expect(table["title"]?.string == "fixture")
        #expect(table["count"]?.int == 0xEA64)
        #expect(table["octal"]?.int == 0o755)
        #expect(table["binary"]?.int == 0b1101)
        #expect(table["ratio"]?.double == 50.10475)
        #expect(table["negative"]?.int == -17)
        #expect(table["enabled"]?.bool == true)
        #expect(table["disabled"]?.bool == false)
        #expect(table["day"]?.date == TOMLDate(year: 2021, month: 5, day: 20))
        #expect(table["alarm"]?.time == TOMLTime(hour: 4, minute: 27, second: 5, nanoSecond: 294))
        let morning = TOMLDate(year: 1979, month: 5, day: 27)
        #expect(table["utc"]?.dateTime == TOMLDateTime(
            date: morning, time: TOMLTime(hour: 7, minute: 32, second: 0, nanoSecond: 0), offset: TOMLTimeOffset(offset: 0)))
        #expect(table["local"]?.dateTime == TOMLDateTime(
            date: morning, time: TOMLTime(hour: 0, minute: 32, second: 0, nanoSecond: 999_999_000),
            offset: TOMLTimeOffset(hours: -7, minutes: 0)))
        #expect(table["floating"]?.dateTime == TOMLDateTime(
            date: morning, time: TOMLTime(hour: 7, minute: 32, second: 0, nanoSecond: 0)))
        #expect(table["multiline"]?.string == "first\nsecond")
        #expect(table["literal"]?.string == #"C:\path\to"#)
        #expect(table["list"]?.array?.count == 4)
        #expect(table["list"]?[2]?.string == "three")
        #expect(table["list"]?[3]?[1]?.bool == false)
        #expect(table["inline"]?["name"]?.string == "nested")
        #expect(table["provider"]?["name"]?.string == "memory-fixture")
        #expect(table["models"]?.array?.count == 2)
        #expect(table["models"]?[1]?["id"]?.string == "second")

        let keys = ["alarm", "binary", "count", "day", "disabled", "enabled", "floating", "inline", "list", "literal",
                    "local", "models", "multiline", "negative", "octal", "provider", "ratio", "title", "utc"]
        #expect(table.keys == keys)
        #expect(table.values.count == keys.count)
        #expect(table.map { $0.0 } == keys)
        #expect(table.convert() == Self.converted)
        #expect(try TOMLTable(string: table.convert()) == table)
        #expect(try TOMLTable(string: Self.converted) == table)
        #expect(try TOMLTable(string: "title = 'other'") != table)
    }

    @Test func valuesOutliveTheTableTheyWereReadFrom() throws {
        // Each parsed table below is a temporary, gone once the value is read from it.
        let models = try #require(try TOMLTable(string: Self.document)["models"]?.array)
        let name = try #require(try TOMLTable(string: Self.document)["provider"]?["name"])
        let inline = try #require(try TOMLTable(string: Self.document)["inline"]?.table)
        let list = try #require(try TOMLTable(string: Self.document)["list"])
        #expect(models.count == 2)
        #expect(models[1]["id"]?.string == "second")
        #expect(name.string == "memory-fixture")
        #expect(inline.convert() == "{ name = 'nested', size = 3 }")
        #expect(list[3]?[0]?.double == 4.5)
    }

    @Test func editsThroughANestedTableChangeTheirDocument() throws {
        let table = try TOMLTable(string: "[local]\nport = 1\n")
        let local = try #require(table["local"]?.table)
        local["port"] = 2
        local["bind"] = "127.0.0.1"
        #expect(table.convert() == "[local]\nbind = '127.0.0.1'\nport = 2")
    }

    @Test func insertingCopiesSoEitherTreeMayGoFirst() throws {
        var source: TOMLTable? = try TOMLTable(string: Self.document)
        let destination = TOMLTable()
        destination["provider"] = source?["provider"]
        destination["list"] = source?["list"]?.array
        destination.insert(try #require(source), at: "all")
        source?["provider"]?.table?["name"] = "changed"
        #expect(source?["provider"]?["name"]?.string == "changed")
        source = nil
        #expect(destination["provider"]?["name"]?.string == "memory-fixture")
        #expect(destination["all"]?["models"]?[1]?["id"]?.string == "second")
        #expect(destination["list"]?[3]?[0]?.double == 4.5)
    }

    @Test func removedValuesKeepTheirContents() throws {
        let table = try TOMLTable(string: Self.document)
        let removed = try #require(table.remove(at: "inline"))
        #expect(table["inline"] == nil)
        #expect(removed.table?.convert() == "{ name = 'nested', size = 3 }")
        let list = try #require(table["list"]?.array)
        let first = list.remove(at: 0)
        #expect(first.int == 1)
        #expect(list.count == 3)
        #expect(table["list"]?.array?.count == 3)
    }

    @Test func dateTimesWrittenFromSwiftKeepTheirOffsets() throws {
        let evening = TOMLDateTime(
            date: TOMLDate(year: 2026, month: 11, day: 13), time: TOMLTime(hour: 19, minute: 3, second: 0, nanoSecond: 0),
            offset: TOMLTimeOffset(hours: -8, minutes: 0))
        let table = TOMLTable()
        table["when"] = evening
        #expect(table["when"]?.dateTime == evening)
        #expect(table.convert() == "when = 2026-11-13T19:03:00-08:00")
        #expect(evening.debugDescription == "2026-11-13T19:03:00-08:00")

        let array = TOMLArray([evening, 1])
        array[1] = TOMLDateTime(
            date: TOMLDate(year: 2026, month: 1, day: 2), time: TOMLTime(hour: 3, minute: 4, second: 5, nanoSecond: 0),
            offset: TOMLTimeOffset(hours: 5, minutes: 30))
        #expect(array.debugDescription == "[ 2026-11-13T19:03:00-08:00, 2026-01-02T03:04:05+05:30 ]")
        #expect(array[1].dateTime?.offset == TOMLTimeOffset(offset: 330))
    }

    @Test(arguments: [
        ("[broken", "Error while parsing table header: encountered end-of-file", 1, 8),
        ("a = ", "Error while parsing key-value pair: encountered end-of-file", 1, 5),
        ("a = 1\na = 2", "Error while parsing key-value pair: cannot redefine existing integer 'a'", 2, 5),
    ])
    func aRefusedParseStillSaysWhereItFailed(_ refusal: (text: String, description: String, line: Int, column: Int)) {
        do {
            _ = try TOMLTable(string: refusal.text)
            Issue.record("\(refusal.text) parsed")
        } catch let error as TOMLParseError {
            #expect(error.description == refusal.description)
            #expect(error.source.begin.line == refusal.line && error.source.begin.column == refusal.column)
            #expect(error.source.end == error.source.begin)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
