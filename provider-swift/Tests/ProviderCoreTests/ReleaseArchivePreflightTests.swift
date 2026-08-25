import Foundation
import Testing
@testable import ProviderCore

@Suite("Release archive preflight")
struct ReleaseArchivePreflightTests {
    @Test("accepts portable entries and GNU long names")
    func acceptsPortableArchive() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let longPath = "Darkbloom.app/Contents/Resources/"
            + String(repeating: "long-name-", count: 20)
        let archive = try fixture.writeArchive(
            named: "valid",
            entries: [
                .init(name: "./", typeflag: 53),
                .init(name: "./bin/", typeflag: 53),
                .init(name: "./bin/darkbloom", body: Data("binary".utf8)),
                .init(
                    name: "././@LongLink",
                    typeflag: 76,
                    body: Data(longPath.utf8) + Data([0])),
                .init(name: "placeholder", body: Data("resource".utf8)),
            ])

        try ReleaseArchivePreflight.validate(archive)
    }

    @Test("rejects unsafe aliases and file-directory conflicts")
    func rejectsUnsafePaths() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let cases: [(String, [RawTarEntry], String)] = [
            (
                "absolute",
                [.init(name: "/tmp/escape")],
                "absolute"
            ),
            (
                "traversal",
                [.init(name: "bin/../escape")],
                "parent traversal"
            ),
            (
                "backslash",
                [.init(name: #"bin\darkbloom"#)],
                "backslash"
            ),
            (
                "duplicate",
                [
                    .init(name: "./bin/darkbloom"),
                    .init(name: "bin/darkbloom"),
                ],
                "duplicate"
            ),
            (
                "case-conflict",
                [
                    .init(name: "bin/Darkbloom"),
                    .init(name: "bin/darkbloom"),
                ],
                "case-conflicting"
            ),
            (
                "file-ancestor",
                [
                    .init(name: "Darkbloom.app"),
                    .init(name: "Darkbloom.app/Contents/file"),
                ],
                "descends through file"
            ),
            (
                "file-after-child",
                [
                    .init(name: "Darkbloom.app/Contents/file"),
                    .init(name: "Darkbloom.app"),
                ],
                "conflicts with descendant"
            ),
        ]

        for (name, entries, expected) in cases {
            let archive = try fixture.writeArchive(
                named: name,
                entries: entries)
            expectPreflightFailure(archive, contains: expected)
        }
    }

    @Test("rejects links devices FIFOs and sparse node headers")
    func rejectsUnsupportedNodeTypes() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let types: [(String, UInt8)] = [
            ("hard-link", 49),
            ("symlink", 50),
            ("character-device", 51),
            ("block-device", 52),
            ("fifo", 54),
            ("contiguous", 55),
            ("gnu-sparse", 83),
        ]

        for (name, typeflag) in types {
            let archive = try fixture.writeArchive(
                named: name,
                entries: [
                    .init(name: "dangerous", typeflag: typeflag),
                ])
            expectPreflightFailure(
                archive,
                contains: "unsupported node type")
        }
    }

    @Test("rejects huge sparse-style headers before reading file data")
    func rejectsHugeHeaderWithoutAllocation() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let oversized = ReleaseArchivePolicy.maxExpandedBytes + 1
        let sizeField = Data(
            String(format: "%011llo", oversized).utf8) + Data([0])
        let archive = try fixture.writeArchive(
            named: "huge-header",
            entries: [
                .init(
                    name: "large-sparse-payload",
                    rawSizeField: sizeField,
                    omitBodyAndPadding: true),
            ])

        let compressedSize = try #require(
            FileManager.default.attributesOfItem(
                atPath: archive.path)[.size] as? NSNumber
        )
        #expect(compressedSize.uint64Value < 4096)
        expectPreflightFailure(
            archive,
            contains: "expanded-size limit")
    }

    @Test("rejects negative and overflowing base-256 sizes")
    func rejectsInvalidBase256Sizes() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let cases: [(String, Data, String)] = [
            (
                "negative",
                Data(repeating: 0xff, count: 12),
                "negative"
            ),
            (
                "overflow",
                Data([0x80] + Array(repeating: 0xff, count: 11)),
                "overflows Int64"
            ),
        ]

        for (name, sizeField, expected) in cases {
            let archive = try fixture.writeArchive(
                named: name,
                entries: [
                    .init(
                        name: "invalid-size",
                        rawSizeField: sizeField,
                        omitBodyAndPadding: true),
                ])
            expectPreflightFailure(archive, contains: expected)
        }
    }

    @Test("rejects sparse and overflowing PAX size metadata")
    func rejectsDangerousPAXMetadata() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let cases: [(String, String, String, String)] = [
            (
                "sparse",
                "GNU.sparse.realsize",
                "4294967297",
                "unsupported sparse PAX metadata"
            ),
            (
                "sun-sparse",
                "SUN.holesdata",
                "0 4096",
                "unsupported sparse PAX metadata"
            ),
            (
                "overflow",
                "size",
                String(repeating: "9", count: 40),
                "overflows"
            ),
            (
                "mode",
                "SCHILY.mode",
                "0000755",
                "unsupported PAX mode metadata"
            ),
        ]

        for (name, key, value, expected) in cases {
            let archive = try fixture.writeArchive(
                named: "pax-\(name)",
                entries: [
                    .init(
                        name: "PaxHeaders/file",
                        typeflag: 120,
                        body: paxRecord(key: key, value: value)),
                    .init(name: "file"),
                ])
            expectPreflightFailure(archive, contains: expected)
        }
    }

    @Test("binds exact release payload modes from tar headers")
    func bindsExactReleasePayloadModes() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let cases: [(String, String, UInt32, String)] = [
            ("flat-binary", "bin/darkbloom", 0o775, "expected 0755"),
            (
                "app-enclave",
                "Darkbloom.app/Contents/MacOS/darkbloom-enclave",
                0o700,
                "expected 0755"
            ),
            ("root-metallib", "mlx.metallib", 0o755, "expected 0644"),
        ]

        for (name, path, mode, expected) in cases {
            let archive = try fixture.writeArchive(
                named: name,
                entries: [
                    .init(
                        name: path,
                        body: Data("payload".utf8),
                        mode: mode
                    ),
                ])
            expectPreflightFailure(archive, contains: expected)
        }
    }

    @Test("enforces aggregate expanded bytes and physical header count")
    func enforcesAggregateLimits() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }

        let expandedArchive = try fixture.writeArchive(
            named: "expanded-count",
            entries: [
                .init(name: "first", body: Data("12345678".utf8)),
                .init(name: "second", body: Data("abcdefgh".utf8)),
            ])
        var policy = testPolicy()
        policy = ReleaseArchivePolicy(
            maxCompressedBytes: policy.maxCompressedBytes,
            // Two headers and two padded payload regions consume 2048
            // bytes before the end markers.
            maxExpandedBytes: 4 * 512 - 1,
            maxEntries: policy.maxEntries,
            maxPathBytes: policy.maxPathBytes,
            maxComponentBytes: policy.maxComponentBytes,
            maxMetadataBytes: policy.maxMetadataBytes)
        expectPreflightFailure(
            expandedArchive,
            policy: policy,
            contains: "expanded-size limit")

        let entryArchive = try fixture.writeArchive(
            named: "entry-count",
            entries: [
                .init(name: "one"),
                .init(name: "two"),
                .init(name: "three"),
            ])
        let entryPolicy = ReleaseArchivePolicy(
            maxCompressedBytes: ReleaseArchivePolicy.maxCompressedBytes,
            maxExpandedBytes: ReleaseArchivePolicy.maxExpandedBytes,
            maxEntries: 2,
            maxPathBytes: ReleaseArchivePolicy.maxPathBytes,
            maxComponentBytes: ReleaseArchivePolicy.maxComponentBytes,
            maxMetadataBytes: ReleaseArchivePolicy.maxMetadataBytes)
        expectPreflightFailure(
            entryArchive,
            policy: entryPolicy,
            contains: "entry limit")

        let paxArchive = try fixture.writeArchive(
            named: "pax-entry-count",
            entries: [
                .init(
                    name: "PaxHeaders/file",
                    typeflag: 120,
                    body: paxRecord(key: "path", value: "renamed")),
                .init(name: "placeholder"),
            ])
        let oneEntryPolicy = ReleaseArchivePolicy(
            maxCompressedBytes: ReleaseArchivePolicy.maxCompressedBytes,
            maxExpandedBytes: ReleaseArchivePolicy.maxExpandedBytes,
            maxEntries: 1,
            maxPathBytes: ReleaseArchivePolicy.maxPathBytes,
            maxComponentBytes: ReleaseArchivePolicy.maxComponentBytes,
            maxMetadataBytes: ReleaseArchivePolicy.maxMetadataBytes)
        expectPreflightFailure(
            paxArchive,
            policy: oneEntryPolicy,
            contains: "entry limit")
    }

    @Test("zero trailer bytes share the expanded archive budget")
    func enforcesExpandedLimitOnZeroTrailer() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let blockSize = 512
        var raw = rawTarArchive([
            .init(name: "empty"),
        ])
        raw.append(
            Data(
                repeating: 0,
                count: 2 * blockSize
            )
        )
        let archive = try fixture.writeRawArchive(
            named: "oversized-zero-trailer",
            raw: raw
        )
        let policy = ReleaseArchivePolicy(
            maxCompressedBytes: ReleaseArchivePolicy.maxCompressedBytes,
            // One empty-file header plus both required end markers.
            maxExpandedBytes: UInt64(3 * blockSize),
            maxEntries: ReleaseArchivePolicy.maxEntries,
            maxPathBytes: ReleaseArchivePolicy.maxPathBytes,
            maxComponentBytes: ReleaseArchivePolicy.maxComponentBytes,
            maxMetadataBytes: ReleaseArchivePolicy.maxMetadataBytes
        )

        expectPreflightFailure(
            archive,
            policy: policy,
            contains: "expanded-size limit"
        )
    }

    @Test("rejects malformed checksum trailer and gzip stream")
    func rejectsMalformedArchive() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }

        var badChecksumRaw = rawTarArchive([
            .init(name: "file"),
        ])
        badChecksumRaw[0] ^= 1
        let badChecksum = try fixture.writeRawArchive(
            named: "bad-checksum",
            raw: badChecksumRaw)
        expectPreflightFailure(
            badChecksum,
            contains: "invalid checksum")

        var trailingRaw = rawTarArchive([
            .init(name: "file"),
        ])
        trailingRaw.append(Data(repeating: 1, count: 512))
        let trailing = try fixture.writeRawArchive(
            named: "trailing",
            raw: trailingRaw)
        expectPreflightFailure(
            trailing,
            contains: "non-zero data")

        let corrupt = try fixture.writeArchive(
            named: "corrupt-gzip",
            entries: [.init(name: "file")])
        var corruptBytes = try Data(contentsOf: corrupt)
        corruptBytes[corruptBytes.count - 1] ^= 1
        try corruptBytes.write(to: corrupt)
        expectPreflightFailure(
            corrupt,
            contains: "gzip stream is corrupt")
    }

    @Test("enforces compressed archive bytes")
    func enforcesCompressedLimit() throws {
        let fixture = try ArchivePreflightFixture()
        defer { fixture.remove() }
        let archive = try fixture.writeArchive(
            named: "compressed",
            entries: [.init(name: "file")])
        let policy = ReleaseArchivePolicy(
            maxCompressedBytes: 1,
            maxExpandedBytes: ReleaseArchivePolicy.maxExpandedBytes,
            maxEntries: ReleaseArchivePolicy.maxEntries,
            maxPathBytes: ReleaseArchivePolicy.maxPathBytes,
            maxComponentBytes: ReleaseArchivePolicy.maxComponentBytes,
            maxMetadataBytes: ReleaseArchivePolicy.maxMetadataBytes)

        expectPreflightFailure(
            archive,
            policy: policy,
            contains: "compressed-size limit")
    }
}

