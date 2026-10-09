import Foundation
import DarkbloomClusterProtocol
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// `handoff/TUI-wiring.md` and `ClusterConsoleWiring` must name the same
    /// elements in the same states, so the screen cannot show as live
    /// something the table does not list as wired.
    static func wiringTableMatchesCode() throws {
        let table = try String(contentsOf: wiringTable, encoding: .utf8)
        var states = [String: String]()
        for line in table.split(whereSeparator: \.isNewline) where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            let id = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            expect(states[id] == nil, "the table lists \(id) twice")
            states[id] = cells[cells.count - 2]
        }
        expect(states.count >= 40, "the table was not read: \(states.count) rows")
        let wired = Set(states.filter { $0.value.hasPrefix("wired") }.keys)
        let exists = Set(states.filter { $0.value.hasPrefix("exists, not wired") }.keys)
        let none = Set(states.filter { $0.value.hasPrefix("none") }.keys)
        expectEqual(wired.count + exists.count + none.count, states.count, "every row has one of the three states")
        expectEqual(wired.symmetricDifference(Set(ClusterConsoleWiring.wired + ClusterConsoleWiring.reconciledAtLaunch.map(\.id))).sorted(), [],
            "wired rows differ from the code")
        // What is reconciled at launch is shown by an element that is itself wired.
        expect(ClusterConsoleWiring.reconciledAtLaunch.allSatisfy { ClusterConsoleWiring.wired.contains($0.shownBy) }, "an intent is shown by an element that is not wired")
        // Every action is a wired row of its own.
        expect(ClusterConsoleAction.allCases.allSatisfy { ClusterConsoleWiring.wired.contains($0.wiring) }, "an action is not a wired row")
        expectEqual(Set(ClusterConsoleAction.allCases.map(\.wiring)).count, ClusterConsoleAction.allCases.count, "two actions share a row")
        expectEqual(exists.symmetricDifference(Set(ClusterConsoleWiring.unavailable.filter(\.exists).map(\.id))).sorted(), [],
            "rows for an operation that exists but is not wired differ from the code")
        expectEqual(none.symmetricDifference(Set(ClusterConsoleWiring.unavailable.filter { !$0.exists }.map(\.id))).sorted(), [],
            "rows with no operation differ from the code")
        expectEqual(Set(ClusterConsoleWiring.wired).count, ClusterConsoleWiring.wired.count, "a wired element is listed twice")
        expect(ClusterConsoleWiring.unavailable.allSatisfy { !$0.reason.isEmpty && !$0.title.isEmpty }, "an unavailable element has no reason")

        // Everything the gate names as a verb and this build cannot do stays out of the key line.
        let keys = ClusterConsoleRenderer.frame(.init(size: .init(columns: 200, rows: 30))).lines.last?.text ?? ""
        for word in ["join", "leave", "drain", "discover", "request"] {
            expect(!keys.lowercased().contains(word), "the key line offers \(word), which no operation backs")
        }
        // Each action key belongs to exactly one action.
        expectEqual(Set(ClusterConsoleAction.allCases.map(\.key)).count, ClusterConsoleAction.allCases.count, "two actions share a key")

        // The admitted-model listing is the list admission itself checks:
        // every registered model/profile pair of every adapter, and no other.
        let listed = ClusterRuntimeAdapter.admittedModels
        expectEqual(listed.map { "\($0.adapterID) v\($0.adapterVersion) \($0.runtimeModelID) \($0.profileID)" },
            ClusterRuntimeAdapter.allCases.flatMap { adapter in
                adapter.registeredProfiles.map { "\(adapter.rawValue) v\(adapter.version) \($0.runtimeModelID) \($0.profileID)" }
            }, "admitted models are not the adapters' registered pairs")
        expect(listed.count >= 2 && Set(listed.map(\.runtimeModelID)).count == listed.count,
            "the listing has \(listed.count) entries; the catalog registers the 9B and the 27B")
        // Read against the source too: a model named there in any other way would be missing here.
        let adapter = try String(contentsOf: adapterSource, encoding: .utf8)
        let literal = try NSRegularExpression(pattern: "\"(registered_[a-z0-9_]+)\"")
        let named = Set(literal.matches(in: adapter, range: NSRange(adapter.startIndex..., in: adapter)).compactMap {
            Range($0.range(at: 1), in: adapter).map { String(adapter[$0]) }
        })
        expectEqual(named.symmetricDifference(Set(listed.flatMap { [$0.runtimeModelID, $0.profileID] })).sorted(), [],
            "ClusterRuntimeAdapter names a model or profile that ClusterRuntimeAdapter.admittedModels does not list")
    }
}
