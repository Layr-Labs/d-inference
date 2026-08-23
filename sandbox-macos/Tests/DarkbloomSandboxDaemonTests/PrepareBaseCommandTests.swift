@testable import DarkbloomSandboxDaemon
import XCTest

final class PrepareBaseCommandTests: XCTestCase {
    func testParsesRequiredPathsAndBoundedDefaults() throws {
        let options = try PrepareBaseCommand.Options([
            "--lume", "/opt/darkbloom/lume",
            "--storage", "/var/lib/darkbloom/vms",
            "--ipsw", "/var/lib/darkbloom/images/tahoe.ipsw",
            "--name", "phase0-base",
            "--json",
        ])

        XCTAssertEqual(options.lumeExecutable.path, "/opt/darkbloom/lume")
        XCTAssertEqual(options.storageDirectory.path, "/var/lib/darkbloom/vms")
        XCTAssertEqual(
            options.restoreImage.path,
            "/var/lib/darkbloom/images/tahoe.ipsw"
        )
        XCTAssertEqual(options.name, "phase0-base")
        XCTAssertEqual(options.cpuCount, 4)
        XCTAssertEqual(options.memoryGiB, 8)
        XCTAssertEqual(options.diskGiB, 100)
        XCTAssertTrue(options.json)
    }

    func testRejectsRelativeMissingDuplicateAndUnknownOptions() {
        XCTAssertThrowsError(try PrepareBaseCommand.Options([
            "--lume", "relative/lume",
            "--storage", "/vms",
            "--ipsw", "/image.ipsw",
            "--name", "base",
        ]))
        XCTAssertThrowsError(try PrepareBaseCommand.Options([
            "--lume", "/lume",
            "--storage", "/vms",
            "--ipsw", "/image.ipsw",
        ]))
        XCTAssertThrowsError(try PrepareBaseCommand.Options([
            "--lume", "/lume",
            "--lume", "/other-lume",
            "--storage", "/vms",
            "--ipsw", "/image.ipsw",
            "--name", "base",
        ]))
        XCTAssertThrowsError(try PrepareBaseCommand.Options([
            "--lume", "/lume",
            "--storage", "/vms",
            "--ipsw", "/image.ipsw",
            "--name", "base",
            "--unknown", "value",
        ]))
    }
}
