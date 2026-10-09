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
        expectEqual(wired.symmetricDifference(Set(ClusterConsoleWiring.wired)).sorted(), [], "wired rows differ from the code")
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

        // The admitted-model listing is derived from the adapters. If an
        // adapter gains a second way to name models, the listing must read it.
        let adapter = try String(contentsOf: adapterSource, encoding: .utf8)
        expect(!adapter.contains("registeredProfiles"),
            "ClusterRuntimeAdapter now has registeredProfiles: make ClusterRuntimeAdapter.admittedModels list every pair it returns")
        expectEqual(ClusterRuntimeAdapter.admittedModels.map(\.runtimeModelID), ClusterRuntimeAdapter.allCases.map(\.runtimeModelID),
            "admitted models are not the adapters' own")
        expect(!ClusterRuntimeAdapter.admittedModels.isEmpty, "no admitted model is listed")
    }
}
