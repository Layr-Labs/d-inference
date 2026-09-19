import Foundation
import ProviderCore

extension Start {
    /// Review residency before downloading the selection. Returning to the
    /// picker does not download models or write settings. The TTY decision is
    /// made by interactiveCatalogPicker; unattended paths never call this.
    static func reviewModelSlots(
        selectedCount: Int,
        current: UInt64,
        readInput: () -> String? = { readLine() },
        emit: (String) -> Void = { print($0, terminator: "") },
        saveLimit: (UInt64) throws -> Void
    ) throws -> Bool {
        switch ModelSlotPolicy.review(
            selectedCount: selectedCount, current: current,
            readInput: readInput, emit: emit)
        {
        case .keep:
            return true
        case .reviseSelection:
            return false
        case .change(let limit):
            try saveLimit(limit)
            emit("  Saved backend.max_model_slots = \(limit). Applies when this provider starts.\n")
            emit("  \(ModelSlotPolicy.summary(selectedCount: selectedCount, configuredLimit: limit))\n")
            emit("  \(ModelSlotPolicy.selectionAdvice(selectedCount: selectedCount, configuredLimit: limit))\n")
            return true
        }
    }
}
