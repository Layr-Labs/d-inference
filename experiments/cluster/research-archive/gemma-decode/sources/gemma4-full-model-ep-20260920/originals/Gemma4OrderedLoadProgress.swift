import Foundation

/// Keep the currently authorized tensor in the remaining reserve until its
/// materialization scope has ended. Authorization alone never advances progress.
struct Gemma4OrderedLoadProgress {
    let expected: [Gemma4SelectedTensor]
    private(set) var completed = 0
    private(set) var pending: Int?
    private(set) var failed = false

    mutating func begin(_ tensor: Gemma4SelectedTensor) throws {
        guard !failed, pending == nil, expected.indices.contains(completed), matches(tensor, expected[completed]) else {
            failed = true; throw ProbeError("Gemma ordered load authorization repeated or substituted")
        }
        pending = completed
    }
    mutating func finish(_ tensor: Gemma4SelectedTensor) throws {
        guard !failed, pending == completed, expected.indices.contains(completed), matches(tensor, expected[completed]) else {
            failed = true; throw ProbeError("Gemma ordered load completion differs")
        }
        completed += 1; pending = nil
    }
    mutating func requireFinished() throws {
        guard !failed, pending == nil, completed == expected.count else {
            failed = true; throw ProbeError("Gemma ordered load did not finish every tensor")
        }
    }
    mutating func poison() { failed = true }
    private func matches(_ a: Gemma4SelectedTensor, _ b: Gemma4SelectedTensor) -> Bool {
        a.localName == b.localName && a.source == b.source && a.loadedDType == b.loadedDType
    }
}
