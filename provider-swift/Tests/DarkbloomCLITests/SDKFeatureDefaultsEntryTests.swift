import Foundation
import Testing

/// review prov-2109-d2 SF2: `SDKFeatureDefaults.apply()` runs first in
/// `main.swift`, before every early branch (the native serving qualification
/// loads a model and serves; it must qualify the defaults it ships with).
@Suite struct SDKFeatureDefaultsEntryTests {
    @Test func defaultsApplyBeforeAnyCommandOrEarlyBranch() throws {
        let main = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DarkbloomCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // provider-swift
            .appendingPathComponent("Sources/darkbloom/main.swift")
        let code = try String(contentsOf: main, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("import ") }
        let apply = try #require(code.firstIndex(of: "SDKFeatureDefaults.apply()"))
        let firstBranch = try #require(code.firstIndex { $0.hasPrefix("if ") })
        #expect(apply < firstBranch)
        #expect(code.filter { $0.contains("SDKFeatureDefaults.apply(") }.count == 1)
    }
}
