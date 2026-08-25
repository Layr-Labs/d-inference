import Foundation

/// Bounds shared with the coordinator and shell installer. The current signed
/// release is about 170 MiB compressed and comfortably below 1 GiB as a
/// decompressed tar stream; this envelope leaves substantial app-growth and
/// flat-verifier headroom while bounding disk, stream expansion, inode,
/// parser-memory, and path-complexity exposure.
struct ReleaseArchivePolicy: Sendable {
    static let maxCompressedBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maxExpandedBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let maxEntries = 16 * 1024
    static let maxPathBytes = 4 * 1024
    static let maxComponentBytes = 255
    static let maxMetadataBytes: UInt64 = 1024 * 1024

    static let defaultPolicy = ReleaseArchivePolicy(
        maxCompressedBytes: maxCompressedBytes,
        maxExpandedBytes: maxExpandedBytes,
        maxEntries: maxEntries,
        maxPathBytes: maxPathBytes,
        maxComponentBytes: maxComponentBytes,
        maxMetadataBytes: maxMetadataBytes
    )

    let maxCompressedBytes: UInt64
    let maxExpandedBytes: UInt64
    let maxEntries: Int
    let maxPathBytes: Int
    let maxComponentBytes: Int
    let maxMetadataBytes: UInt64

    func validate() throws {
        guard maxEntries > 0,
              maxPathBytes > 0,
              maxComponentBytes > 0
        else {
            throw ReleaseArchivePreflightError("invalid release archive policy")
        }
    }
}

struct ReleaseArchivePreflightError: LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}

enum ReleaseArchivePreflight {
    fileprivate static let blockSize = 512
    private static let gzipExecutable = URL(fileURLWithPath: "/usr/bin/gzip")

    static func validate(
        _ archive: URL,
        policy: ReleaseArchivePolicy = .defaultPolicy
    ) throws {
        try policy.validate()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        } catch {
            throw ReleaseArchivePreflightError(
                "could not inspect release archive: \(error.localizedDescription)")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            throw ReleaseArchivePreflightError(
                "release archive must be a regular file")
        }
        guard size.uint64Value <= policy.maxCompressedBytes else {
            throw ReleaseArchivePreflightError(
                "release archive exceeds the \(policy.maxCompressedBytes)-byte compressed-size limit")
        }
        guard FileManager.default.isExecutableFile(
            atPath: gzipExecutable.path)
        else {
            throw ReleaseArchivePreflightError(
                "system gzip is unavailable at \(gzipExecutable.path)")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = gzipExecutable
        process.arguments = ["-dc", "--", archive.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ReleaseArchivePreflightError(
                "could not start release archive decompression: \(error.localizedDescription)")
        }

        let readHandle = output.fileHandleForReading
        defer {
            try? readHandle.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let stream = ReleaseArchiveByteStream(readHandle)
        try ReleaseTarValidator(stream: stream, policy: policy).validate()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            throw ReleaseArchivePreflightError(
                "release archive gzip stream is corrupt or truncated")
        }
    }
}

private final class ReleaseArchiveByteStream {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readExactly(
        _ count: Int,
        allowingEndOfFile: Bool = false
    ) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let next: Data
            do {
                next = try handle.read(
                    upToCount: count - result.count) ?? Data()
            } catch {
                throw ReleaseArchivePreflightError(
                    "could not read release archive: \(error.localizedDescription)")
            }
            if next.isEmpty {
                if result.isEmpty && allowingEndOfFile {
                    return nil
                }
                throw ReleaseArchivePreflightError(
                    "release archive contains truncated tar data")
            }
            result.append(next)
        }
        return result
    }

    func skip(_ count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 64 * 1024))
            _ = try readExactly(chunkSize)
            remaining -= UInt64(chunkSize)
        }
    }

    func readChunk(maxCount: Int) throws -> Data? {
        do {
            let data = try handle.read(upToCount: maxCount) ?? Data()
            return data.isEmpty ? nil : data
        } catch {
            throw ReleaseArchivePreflightError(
                "could not read release archive trailer: \(error.localizedDescription)")
        }
    }
}

private enum ReleaseArchiveNodeKind {
    case regular
    case directory
}

private struct ReleaseArchivePendingMetadata {
    var path: String?
    var size: UInt64?
}

private final class ReleaseArchivePathTracker {
    private var nodes: [String: ReleaseArchiveNodeKind] = [:]
    private var pathsWithDescendants = Set<String>()