private struct RawTarEntry {
    let name: String
    let typeflag: UInt8
    let body: Data
    let mode: UInt32
    let rawSizeField: Data?
    let omitBodyAndPadding: Bool

    init(
        name: String,
        typeflag: UInt8 = 48,
        body: Data = Data(),
        mode: UInt32 = 0o755,
        rawSizeField: Data? = nil,
        omitBodyAndPadding: Bool = false
    ) {
        self.name = name
        self.typeflag = typeflag
        self.body = body
        self.mode = mode
        self.rawSizeField = rawSizeField
        self.omitBodyAndPadding = omitBodyAndPadding
    }
}

private final class ArchivePreflightFixture {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "release-archive-preflight-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeArchive(
        named name: String,
        entries: [RawTarEntry]
    ) throws -> URL {
        try writeRawArchive(
            named: name,
            raw: rawTarArchive(entries))
    }

    func writeRawArchive(
        named name: String,
        raw: Data
    ) throws -> URL {
        let source = root.appendingPathComponent("\(name).tar")
        let archive = root.appendingPathComponent("\(name).tar.gz")
        try raw.write(to: source)
        _ = FileManager.default.createFile(
            atPath: archive.path,
            contents: Data())
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", "--", source.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        return archive
    }
}

private func expectPreflightFailure(
    _ archive: URL,
    policy: ReleaseArchivePolicy = .defaultPolicy,
    contains expected: String
) {
    do {
        try ReleaseArchivePreflight.validate(archive, policy: policy)
        Issue.record("archive unexpectedly passed preflight: \(archive.lastPathComponent)")
    } catch {
        #expect("\(error)".contains(expected))
    }
}

