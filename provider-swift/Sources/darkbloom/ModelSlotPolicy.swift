import Foundation

/// Presentation and input policy for resident-model slots, separate from
/// request concurrency and from the list of models advertised to the network.
enum ModelSlotPolicy {
    enum Choice: Equatable {
        case keep
        case change(UInt64)
        case reviseSelection
    }

    static func summary(selectedCount: Int, configuredLimit: UInt64) -> String {
        let effective = min(UInt64(max(0, selectedCount)), max(1, configuredLimit))
        return "\(selectedCount) selected · up to \(effective) resident models (configured limit: \(configuredLimit))"
    }

    static func selectionAdvice(selectedCount: Int, configuredLimit: UInt64) -> String {
        if UInt64(max(0, selectedCount)) > max(1, configuredLimit) {
            return "Loading another selected model may replace an idle resident."
        }
        return "Memory checks may allow fewer residents; coexistence is not guaranteed."
    }

    static func parseLimit(_ input: String) -> UInt64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let limit = UInt64(text), limit > 0, limit <= UInt64(Int.max)
        else { return nil }
        return limit
    }

    /// Enter, EOF or exhausted retries preserve the operator's current policy.
    /// Only an explicit, valid, different value is a request to write config.
    static func review(
        selectedCount: Int,
        current: UInt64,
        readInput: () -> String?,
        emit: (String) -> Void
    ) -> Choice {
        emit("""

          Resident models
          \(summary(selectedCount: selectedCount, configuredLimit: current))
          \(selectionAdvice(selectedCount: selectedCount, configuredLimit: current))
          Increasing the limit can use more memory. Load-time memory checks still apply.
          This is separate from requests served concurrently by each model.

            1) Keep the current limit
            2) Change the resident-model limit (saved to provider.toml)
            3) Return to model selection

        """)
        for _ in 0..<3 {
            emit("  Choice [1]: ")
            guard let input = readInput() else { return .keep }
            switch input.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "", "1": return .keep
            case "3": return .reviseSelection
            case "2":
                for _ in 0..<3 {
                    emit("  Maximum resident models [\(current)]: ")
                    guard let input = readInput() else { return .keep }
                    if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .keep
                    }
                    if let limit = parseLimit(input) {
                        return limit == current ? .keep : .change(limit)
                    }
                    emit("  Enter a positive whole number no greater than \(Int.max).\n")
                }
                return .keep
            default:
                emit("  Please enter 1, 2 or 3.\n")
            }
        }
        return .keep
    }
}
