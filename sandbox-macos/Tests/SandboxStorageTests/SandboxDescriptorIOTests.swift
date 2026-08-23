import Darwin
import Foundation
@testable import SandboxStorage
import XCTest

final class SandboxDescriptorIOTests: XCTestCase {
    func testSourceMutationPreventsDestinationPublication() throws {
        let fixture = try DescriptorFixture()
        defer { fixture.remove() }
        try Data("before".utf8).write(to: fixture.source)

        XCTAssertThrowsError(
            try SandboxDescriptorIO.withStableSourceAndExclusiveDestination(
                source: fixture.source,
                destination: fixture.destination
            ) { sourceDescriptor, _, destinationDescriptor in
                let data = try SandboxDescriptorIO.readUpTo(
                    64,
                    from: sourceDescriptor
                )
                try SandboxDescriptorIO.writeAll(
                    data,
                    to: destinationDescriptor
                )
                let mutation = Darwin.open(
                    fixture.source.path,
                    O_WRONLY | O_CLOEXEC
                )
                guard mutation >= 0 else {
                    throw POSIXError(.EIO)
                }
                defer { Darwin.close(mutation) }
                var replacement: UInt8 = 0x58
                guard pwrite(mutation, &replacement, 1, 0) == 1 else {
                    throw POSIXError(.EIO)
                }
            }
        ) { error in
            XCTAssertEqual(
                error as? SandboxDescriptorIOError,
                .sourceChanged
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.destination.path)
        )
        XCTAssertFalse(try fixture.hasPartialFiles())
    }

    func testCompetingDestinationWinsWithoutOverwrite() throws {
        let fixture = try DescriptorFixture()
        defer { fixture.remove() }
        let competing = Data("competing".utf8)

        XCTAssertThrowsError(
            try SandboxDescriptorIO.withExclusiveDestination(
                at: fixture.destination
            ) { descriptor in
                try SandboxDescriptorIO.writeAll(
                    Data("pending".utf8),
                    to: descriptor
                )
                try competing.write(to: fixture.destination)
            }
        ) { error in
            XCTAssertEqual(
                error as? SandboxDescriptorIOError,
                .destinationExists
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination),
            competing
        )
        XCTAssertFalse(try fixture.hasPartialFiles())
    }

    func testDestinationParentSymlinkIsRejected() throws {
        let fixture = try DescriptorFixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent(
            "target",
            isDirectory: true
        )
        let link = fixture.directory.appendingPathComponent(
            "linked-parent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        let destination = link.appendingPathComponent("artifact")

        XCTAssertThrowsError(
            try SandboxDescriptorIO.withExclusiveDestination(
                at: destination
            ) { descriptor in
                try SandboxDescriptorIO.writeAll(
                    Data("blocked".utf8),
                    to: descriptor
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? SandboxDescriptorIOError,
                .unsafeDestination
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("artifact").path
            )
        )
    }
}

private struct DescriptorFixture {
    let directory: URL
    let source: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-descriptor-io-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        source = directory.appendingPathComponent("source")
        destination = directory.appendingPathComponent("destination")
    }

    func hasPartialFiles() throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).contains { $0.hasSuffix(".partial") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
