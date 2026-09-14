@testable import DarkbloomSandboxDaemon
import XCTest

final class ReconcileExpiredCommandTests: XCTestCase {
    func testParsesRequiredCapacityPolicyAndSafeDefaults() throws {
        let options = try ReconcileExpiredCommand.Options([
            "--lume", "/opt/darkbloom/lume",
            "--storage", "/var/lib/darkbloom/vms",
            "--capacity-dir", "/var/lib/darkbloom/capacity",
            "--max-cpu", "12",
            "--max-memory-gib", "32",
            "--development-ad-hoc-lume",
            "--json",
        ])

        XCTAssertEqual(options.maximumCPUCount, 12)
        XCTAssertEqual(options.maximumMemoryGiB, 32)
        XCTAssertEqual(options.maximumGrowthGiB, 320)
        XCTAssertEqual(options.storageHeadroomGiB, 20)
        XCTAssertTrue(options.developmentAdHocLume)
        XCTAssertTrue(options.json)
    }

    func testRejectsIncompleteUnsafeOrDuplicateArguments() {
        XCTAssertThrowsError(try ReconcileExpiredCommand.Options([
            "--lume", "/lume",
            "--storage", "/vms",
            "--capacity-dir", "/capacity",
            "--max-memory-gib", "32",
        ]))
        XCTAssertThrowsError(try ReconcileExpiredCommand.Options([
            "--lume", "/lume",
            "--storage", "relative",
            "--capacity-dir", "/capacity",
            "--max-cpu", "8",
            "--max-memory-gib", "32",
        ]))
        XCTAssertThrowsError(try ReconcileExpiredCommand.Options([
            "--lume", "/lume",
            "--storage", "/vms",
            "--capacity-dir", "/capacity",
            "--max-cpu", "0",
            "--max-memory-gib", "32",
        ]))
        XCTAssertThrowsError(try ReconcileExpiredCommand.Options([
            "--lume", "/lume",
            "--lume", "/other",
            "--storage", "/vms",
            "--capacity-dir", "/capacity",
            "--max-cpu", "8",
            "--max-memory-gib", "32",
        ]))
    }
}