    func add(_ path: String, kind: ReleaseArchiveNodeKind) throws {
        let key = foldASCII(path)
        if key == ".", kind != .directory {
            throw ReleaseArchivePreflightError(
                "release archive root entry must be a directory")
        }
        guard nodes[key] == nil else {
            throw ReleaseArchivePreflightError(
                "release archive contains duplicate or case-conflicting path \(path)")
        }
        if kind == .regular, pathsWithDescendants.contains(key) {
            throw ReleaseArchivePreflightError(
                "release archive file \(path) conflicts with descendant entries")
        }

        if key != "." {
            let components = key.split(
                separator: "/",
                omittingEmptySubsequences: false)
            if components.count > 1 {
                for end in 1..<components.count {
                    let ancestor = components[..<end].joined(separator: "/")
                    if let existing = nodes[ancestor],
                       existing != .directory
                    {
                        throw ReleaseArchivePreflightError(
                            "release archive path \(path) descends through file \(ancestor)")
                    }
                    pathsWithDescendants.insert(ancestor)
                }
            }
        }
        nodes[key] = kind
    }

    private func foldASCII(_ value: String) -> String {
        let bytes = value.utf8.map { byte -> UInt8 in
            if byte >= 65, byte <= 90 {
                return byte + 32
            }
            return byte
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private final class ReleaseTarValidator {
    private let stream: ReleaseArchiveByteStream
    private let policy: ReleaseArchivePolicy
    private let pathTracker = ReleaseArchivePathTracker()
    private var pending = ReleaseArchivePendingMetadata()
    private var expandedBytes: UInt64 = 0
    private var entryCount = 0

    init(
        stream: ReleaseArchiveByteStream,
        policy: ReleaseArchivePolicy
    ) {
        self.stream = stream
        self.policy = policy
    }

    func validate() throws {
        while true {
            guard let blockData = try stream.readExactly(
                ReleaseArchivePreflight.blockSize,
                allowingEndOfFile: true)
            else {
                throw ReleaseArchivePreflightError(
                    "release archive is missing the tar end marker")
            }
            try addExpandedBytes(
                UInt64(ReleaseArchivePreflight.blockSize))
            let header = [UInt8](blockData)
            if header.allSatisfy({ $0 == 0 }) {
                try validateEndMarker()
                return
            }

            entryCount += 1
            guard entryCount <= policy.maxEntries else {
                throw ReleaseArchivePreflightError(
                    "release archive exceeds the \(policy.maxEntries)-entry limit")
            }
            try validateChecksum(header)

            let headerPath = try tarHeaderPath(header)
            _ = try cleanPath(headerPath)
            let headerMode = try parseTarNumber(
                Array(header[100..<108]),
                label: "entry mode")
            guard headerMode <= 0o777 else {
                throw ReleaseArchivePreflightError(
                    "release archive entry mode exceeds portable permission bits")
            }
            let headerSize = try parseTarNumber(
                Array(header[124..<136]),
                label: "entry size")
            let typeflag = header[156]

            switch typeflag {
            case 120: // x: per-entry PAX metadata
                let payload = try readMetadata(
                    size: headerSize,
                    label: "PAX")
                try merge(parsePAX(payload))
                continue
            case 103: // g: global PAX metadata
                let payload = try readMetadata(
                    size: headerSize,
                    label: "global PAX")
                let attributes = try parsePAX(payload)
                guard attributes.path == nil,
                      attributes.size == nil
                else {
                    throw ReleaseArchivePreflightError(
                        "release archive global PAX metadata must not override path or size")
                }
                continue
            case 76: // L: GNU long name
                var payload = try readMetadata(
                    size: headerSize,
                    label: "GNU long-name")
                while payload.last == 0 || payload.last == 10 {
                    payload.removeLast()
                }
                try mergePath(try cleanPath(payload))
                continue
            case 75: // K: GNU long link
                throw ReleaseArchivePreflightError(
                    "release archive contains unsupported GNU long-link metadata")
            default:
                break
            }

            let effectivePath: String
            if let metadataPath = pending.path {
                effectivePath = metadataPath
            } else {
                effectivePath = try cleanPath(headerPath)
            }
            let effectiveSize = pending.size ?? headerSize
            pending = ReleaseArchivePendingMetadata()

            let kind: ReleaseArchiveNodeKind
            switch typeflag {
            case 0, 48:
                kind = .regular
            case 53:
                kind = .directory
                guard effectiveSize == 0 else {
                    throw ReleaseArchivePreflightError(
                        "release archive directory \(effectivePath) has a non-zero size")
                }
            default:
                throw ReleaseArchivePreflightError(
                    String(
                        format:
                            "release archive entry %@ uses unsupported node type 0x%02x",
                        effectivePath,
                        typeflag))
            }

            if kind == .regular,
               let mismatch = UpdateArtifactModes.archiveModeMismatch(
                   path: effectivePath,
                   actual: headerMode)
            {
                throw ReleaseArchivePreflightError(mismatch)
            }
            try pathTracker.add(effectivePath, kind: kind)
            try addTarPayloadBytes(effectiveSize)
            try stream.skip(effectiveSize)
            try skipPadding(for: effectiveSize)
        }
    }

    private func validateEndMarker() throws {
        guard pending.path == nil, pending.size == nil else {
            throw ReleaseArchivePreflightError(
                "release archive ends with dangling path or size metadata")
        }
        guard let second = try stream.readExactly(
            ReleaseArchivePreflight.blockSize)
        else {
            throw ReleaseArchivePreflightError(
                "release archive is missing the second tar end marker")
        }
        try addExpandedBytes(UInt64(ReleaseArchivePreflight.blockSize))
        guard second.allSatisfy({ $0 == 0 }) else {
            throw ReleaseArchivePreflightError(
                "release archive has an incomplete tar end marker")
        }

        var trailingBytes: UInt64 = 0
        while let chunk = try stream.readChunk(maxCount: 32 * 1024) {
            guard chunk.allSatisfy({ $0 == 0 }) else {
                throw ReleaseArchivePreflightError(
                    "release archive contains non-zero data after the tar end marker")
            }
            try addExpandedBytes(UInt64(chunk.count))
            let (next, overflow) = trailingBytes.addingReportingOverflow(
                UInt64(chunk.count))
            guard !overflow else {
                throw ReleaseArchivePreflightError(
                    "release archive trailer length overflows UInt64")
            }
            trailingBytes = next
        }
        guard trailingBytes % UInt64(ReleaseArchivePreflight.blockSize) == 0 else {
            throw ReleaseArchivePreflightError(
                "release archive trailer is not block-aligned")
        }
    }

    private func validateChecksum(_ header: [UInt8]) throws {
        let stored = try parseOctal(
            Array(header[148..<156]),
            label: "header checksum")
        var sum: UInt64 = 0
        for (index, byte) in header.enumerated() {
            sum += UInt64(index >= 148 && index < 156 ? 32 : byte)
        }
        guard stored == sum else {
            throw ReleaseArchivePreflightError(
                "release archive contains a tar header with an invalid checksum")
        }
    }

    private func tarHeaderPath(_ header: [UInt8]) throws -> [UInt8] {
        let name = try tarString(Array(header[0..<100]), label: "name")
        let prefix = try tarString(Array(header[345..<500]), label: "prefix")
        guard !prefix.isEmpty else { return name }
        guard Array(header[257..<263]).starts(with: Array("ustar".utf8)) else {
            throw ReleaseArchivePreflightError(
                "release archive uses a tar prefix without a USTAR header")
        }
        return prefix + [47] + name
    }

    private func tarString(
        _ field: [UInt8],
        label: String
    ) throws -> [UInt8] {
        guard let nul = field.firstIndex(of: 0) else { return field }
        guard field[(nul + 1)...].allSatisfy({ $0 == 0 }) else {
            throw ReleaseArchivePreflightError(
                "release archive contains non-zero padding in its tar \(label) field")
        }
        return Array(field[..<nul])
    }

    private func parseTarNumber(
        _ field: [UInt8],
        label: String
    ) throws -> UInt64 {
        guard let first = field.first else {
            throw ReleaseArchivePreflightError(
                "release archive \(label) is empty")
        }
        guard first & 0x80 != 0 else {
            return try parseOctal(field, label: label)
        }
        guard first & 0x40 == 0 else {
            throw ReleaseArchivePreflightError(
                "release archive \(label) is negative")
        }

        var value = UInt64(first & 0x3f)
        for byte in field.dropFirst() {
            let (multiplied, multiplyOverflow) =
                value.multipliedReportingOverflow(by: 256)
            let (next, addOverflow) =
                multiplied.addingReportingOverflow(UInt64(byte))
            guard !multiplyOverflow,
                  !addOverflow,
                  next <= UInt64(Int64.max)
            else {
                throw ReleaseArchivePreflightError(
                    "release archive \(label) overflows Int64")
            }
            value = next
        }
        return value
    }

    private func parseOctal(
        _ field: [UInt8],
        label: String
    ) throws -> UInt64 {
        var start = 0
        while start < field.count,
              field[start] == 0 || field[start] == 32
        {
            start += 1
        }
        var end = field.count
        while end > start,
              field[end - 1] == 0 || field[end - 1] == 32
        {
            end -= 1
        }
        guard start < end else { return 0 }

        var value: UInt64 = 0
        for byte in field[start..<end] {
            guard byte >= 48, byte <= 55 else {
                throw ReleaseArchivePreflightError(
                    "release archive \(label) is not valid octal")
            }
            value = value * 8 + UInt64(byte - 48)
        }
        return value
    }

    private func readMetadata(
        size: UInt64,
        label: String
    ) throws -> [UInt8] {
        guard size <= policy.maxMetadataBytes,
              size <= UInt64(Int.max)
        else {
            throw ReleaseArchivePreflightError(
                "release archive \(label) metadata exceeds the \(policy.maxMetadataBytes)-byte limit")
        }
        try addTarPayloadBytes(size)
        guard let payload = try stream.readExactly(Int(size)) else {
            throw ReleaseArchivePreflightError(
                "release archive contains truncated \(label) metadata")
        }
        try skipPadding(for: size)
        return [UInt8](payload)
    }

    private func parsePAX(
        _ payload: [UInt8]
    ) throws -> ReleaseArchivePendingMetadata {
        var attributes = ReleaseArchivePendingMetadata()
        var seen = Set<String>()
        var offset = 0

        while offset < payload.count {
            guard let relativeSpace = payload[offset...].firstIndex(of: 32),
                  relativeSpace > offset
            else {
                throw ReleaseArchivePreflightError(
                    "release archive contains malformed PAX metadata")
            }
            let length = try parseDecimal(
                Array(payload[offset..<relativeSpace]),
                limit: UInt64(payload.count - offset),
                label: "PAX record length")
            let prefixLength = relativeSpace - offset + 1
            guard length > UInt64(prefixLength),
                  length <= UInt64(payload.count - offset),
                  length <= UInt64(Int.max)
            else {
                throw ReleaseArchivePreflightError(
                    "release archive contains an invalid PAX record length")
            }
            let recordEnd = offset + Int(length)
            guard payload[recordEnd - 1] == 10 else {
                throw ReleaseArchivePreflightError(
                    "release archive PAX record is missing its newline terminator")
            }
            let body = Array(payload[(relativeSpace + 1)..<(recordEnd - 1)])
            guard let equals = body.firstIndex(of: 61),
                  equals > 0
            else {
                throw ReleaseArchivePreflightError(
                    "release archive contains a malformed PAX key/value record")
            }
            let keyBytes = Array(body[..<equals])
            guard keyBytes.allSatisfy({
                $0 >= 0x21 && $0 <= 0x7e && $0 != 61
            }) else {
                throw ReleaseArchivePreflightError(
                    "release archive contains an invalid PAX key")
            }
            let key = String(decoding: keyBytes, as: UTF8.self)
            guard seen.insert(key).inserted else {
                throw ReleaseArchivePreflightError(
                    "release archive repeats PAX key \(key)")
            }
            let value = Array(body[(equals + 1)...])

            if isSparsePAXKey(key) {
                throw ReleaseArchivePreflightError(
                    "release archive contains unsupported sparse PAX metadata \(key)")
            }
            switch key {
            case "path":
                attributes.path = try cleanPath(value)
            case "linkpath":
                _ = try cleanPath(value)
            case "size":
                attributes.size = try parseDecimal(
                    value,
                    limit: UInt64(Int64.max),
                    label: "PAX size")
            case "SCHILY.filetype":
                throw ReleaseArchivePreflightError(
                    "release archive contains unsupported PAX file-type metadata")
            case "SCHILY.mode":
                throw ReleaseArchivePreflightError(
                    "release archive contains unsupported PAX mode metadata")
            default:
                break
            }
            offset = recordEnd
        }
        return attributes
    }

    private func isSparsePAXKey(_ key: String) -> Bool {
        key == "GNU.sparse"
            || key.hasPrefix("GNU.sparse.")
            || key == "SCHILY.realsize"
            || key == "SUN.holesdata"
            || key.hasPrefix("LIBARCHIVE.sparse")
    }

    private func parseDecimal(
        _ bytes: [UInt8],
        limit: UInt64,
        label: String
    ) throws -> UInt64 {
        guard !bytes.isEmpty else {
            throw ReleaseArchivePreflightError(
                "release archive \(label) is empty")
        }
        var value: UInt64 = 0
        for byte in bytes {
            guard byte >= 48, byte <= 57 else {
                throw ReleaseArchivePreflightError(
                    "release archive \(label) is not an unsigned decimal integer")
            }
            let digit = UInt64(byte - 48)
            guard digit <= limit,
                  value <= (limit - digit) / 10
            else {
                throw ReleaseArchivePreflightError(
                    "release archive \(label) overflows its supported range")
            }
            value = value * 10 + digit
        }
        return value
    }

    private func merge(_ attributes: ReleaseArchivePendingMetadata) throws {
        if let path = attributes.path {
            try mergePath(path)
        }
        if let size = attributes.size {
            if let existing = pending.size, existing != size {
                throw ReleaseArchivePreflightError(
                    "release archive contains conflicting size metadata")
            }
            pending.size = size
        }
    }

    private func mergePath(_ path: String) throws {
        if let existing = pending.path, existing != path {
            throw ReleaseArchivePreflightError(
                "release archive contains conflicting path metadata")
        }
        pending.path = path
    }

    private func cleanPath(_ bytes: [UInt8]) throws -> String {
        guard !bytes.isEmpty else {
            throw ReleaseArchivePreflightError(
                "release archive path is empty")
        }
        guard bytes.count <= policy.maxPathBytes else {
            throw ReleaseArchivePreflightError(
                "release archive path exceeds the \(policy.maxPathBytes)-byte limit")
        }
        guard bytes.first != 47 else {
            throw ReleaseArchivePreflightError(
                "release archive path is absolute")
        }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw ReleaseArchivePreflightError(
                "release archive path contains non-portable bytes")
        }
        guard !bytes.contains(92) else {
            throw ReleaseArchivePreflightError(
                "release archive path contains a backslash")
        }

        let raw = String(decoding: bytes, as: UTF8.self)
        var cleaned: [Substring] = []
        for component in raw.split(
            separator: "/",
            omittingEmptySubsequences: false)
        {
            if component.isEmpty || component == "." {
                continue
            }
            guard component != ".." else {
                throw ReleaseArchivePreflightError(
                    "release archive path contains parent traversal")
            }
            guard component.utf8.count <= policy.maxComponentBytes else {
                throw ReleaseArchivePreflightError(
                    "release archive path component exceeds the \(policy.maxComponentBytes)-byte limit")
            }
            cleaned.append(component)
        }
        let result = cleaned.isEmpty ? "." : cleaned.joined(separator: "/")
        guard result.utf8.count <= policy.maxPathBytes else {
            throw ReleaseArchivePreflightError(
                "release archive normalized path exceeds the \(policy.maxPathBytes)-byte limit")
        }
        return result
    }

    private func cleanPath(_ string: String) throws -> String {
        try cleanPath(Array(string.utf8))
    }

    private func addExpandedBytes(_ size: UInt64) throws {
        let (next, overflow) = expandedBytes.addingReportingOverflow(size)
        guard !overflow,
              size <= policy.maxExpandedBytes,
              next <= policy.maxExpandedBytes
        else {
            throw ReleaseArchivePreflightError(
                "release archive exceeds the \(policy.maxExpandedBytes)-byte expanded-size limit")
        }
        expandedBytes = next
    }

    private func addTarPayloadBytes(_ size: UInt64) throws {
        let blockSize = UInt64(ReleaseArchivePreflight.blockSize)
        let padding = (blockSize - size % blockSize) % blockSize
        let (physicalSize, overflow) = size.addingReportingOverflow(padding)
        guard !overflow else {
            throw ReleaseArchivePreflightError(
                "release archive entry size overflows UInt64")
        }
        try addExpandedBytes(physicalSize)
    }

    private func skipPadding(for size: UInt64) throws {
        let blockSize = UInt64(ReleaseArchivePreflight.blockSize)
        let padding = (blockSize - size % blockSize) % blockSize
        try stream.skip(padding)
    }
}
