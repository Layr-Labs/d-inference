import Foundation
import ProviderCore

extension Status {
    /// A held provider is connected and healthy but deliberately takes no
    /// inference; without this line "Daemon: running" reads as earning.
    static func addonHoldLine(_ snapshot: AddonHoldSnapshot?, now: Date = Date()) -> String? {
        guard let holds = snapshot?.holds, let first = holds.first else { return nil }
        let others = holds.count > 1 ? " (+\(holds.count - 1) more)" : ""
        return "Not serving: held by add-on \(Addon.describe(first, now: now))\(others). "
            + "Run `\(BuildEnvironment.current.cliName) addon` for details."
    }
}
