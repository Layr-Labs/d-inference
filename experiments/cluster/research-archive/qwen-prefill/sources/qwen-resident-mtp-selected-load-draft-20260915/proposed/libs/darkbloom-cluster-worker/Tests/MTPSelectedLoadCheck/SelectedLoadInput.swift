import Foundation

/// The original worker's closed parser is copied exactly into this private
/// executable; these additional restrictions apply only to the loading check.
struct SelectedLoadInput {
    enum Mode: String { case checkArguments = "check-arguments", load }
    let mode: Mode
    let worker: WorkerConfiguration

    init(arguments: [String], now: UInt64) throws {
        guard let first = arguments.first, let mode = Mode(rawValue: first) else {
            throw WorkerFailure.invalid("Expected explicit check-arguments or load command")
        }
        let worker = try WorkerConfiguration(arguments: Array(arguments.dropFirst()), now: now)
        guard worker.bootstrap == nil, worker.load.rank == 1, worker.load.stageCut == 4,
              worker.load.prefillSchedule == .serial,
              worker.load.allocatorPolicy == .disableFreedBufferCache else {
            throw WorkerFailure.invalid("Loading check requires rank1/cut4, serial, cache-off and no bootstrap attachment")
        }
        self.mode = mode; self.worker = worker
    }
}