private func testPolicy() -> ReleaseArchivePolicy {
    .defaultPolicy
}

private func rawTarArchive(_ entries: [RawTarEntry]) -> Data {
    var output = Data()
    for entry in entries {
        output.append(tarHeader(entry))
        if entry.omitBodyAndPadding {
            continue
        }
        output.append(entry.body)
        let padding = (512 - entry.body.count % 512) % 512
        output.append(Data(repeating: 0, count: padding))
    }
    output.append(Data(repeating: 0, count: 1024))
    return output
}

private func tarHeader(_ entry: RawTarEntry) -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    write(Array(entry.name.utf8), into: &header, at: 0, count: 100)
    write(
        Array(String(format: "%07o\0", entry.mode).utf8),
        into: &header,
        at: 100,
        count: 8
    )
    write(Array("0000000\0".utf8), into: &header, at: 108, count: 8)
    write(Array("0000000\0".utf8), into: &header, at: 116, count: 8)
    let sizeField = entry.rawSizeField
        ?? Data(String(format: "%011o", entry.body.count).utf8) + Data([0])
    write([UInt8](sizeField), into: &header, at: 124, count: 12)
    write(Array("00000000000\0".utf8), into: &header, at: 136, count: 12)
    for index in 148..<156 {
        header[index] = 32
    }
    header[156] = entry.typeflag
    write(Array("ustar\0".utf8), into: &header, at: 257, count: 6)
    write(Array("00".utf8), into: &header, at: 263, count: 2)

    let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
    write(
        Array(String(format: "%06llo\0 ", checksum).utf8),
        into: &header,
        at: 148,
        count: 8)
    return Data(header)
}

private func write(
    _ source: [UInt8],
    into destination: inout [UInt8],
    at offset: Int,
    count: Int
) {
    precondition(source.count <= count)
    for (index, byte) in source.enumerated() {
        destination[offset + index] = byte
    }
}

private func paxRecord(key: String, value: String) -> Data {
    let body = "\(key)=\(value)\n"
    var length = body.utf8.count + 2
    while true {
        let record = "\(length) \(body)"
        if record.utf8.count == length {
            return Data(record.utf8)
        }
        length = record.utf8.count
    }
}
