import Foundation
import Testing

/// Provider code waits for a child through its termination handler, with
/// `ProcessExitObserver`, never with `Process.waitUntilExit()`. Several of the
/// places that start a child (`open`, `codesign`, `profiles`, `log`) cannot be
/// run from a test, so this reads the sources instead.
@Suite("Child exit wait convention")
struct ChildExitWaitConventionTests {
    @Test("No provider source waits with Process.waitUntilExit()")
    func sourcesDoNotCallWaitUntilExit() throws {
        let sources = try providerPackageRoot().appendingPathComponent("Sources")
        let paths = try #require(FileManager.default.enumerator(atPath: sources.path))
        var calls: [String] = []
        for case let path as String in paths where path.hasSuffix(".swift") {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.contains(".waitUntilExit(") && !code.hasPrefix("//") {
                    calls.append("\(path):\(index + 1)")
                }
            }
        }
        #expect(calls.isEmpty, "use ProcessExitObserver instead of waitUntilExit() in: \(calls.sorted().joined(separator: ", "))")
    }

    private func providerPackageRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root != root.deletingLastPathComponent() {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                return root
            }
            root.deleteLastPathComponent()
        }
        throw PackageLocationError.packageRootNotFound
    }

    private enum PackageLocationError: Error { case packageRootNotFound }
}
