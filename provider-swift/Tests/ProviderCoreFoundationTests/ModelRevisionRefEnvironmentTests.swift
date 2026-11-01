import Foundation
import ProviderBuildEnvironment
import XCTest

@testable import ProviderCoreFoundation

/// The weights cache is shared by a dev and a production install, but each
/// install selects its active revision with its own ref.
final class ModelRevisionRefEnvironmentTests: XCTestCase {
    private var root: URL!
    private var snapshots: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("revision-ref-\(UUID().uuidString)", isDirectory: true)
        snapshots = root.appendingPathComponent("models--example--model/snapshots", isDirectory: true)
        for name in ["prod-revision", "dev-revision"] {
            try FileManager.default.createDirectory(
                at: snapshots.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var refs: URL { snapshots.deletingLastPathComponent().appendingPathComponent("refs", isDirectory: true) }

    private func select(_ environment: BuildEnvironment, _ revision: String) throws {
        try revision.write(to: refs.appendingPathComponent(environment.modelRevisionRef), atomically: true, encoding: .utf8)
    }

    private func selected(_ environment: BuildEnvironment) -> String? {
        ModelScanner.findLatestSnapshot(
            in: snapshots, refNames: ModelScanner.revisionRefNames(for: environment))?.lastPathComponent
    }

    func testProductionReadsOnlyItsOwnRef() {
        XCTAssertEqual(ModelScanner.revisionRefNames(for: .prod), [BuildEnvironment.prod.modelRevisionRef])
        XCTAssertEqual(ModelScanner.revisionRefNames(), ModelScanner.revisionRefNames(for: .current))
    }

    func testEnvironmentsSelectIndependently() throws {
        try select(.prod, "prod-revision")
        try select(.dev, "dev-revision")
        XCTAssertEqual(selected(.prod), "prod-revision")
        XCTAssertEqual(selected(.dev), "dev-revision")

        // A dev activation never moves production's selection, and the reverse.
        try select(.dev, "prod-revision")
        XCTAssertEqual(selected(.prod), "prod-revision")
        try select(.prod, "dev-revision")
        XCTAssertEqual(selected(.dev), "prod-revision")
    }

    func testDevWithoutItsOwnRefFollowsProductionSelection() throws {
        try select(.prod, "prod-revision")
        XCTAssertEqual(selected(.dev), "prod-revision")
    }
}
