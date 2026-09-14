import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessBaseCommandTests: XCTestCase {
    private let common = ["--storage", "/vms", "--name", "base", "--host-identity-file", "/config/host.json",
                          "--host-id", "f10c12bf-881a-432e-80d2-20a562568353"]
    private let reserve = ["--lume", "/runtime/lume", "--ipsw", "/images/apple.ipsw", "--guest-release", "/release"]
    private let payload = ["--guest-release", "/release", "--output", "/operator/payload"]
    private let stage = ["--lume", "/runtime/lume", "--payload", "/operator/payload", "--journal-dir", "/operator/staging"]

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
        for args in [["reserve"] + common + reserve + ["--journal-dir", "/operator/journal"],
                     ["stage"] + common + stage + ["--ipsw", "/image"],
                     ["payload"] + common + payload + ["--lume", "/runtime/lume"],
                     ["stage"] + common + stage + ["--json", "--json"],
                     ["stage"] + common + stage + ["--name", "other"],
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
        for args in [["payload"] + common + payload, ["stage"] + common + stage] {
            XCTAssertThrowsError(try AccountlessBaseRootInput(AccountlessBaseOptions(args))) { error in
                XCTAssertTrue(String(describing: error).contains("require the root operator"))
            }
        }
    }

    func testPhaseReportsNeverClaimInstallationOrQualification() throws {
        let fixture = try AccountlessInstallationTestFixture(); defer { fixture.remove() }
        for phase in [AccountlessBasePhaseReport.Phase.awaitingRootInstallation, .payloadPrepared, .payloadStaged] {
            let report = AccountlessBasePhaseReport(phase: phase, candidate: fixture.candidate, replayed: true)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            XCTAssertEqual(json["installed"] as? Bool, false)
            XCTAssertEqual(json["qualified"] as? Bool, false)
            XCTAssertEqual(json["phase"] as? String, phase.rawValue)
            XCTAssertEqual(json["replayed"] as? Bool, true)
        }
    }
}
