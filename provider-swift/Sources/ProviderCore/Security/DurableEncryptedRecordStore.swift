/// Crash-durable encrypted record store shared by terminal and abort journals.

import CryptoKit
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - Durable encrypted filesystem boundary

/// Shared by terminal records and abort tombstones. It is intentionally a
/// concrete production implementation: tests inject only key material and a
/// temporary directory, then execute these exact AES-GCM/POSIX paths.
final class DurableEncryptedRecordStore: @unchecked Sendable {
    struct ScannedRecord {
        let name: String
        let url: URL
        let plaintext: Data
    }

    struct ScanResult {
        let records: [ScannedRecord]
        let quarantinedNames: Set<String>
        let quarantinedCount: Int
        let reservationNames: Set<String>
        let invalidReservationNames: Set<String>
        let stagedReservations: [String: ScannedRecord]
    }

    private static let magic = Data([0x44, 0x42, 0x54, 0x4A])  // "DBTJ"
    private static let formatVersion: UInt16 = 1
    private static let tagBytes = 16
    private static let headerBytes = 24
    private static let fileExtension = "dbtj"
    private static let tempMarker = ".tmp-"

    private let recordsDirectory: URL
    private let quarantineDirectory: URL
    private let reservationsDirectory: URL
    private let namespace: String
    private let key: SymmetricKey
    private let maximumRecordBytes: Int
    private let lifetimeLock: JournalLifetimeFileLock
    private let faults: any JournalFaultInjecting
    private let lock = NSLock()

    init(
        directory: URL,
        namespace: String,
        key: SymmetricKey,
        maximumRecordBytes: Int,
        lockName: String,
        faults: any JournalFaultInjecting = NoJournalFaults()
    ) throws {
        try Self.ensureDirectory(directory)
        self.lifetimeLock = try JournalLifetimeFileLock(directory: directory, name: lockName)
        self.recordsDirectory = directory.appendingPathComponent("records", isDirectory: true)
        self.quarantineDirectory = directory.appendingPathComponent(
            "quarantine", isDirectory: true)
        self.reservationsDirectory = directory.appendingPathComponent(
            "reservations", isDirectory: true)
        self.namespace = namespace
        self.key = key
        self.maximumRecordBytes = maximumRecordBytes
        self.faults = faults
        try Self.ensureDirectory(recordsDirectory)
        try Self.ensureDirectory(quarantineDirectory)
        try Self.ensureDirectory(reservationsDirectory)
    }

    func scan() throws -> ScanResult {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw TerminalJournalError.ioFailure("list records: \(error)")
        }

