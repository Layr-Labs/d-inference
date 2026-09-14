import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessBaseCommandTests: XCTestCase {
    private let common = ["--storage", "/vms", "--name", "base", "--host-identity-file", "/config/host.json",
                          "--host-id", "f10c12bf-881a-432e-80d2-20a562568353"]
    private let reserve = ["--lume", "/runtime/lume", "--ipsw", "/images/apple.ipsw", "--guest-release", "/release"]
    private let payload = ["--guest-release", "/release", "--output", "/operator/payload"]
    private let stage = ["--lume", "/runtime/lume", "--payload", "/operator/payload", "--journal-dir", "/operator/staging"]
    private let collection = ["--permit-file", "/root-plan/permit.json", "--boot-journal-dir", "/operator/boot",
                              "--collection-dir", "/operator/collection"]
    private let publication = ["--permit-file", "/root-plan/permit.json", "--collection-file", "/root-plan/collection.json",
                               "--guest-release", "/release"]

    func testReserveSelectsRawRestoreWithNoAccountPresetAndFixedDiskPolicy() throws {
        let options = try AccountlessBaseOptions(["reserve"] + common + reserve + ["--json"])
        let spec = try options.specification()
        guard case .appleRestore(let image) = spec.imageSource else { return XCTFail("must never choose unattended account setup") }
        XCTAssertEqual(image.path, "/images/apple.ipsw")
        XCTAssertEqual(spec.resources.cpuCount, 4)
        XCTAssertEqual(spec.resources.memoryBytes, 8 * SandboxResourcePolicy.gibibyte)
        XCTAssertEqual(spec.diskBytes, SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound)
        XCTAssertTrue(options.json)
        for extra in [["--disk-gib", "1"], ["--cpu", "0"], ["--memory-gib", "18446744073709551615"],
                      ["--development-ad-hoc-lume"], ["--unattended", "tahoe"]] {
            XCTAssertThrowsError(try AccountlessBaseOptions(["reserve"] + common + reserve + extra))
        }
    }

    func testPhaseOptionsCannotCrossPrivilegeOrOperationBoundaries() throws {
        XCTAssertEqual(try AccountlessBaseOptions(["payload"] + common + payload).phase, .payload)
        XCTAssertEqual(try AccountlessBaseOptions(["stage"] + common + stage).phase, .stage)
        XCTAssertEqual(try AccountlessBaseOptions(["boot"] + common + ["--permit-file", "/root-plan/permit.json"]).phase, .boot)
        XCTAssertEqual(try AccountlessBaseOptions(["authorize-boot"] + common + stage
            + ["--boot-journal-dir", "/operator/boot", "--permit-file", "/root-plan/permit.json"]).phase, .authorizeBoot)
        XCTAssertEqual(try AccountlessBaseOptions(["collect"] + common + collection
            + ["--collection-file", "/root-plan/collection.json"]).phase, .collect)
        XCTAssertEqual(try AccountlessBaseOptions(["abort-collection"] + common + collection).phase, .abortCollection)
        XCTAssertEqual(try AccountlessBaseOptions(["publish-installed"] + common + publication).phase, .publishInstalled)
        XCTAssertEqual(try AccountlessBaseOptions(["qualify"] + common + publication
            + ["--capacity-dir", "/operator/capacity", "--qualification-dir", "/operator/qualification"]).phase, .qualify)
        for args in [["reserve"] + common + reserve + ["--journal-dir", "/operator/journal"],
                     ["stage"] + common + stage + ["--ipsw", "/image"],
                     ["payload"] + common + payload + ["--lume", "/runtime/lume"],
                     ["stage"] + common + stage + ["--json", "--json"],
                     ["stage"] + common + stage + ["--name", "other"],
                     ["boot"] + common + ["--permit-file", "/root-plan/permit.json", "--lume", "/other-runtime"],
                     ["collect"] + common + collection,
                     ["abort-collection"] + common + collection + ["--collection-file", "/root-plan/collection.json"],
                     ["publish-installed"] + common + publication + ["--lume", "/other-runtime"],
                     ["publish-installed"] + common + publication + ["--collection-dir", "/operator/collection"],
                     ["qualify"] + common + publication,
                     ["qualify"] + common + publication + ["--capacity-dir", "/operator/capacity", "--qualification-dir", "/operator/qualification", "--lume", "/other"],
                     ["boot"] + common, ["stage"] + common] {
            XCTAssertThrowsError(try AccountlessBaseOptions(args), args.joined(separator: " "))
        }
    }

    func testPathsRejectTraversalControlCharactersAndMissingValues() throws {
        for path in ["relative", "/operator/../payload", "/operator//payload", "/operator/payload\n", "/", "--json"] {
            XCTAssertThrowsError(try AccountlessBaseOptions(["payload"] + common + ["--guest-release", "/release", "--output", path]))
        }
        XCTAssertThrowsError(try AccountlessBaseOptions(["payload"] + common + ["--guest-release", "/release", "--output"]))
    }

    func testRootPhasesRefuseOrdinaryProcessBeforeOpeningInputPaths() throws {
        guard getuid() != 0 else { throw XCTSkip("requires an ordinary test process") }
        for args in [["payload"] + common + payload, ["stage"] + common + stage,
                     ["collect"] + common + collection + ["--collection-file", "/root-plan/collection.json"],
                     ["abort-collection"] + common + collection] {
            XCTAssertThrowsError(try AccountlessBaseRootInput(AccountlessBaseOptions(args))) { error in
                XCTAssertTrue(String(describing: error).contains("require the root operator"))
            }
        }
    }

    func testPreparationReportsNeverClaimInstallationOrQualification() throws {
        let fixture = try AccountlessInstallationTestFixture(); defer { fixture.remove() }
        for phase in [AccountlessBasePhaseReport.Phase.awaitingRootInstallation, .payloadPrepared, .payloadStaged,
                      .installerBootAuthorized, .installerBootStopped, .installerAttemptRecovered,
                      .installationCollected, .collectionAborted] {
            let report = AccountlessBasePhaseReport(phase: phase, candidate: fixture.candidate, replayed: true)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            XCTAssertEqual(json["installed"] as? Bool, false)
            XCTAssertEqual(json["qualified"] as? Bool, false)
            XCTAssertEqual(json["phase"] as? String, phase.rawValue)
            XCTAssertEqual(json["replayed"] as? Bool, true)
        }
        let installed = AccountlessBasePhaseReport(phase: .installedAwaitingQualification, candidate: fixture.candidate,
            sourceStopped: true, collectionPath: "/root-plan/collection.json", installed: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(installed)) as? [String: Any])
        XCTAssertEqual(json["installed"] as? Bool, true)
        XCTAssertEqual(json["qualified"] as? Bool, false)
        XCTAssertEqual(json["collectionPath"] as? String, "/root-plan/collection.json")
        let qualified = AccountlessBasePhaseReport(phase: .templateQualified, candidate: fixture.candidate,
            sourceStopped: true, installed: true, qualified: true, qualificationID: UUID())
        let qualifiedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(qualified)) as? [String: Any])
        XCTAssertEqual(qualifiedJSON["qualified"] as? Bool, true)
        XCTAssertNotNil(qualifiedJSON["qualificationID"])
    }

    func testAClaimedInstallerCannotBeReservedAsANewRawCandidate() throws {
        let fixture = try AccountlessInstallationTestFixture(); defer { fixture.remove() }
        let directory = fixture.base.storage.appendingPathComponent("base")
        let store = try AccountlessBaseCandidateStore(directory: directory)
        try store.requireNoPreparedArtifacts()
        let claim = directory.appendingPathComponent(LumeInstalledCandidateCheckpoint.bootClaimFileName)
        try Data().write(to: claim)
        XCTAssertEqual(chmod(claim.path, 0o600), 0)
        XCTAssertThrowsError(try store.requireNoPreparedArtifacts())
    }
}
