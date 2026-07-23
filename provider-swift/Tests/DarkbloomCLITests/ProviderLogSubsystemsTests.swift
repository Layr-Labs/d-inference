import Foundation
import ProviderCore
import Testing

/// Coverage pins for the `darkbloom report` / `darkbloom logs` collection
/// predicate. The v0.7.13 incident: both commands filtered on the single
/// `dev.darkbloom.provider` subsystem while all KVCacheSSD and engine-bridge
/// code logs to `com.darkbloom.provider` — so uploaded reports carried zero
/// SSD-cache lines. These tests pin the predicate AND scan the package
/// sources so a future subsystem cannot silently escape collection again.
@Suite("Provider log subsystems")
struct ProviderLogSubsystemsTests {

    @Test("unified log predicate covers every registered subsystem")
    func predicateIsPinned() {
        #expect(ProviderLogSubsystems.unifiedLogPredicate()
            == #"subsystem == "dev.darkbloom.provider" OR "#
            + #"subsystem == "com.darkbloom.provider" OR "#
            + #"subsystem == "io.darkbloom.provider" OR "#
            + #"subsystem == "io.darkbloom.fan""#)
    }

    @Test("every subsystem literal under Sources is registered for collection")
    func sourceSubsystemLiteralsAreRegistered() throws {
        // Tests/DarkbloomCLITests/<this file> -> package root -> Sources.
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DarkbloomCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourcesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]))
        let regex = try NSRegularExpression(pattern: #"subsystem:\s*"([^"]+)""#)

        var found: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in regex.matches(in: contents, range: range) {
                guard let subsystemRange = Range(match.range(at: 1), in: contents)
                else { continue }
                found.insert(String(contents[subsystemRange]))
            }
        }

        // Sanity: the scan actually saw the known subsystems — an empty or
        // partial result would mean the walk broke, not that coverage holds.
        #expect(found.isSuperset(of: ProviderLogSubsystems.all))
        // Drift gate: any subsystem logged anywhere in Sources MUST be in
        // the collection list, or `darkbloom report` silently drops it.
        let unregistered = found.subtracting(ProviderLogSubsystems.all)
        #expect(
            unregistered.isEmpty,
            "subsystems logged but not collected by report/logs: \(unregistered.sorted())")
    }
}