        var records: [ScannedRecord] = []
        let existingQuarantine = try quarantinedNamesLocked()
        let quarantined = existingQuarantine.names
        let quarantinedCount = existingQuarantine.count
        let reservations = try reservationNamesLocked()
        for url in urls {
            let filename = url.lastPathComponent
            if filename.contains(Self.tempMarker) { continue }
            guard url.pathExtension == Self.fileExtension else {
                throw TerminalJournalError.malformedRecord(
                    "unexpected journal file \(filename)")
            }
            let name = url.deletingPathExtension().lastPathComponent
            if quarantined.contains(name) { continue }
            // Header truncation, wrong key/AAD, and GCM failure are not proof
            // that the obligation is malformed. Fail initialization with the
            // source file untouched.
            let plaintext = try readLocked(url: url, name: name)
            records.append(ScannedRecord(name: name, url: url, plaintext: plaintext))
        }
        // Only after every obligation authenticated successfully may orphan
        // temp files be removed.
        try sweepTempsLocked()
        try sweepQuarantineTempsLocked()
        return ScanResult(
            records: records,
            quarantinedNames: quarantined,
            quarantinedCount: quarantinedCount,
            reservationNames: reservations.names,
            invalidReservationNames: reservations.invalid,
            stagedReservations: reservations.staged
        )
    }

    /// Allocate real filesystem blocks for the largest possible terminal
    /// before funded start durability can be acknowledged.
    func reserveTerminalSpace(name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let url = reservationURL(name: name)
        let descriptor = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        if descriptor < 0 {
            if errno == EEXIST {
                guard reservationFileIsValid(url) else {
                    throw TerminalJournalError.malformedRecord(
                        "existing terminal reservation has the wrong size")
                }
                let existing = url.path.withCString { open($0, O_RDWR | O_CLOEXEC) }
                guard existing >= 0 else {
                    throw TerminalJournalError.systemCall(
                        operation: "open existing terminal reservation",
                        errorNumber: errno
                    )
                }
                defer { _ = close(existing) }
                try inject(.fileSync)
                try Self.syncFileDescriptor(existing)
                try inject(.directorySync)
                try Self.syncDirectory(reservationsDirectory)
                return
            }
            throw TerminalJournalError.systemCall(
                operation: "create terminal reservation",
                errorNumber: errno
            )
        }
        defer { _ = close(descriptor) }

        do {
            try inject(.preallocate)
            try Self.preallocate(
                descriptor: descriptor,
                byteCount: maximumRecordBytes
            )
            try inject(.fileSync)
            try Self.syncFileDescriptor(descriptor)
            try inject(.directorySync)
            try Self.syncDirectory(reservationsDirectory)
        } catch {
            // If durability is uncertain, leave the reservation in place.
            // Reopen reconciliation can safely remove it only when no funded
            // start record exists.
            throw error
        }
    }

    func consumeTerminalReservation(name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try inject(.unlink)
        try Self.unlinkIfPresent(reservationURL(name: name))
        try inject(.directorySync)
        try Self.syncDirectory(reservationsDirectory)
    }

    func terminalReservationExists(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: reservationURL(name: name).path)
    }

    func recordExists(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: recordURL(name: name).path)
    }

    func write(name: String, plaintext: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileData = try encryptLocked(name: name, plaintext: plaintext)
        guard fileData.count <= maximumRecordBytes else {
            throw TerminalJournalError.recordTooLarge(
                actual: fileData.count,
                maximum: maximumRecordBytes
            )
        }
        let target = recordURL(name: name)
        let temporary = recordsDirectory.appendingPathComponent(
            "\(name).\(Self.fileExtension)\(Self.tempMarker)\(UUID().uuidString)")
        do {
            try inject(.newFileAllocation)
            try inject(.write)
            try Self.writeFile(fileData, to: temporary)
            try inject(.fileSync)
            try Self.syncFile(at: temporary)
            try inject(.rename)
            try Self.atomicRename(from: temporary, to: target)
            try inject(.directorySync)
            try Self.syncDirectory(recordsDirectory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let journalError = error as? TerminalJournalError {
                throw journalError
            }
            throw TerminalJournalError.ioFailure("durable record write: \(error)")
        }
    }

    /// Persist a terminal using the blocks reserved before funded admission.
    ///
    /// The reservation inode remains linked from `reservations/` until the
    /// replacement record has been directory-fsynced. A hard link in
    /// `records/` lets the atomic rename consume that inode without allocating
    /// another data-bearing temporary file.
    func writeConsumingReservation(name: String, plaintext: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileData = try encryptLocked(name: name, plaintext: plaintext)
        guard fileData.count <= maximumRecordBytes else {
            throw TerminalJournalError.recordTooLarge(
                actual: fileData.count,
                maximum: maximumRecordBytes
            )
        }

        let reservation = reservationURL(name: name)
        let reservationSize = try Self.regularFileSize(reservation)
        if reservationSize == maximumRecordBytes {
            try stageTerminalLocked(fileData, reservation: reservation)
        } else {
            // A prior attempt may have durably staged and truncated this exact
            // terminal before crashing. Never re-encrypt/re-sign over it.
            let existing = try readLocked(url: reservation, name: name)
            guard existing == plaintext else {
                throw TerminalJournalError.malformedRecord(
                    "staged terminal reservation conflicts with requested terminal")
            }
        }

        try commitStagedReservationLocked(name: name)
    }

    /// Complete a terminal replacement that was durably staged before a crash.
    /// The staged ciphertext is authenticated before this method is called by
    /// recovery, and is authenticated again here before its inode is relinked.
    func commitStagedReservation(name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try readLocked(url: reservationURL(name: name), name: name)
        try commitStagedReservationLocked(name: name)
    }

    func delete(name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let target = recordURL(name: name)
        try inject(.unlink)
        try Self.unlinkIfPresent(target)
        // This fsync is part of the ACK contract, not best effort.
        try inject(.directorySync)
        try Self.syncDirectory(recordsDirectory)
    }

    func quarantineAuthenticatedRecord(name: String, reason: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try quarantineAuthenticatedRecordLocked(name: name, reason: reason)
    }

    private func stageTerminalLocked(_ data: Data, reservation: URL) throws {
        guard reservationFileIsValid(reservation) else {
            throw TerminalJournalError.malformedRecord(
                "terminal reservation is not fully preallocated")
        }
        let descriptor = reservation.path.withCString { open($0, O_RDWR | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw TerminalJournalError.systemCall(
                operation: "open terminal reservation for staging",
                errorNumber: errno
            )
        }
        defer { _ = close(descriptor) }

        try inject(.write)
        try Self.writeAll(data, descriptor: descriptor)

        // The bytes become durable while the inode still has its fully
        // preallocated logical length. Only then can shortening release the
        // unused tail without risking a short, unauthenticated staged terminal.
        try inject(.fileSync)
        try Self.syncFileDescriptor(descriptor)
        try inject(.truncate)
        guard ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw TerminalJournalError.systemCall(
                operation: "truncate staged terminal reservation",
                errorNumber: errno
            )
        }
        try inject(.fileSync)
        try Self.syncFileDescriptor(descriptor)
    }

    private func commitStagedReservationLocked(name: String) throws {
        let reservation = reservationURL(name: name)
        let target = recordURL(name: name)
        if try Self.sameInode(reservation, target) {
            // A previous rename reached the namespace but failed before its
            // directory fsync. Establish destination durability before dropping the
            // reservation link that protects the same inode.
            try inject(.directorySync)
            try Self.syncDirectory(recordsDirectory)
            try inject(.unlink)
            try Self.unlinkIfPresent(reservation)
            try inject(.directorySync)
            try Self.syncDirectory(reservationsDirectory)
            return
        }
        let temporary = recordsDirectory.appendingPathComponent(
            "\(name).\(Self.fileExtension)\(Self.tempMarker)\(UUID().uuidString)")

        do {
            try inject(.link)
            try Self.hardLink(from: reservation, to: temporary)
            try inject(.rename)
            try Self.atomicRename(from: temporary, to: target)
            try inject(.directorySync)
            try Self.syncDirectory(recordsDirectory)

            // The destination name is now durable and owns the staged inode. Only
            // now may the original reservation link be consumed.
            try inject(.unlink)
            try Self.unlinkIfPresent(reservation)
            try inject(.directorySync)
            try Self.syncDirectory(reservationsDirectory)
        } catch {
            // A pre-rename hard link is only a temporary alias. The reservation link
            // remains authoritative and lets reopen safely retry the commit.
            try? Self.unlinkIfPresent(temporary)
            throw error
        }
    }

    private func encryptLocked(name: String, plaintext: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: aad(name: name)
            )
        } catch {
            throw TerminalJournalError.ioFailure("AES-GCM seal: \(error)")
        }
        guard sealed.tag.count == Self.tagBytes,
            sealed.ciphertext.count <= Int(UInt32.max) - Self.tagBytes
        else {
            throw TerminalJournalError.recordTooLarge(
                actual: sealed.ciphertext.count,
                maximum: maximumRecordBytes
            )
        }

        var output = Data()
        output.reserveCapacity(Self.headerBytes + sealed.ciphertext.count + Self.tagBytes)
        output.append(Self.magic)
        output.appendUInt16BE(Self.formatVersion)
        output.appendUInt16BE(0)
        output.append(contentsOf: nonce)
        output.appendUInt32BE(UInt32(sealed.ciphertext.count + sealed.tag.count))
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    private func readLocked(url: URL, name: String) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw TerminalJournalError.ioFailure("stat record: \(error)")
        }
        guard values.isRegularFile == true,
            let size = values.fileSize,
            size >= Self.headerBytes + Self.tagBytes,
            size <= maximumRecordBytes
        else {
            throw TerminalJournalError.malformedRecord("record size/type is invalid")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw TerminalJournalError.ioFailure("read record: \(error)")
        }
        guard data.count == size,
            data.prefix(4) == Self.magic,
            data.readUInt16BE(at: 4) == Self.formatVersion,
            data.readUInt16BE(at: 6) == 0
        else {
            throw TerminalJournalError.malformedRecord("header mismatch")
        }
        let sealedLength = Int(data.readUInt32BE(at: 20))
        guard sealedLength >= Self.tagBytes,
            sealedLength == data.count - Self.headerBytes
        else {
            throw TerminalJournalError.malformedRecord("ciphertext length mismatch")
        }

        do {
            let nonce = try AES.GCM.Nonce(data: data.subdata(in: 8..<20))
            let ciphertextEnd = data.count - Self.tagBytes
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: data.subdata(in: Self.headerBytes..<ciphertextEnd),
                tag: data.suffix(Self.tagBytes)
            )
            return try AES.GCM.open(box, using: key, authenticating: aad(name: name))
        } catch {
            throw TerminalJournalError.authenticationFailed
        }
    }

    private func aad(name: String) -> Data {
        Data("darkbloom-journal-v1\u{0}\(namespace)\u{0}\(name)".utf8)
    }

    private func recordURL(name: String) -> URL {
        recordsDirectory.appendingPathComponent("\(name).\(Self.fileExtension)")
    }

    private func reservationURL(name: String) -> URL {
        reservationsDirectory.appendingPathComponent("\(name).reserve")
    }

    private func reservationFileIsValid(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey])
        else { return false }
        return values.isRegularFile == true
            && values.fileSize == maximumRecordBytes
            && (values.fileAllocatedSize ?? 0) >= maximumRecordBytes
    }

    private func reservationNamesLocked() throws -> (
        names: Set<String>,
        invalid: Set<String>,
        staged: [String: ScannedRecord]
    ) {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: reservationsDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TerminalJournalError.ioFailure("list terminal reservations: \(error)")
        }
        var names: Set<String> = []
        var invalid: Set<String> = []
        var staged: [String: ScannedRecord] = [:]
        for url in urls {
            guard url.pathExtension == "reserve" else {
                throw TerminalJournalError.malformedRecord(
                    "invalid terminal reservation \(url.lastPathComponent)")
            }
            let name = url.deletingPathExtension().lastPathComponent
            names.insert(name)
            if reservationFileIsValid(url) {
                continue
            }
            let size = try Self.regularFileSize(url)
            if size >= Self.headerBytes + Self.tagBytes,
                size < maximumRecordBytes
            {
                // A shortened reservation can only be produced after terminal bytes
                // were file-fsynced. Authenticate it before treating it as staged.
                let plaintext = try readLocked(url: url, name: name)
                staged[name] = ScannedRecord(name: name, url: url, plaintext: plaintext)
            } else {
                invalid.insert(name)
            }
        }
        return (names, invalid, staged)
    }

    private struct QuarantineIndexEntry: Codable {
        let schema: String
        let recordName: String
        let reason: String
        let indexedAtUnixMilliseconds: Int64
    }

    private func quarantineAuthenticatedRecordLocked(name: String, reason: String) throws {
        guard recordExistsLocked(name: name) else {
            throw TerminalJournalError.malformedRecord(
                "cannot index missing authenticated record \(name)")
        }
        let marker = QuarantineIndexEntry(
            schema: "darkbloom.journal-quarantine.v1",
            recordName: name,
            reason: String(reason.prefix(1_024)),
            indexedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(marker)
        let data = try encryptLocked(name: "quarantine-index:\(name)", plaintext: plaintext)
        let target = quarantineDirectory.appendingPathComponent("\(name).qidx")
        let temporary = quarantineDirectory.appendingPathComponent(
            "\(name).qidx\(Self.tempMarker)\(UUID().uuidString)")
        try inject(.write)
        try Self.writeFile(data, to: temporary)
        try inject(.fileSync)
        try Self.syncFile(at: temporary)
        try inject(.rename)
        try Self.atomicRename(from: temporary, to: target)
        try inject(.directorySync)
        try Self.syncDirectory(quarantineDirectory)
    }

    private func quarantinedNamesLocked() throws -> (names: Set<String>, count: Int) {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TerminalJournalError.ioFailure("list quarantine: \(error)")
        }
        let decoder = JSONDecoder()
        var names: Set<String> = []
        for url in urls {
            if url.lastPathComponent.contains(Self.tempMarker) {
                continue
            }
            guard url.pathExtension == "qidx" else {
                throw TerminalJournalError.malformedRecord(
                    "unexpected quarantine index file \(url.lastPathComponent)")
            }
            let filenameName = url.deletingPathExtension().lastPathComponent
            let data = try readLocked(
                url: url,
                name: "quarantine-index:\(filenameName)"
            )
            let marker = try decoder.decode(QuarantineIndexEntry.self, from: data)
            guard marker.schema == "darkbloom.journal-quarantine.v1",
                marker.recordName == filenameName,
                recordExistsLocked(name: marker.recordName)
            else {
                throw TerminalJournalError.malformedRecord(
                    "invalid quarantine index \(url.lastPathComponent)")
            }
            names.insert(marker.recordName)
        }
        return (names, names.count)
    }

    private func recordExistsLocked(name: String) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(name: name).path)
    }

    private func sweepTempsLocked() throws {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TerminalJournalError.ioFailure("list temp records: \(error)")
        }
        var removed = false
        for url in urls where url.lastPathComponent.contains(Self.tempMarker) {
            try inject(.unlink)
            try Self.unlinkIfPresent(url)
            removed = true
        }
        if removed {
            try inject(.directorySync)
            try Self.syncDirectory(recordsDirectory)
        }
    }

    private func sweepQuarantineTempsLocked() throws {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TerminalJournalError.ioFailure(
                "list quarantine temp records: \(error)")
        }
        var removed = false
        for url in urls where url.lastPathComponent.contains(Self.tempMarker) {
            try inject(.unlink)
            try Self.unlinkIfPresent(url)
            removed = true
        }
        if removed {
            try inject(.directorySync)
            try Self.syncDirectory(quarantineDirectory)
        }
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TerminalJournalError.ioFailure("\(url.path) exists but is not a directory")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try syncDirectory(url.deletingLastPathComponent())
        } catch let error as TerminalJournalError {
            throw error
        } catch {
            throw TerminalJournalError.ioFailure("create directory \(url.path): \(error)")
        }
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        guard
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw TerminalJournalError.ioFailure("create temp file \(url.lastPathComponent)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TerminalJournalError.ioFailure("open temp file: \(error)")
        }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw TerminalJournalError.ioFailure("write/fsync temp file: \(error)")
        }
    }

    private static func regularFileSize(_ url: URL) throws -> Int {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw TerminalJournalError.ioFailure("stat \(url.lastPathComponent): \(error)")
        }
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw TerminalJournalError.malformedRecord(
                "\(url.lastPathComponent) is not a regular file")
        }
        return size
    }

    private static func sameInode(_ lhs: URL, _ rhs: URL) throws -> Bool {
        var lhsMetadata = stat()
        var rhsMetadata = stat()
        let lhsResult = lhs.path.withCString { path in lstat(path, &lhsMetadata) }
        guard lhsResult == 0 else {
            throw TerminalJournalError.systemCall(
                operation: "stat staged terminal reservation",
                errorNumber: errno
            )
        }
        let rhsResult = rhs.path.withCString { path in lstat(path, &rhsMetadata) }
        if rhsResult != 0 {
            if errno == ENOENT { return false }
            throw TerminalJournalError.systemCall(
                operation: "stat terminal record",
                errorNumber: errno
            )
        }
        return lhsMetadata.st_dev == rhsMetadata.st_dev
            && lhsMetadata.st_ino == rhsMetadata.st_ino
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = pwrite(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written,
                    off_t(written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw TerminalJournalError.systemCall(
                        operation: "write staged terminal reservation",
                        errorNumber: errno
                    )
                }
                guard result > 0 else {
                    throw TerminalJournalError.ioFailure(
                        "write staged terminal reservation made no progress")
                }
                written += result
            }
        }
    }

    private static func hardLink(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                #if canImport(Darwin)
                    Darwin.link(sourcePath, destinationPath)
                #elseif canImport(Glibc)
                    Glibc.link(sourcePath, destinationPath)
                #else
                    -1
                #endif
            }
        }
        guard result == 0 else {
            throw TerminalJournalError.systemCall(
                operation: "link staged terminal reservation",
                errorNumber: errno
            )
        }
    }

    private static func syncFile(at url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TerminalJournalError.ioFailure("open temp file for fsync: \(error)")
        }
        defer { try? handle.close() }
        try syncFileDescriptor(handle.fileDescriptor)
    }

    private func inject(_ point: JournalFaultPoint) throws {
        do {
            try faults.before(point)
        } catch let failure as JournalInjectedSystemFailure {
            throw TerminalJournalError.systemCall(
                operation: failure.point.rawValue,
                errorNumber: failure.errorNumber
            )
        }
    }

    private static func syncFileDescriptor(_ descriptor: Int32) throws {
        #if canImport(Darwin)
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else {
            throw TerminalJournalError.ioFailure(
                "fsync file failed: errno \(errno)")
        }
    }

    private static func preallocate(descriptor: Int32, byteCount: Int) throws {
        #if canImport(Darwin)
            var request = fstore_t(
                fst_flags: UInt32(F_ALLOCATECONTIG),
                fst_posmode: Int32(F_PEOFPOSMODE),
                fst_offset: 0,
                fst_length: off_t(byteCount),
                fst_bytesalloc: 0
            )
            if fcntl(descriptor, F_PREALLOCATE, &request) == -1 {
                request.fst_flags = UInt32(F_ALLOCATEALL)
                guard fcntl(descriptor, F_PREALLOCATE, &request) != -1 else {
                    throw TerminalJournalError.systemCall(
                        operation: "F_PREALLOCATE",
                        errorNumber: errno
                    )
                }
            }
            guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
                throw TerminalJournalError.systemCall(
                    operation: "ftruncate terminal reservation",
                    errorNumber: errno
                )
            }
        #elseif canImport(Glibc)
            let result = posix_fallocate(descriptor, 0, off_t(byteCount))
            guard result == 0 else {
                throw TerminalJournalError.systemCall(
                    operation: "posix_fallocate",
                    errorNumber: result
                )
            }
        #else
            guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
                throw TerminalJournalError.systemCall(
                    operation: "ftruncate terminal reservation",
                    errorNumber: errno
                )
            }
        #endif
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else {
            throw TerminalJournalError.ioFailure(
                "open directory for fsync failed: \(url.path), errno \(errno)")
        }
        defer { _ = close(descriptor) }
        #if canImport(Darwin)
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else {
            throw TerminalJournalError.ioFailure(
                "fsync directory failed: \(url.path), errno \(errno)")
        }
    }

    private static func atomicRename(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                #if canImport(Darwin)
                    Darwin.rename(sourcePath, destinationPath)
                #elseif canImport(Glibc)
                    Glibc.rename(sourcePath, destinationPath)
                #else
                    -1
                #endif
            }
        }
        guard result == 0 else {
            throw TerminalJournalError.ioFailure(
                "rename \(source.lastPathComponent) -> \(destination.lastPathComponent) failed: errno \(errno)"
            )
        }
    }

    private static func unlinkIfPresent(_ url: URL) throws {
        let result = url.path.withCString { path in
            #if canImport(Darwin)
                Darwin.unlink(path)
            #elseif canImport(Glibc)
                Glibc.unlink(path)
            #else
                -1
            #endif
        }
        if result == 0 || errno == ENOENT { return }
        throw TerminalJournalError.ioFailure(
            "unlink \(url.lastPathComponent) failed: errno \(errno)")
    }
}

extension Data {
    fileprivate mutating func appendUInt16BE(_ value: UInt16) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendUInt32BE(_ value: UInt32) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    fileprivate func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(self[index(startIndex, offsetBy: offset)]) << 8)
            | UInt16(self[index(startIndex, offsetBy: offset + 1)])
    }

    fileprivate func readUInt32BE(at offset: Int) -> UInt32 {
        (UInt32(self[index(startIndex, offsetBy: offset)]) << 24)
            | (UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 16)
            | (UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 8)
            | UInt32(self[index(startIndex, offsetBy: offset + 3)])
    }
}
