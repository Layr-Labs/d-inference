import Darwin
import Foundation
import SandboxRuntime

enum LumeGuestCommandJournalBudget {
    static let controlDiskBytes: UInt64 = 128 * 1_024 * 1_024
    // Covers other VM metadata and one in-flight result publication. Each
    // command additionally reserves allocation rounding and filesystem metadata.
    static let safetyBytes: UInt64 = 128 * 1_024 * 1_024
    static let perCommandFilesystemBytes: UInt64 = 64 * 1_024
    static let maximumCommandStorageBytes =
        UInt64(LumeGuestCommandEnvelope.maximumEnvelopeBytes) + perCommandFilesystemBytes
    static let availableJournalBytes = SandboxStorageReservation.perSandboxOverheadBytes
        - controlDiskBytes - safetyBytes
    static let maximumCommandCount = min(256, Int(availableJournalBytes / maximumCommandStorageBytes))

    /// The caller holds the VM operation and lease locks across this check,
    /// mkdir and claim publication. Directories themselves are the durable
    /// admission record, so a crash cannot reset a separate cached counter.
    /// Stop after a bounded number of entries even for an oversized old journal.
    static func requireRoom(in installation: Int32) throws {
        let duplicate = dup(installation)
        guard duplicate >= 0 else { throw LumeGuestCommandJournal.outcomeUnavailable() }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw LumeGuestCommandJournal.outcomeUnavailable()
        }
        defer { closedir(directory) }
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw LumeGuestCommandJournal.outcomeUnavailable() }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            // Incomplete claims and unexpected entries still consume a slot;
            // ignoring them would permit crashes to grow storage indefinitely.
            count += 1
            if count >= maximumCommandCount { throw SandboxRuntimeError.commandLimitReached }
        }
    }
}
