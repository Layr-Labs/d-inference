import XCTest

final class MiMoTestPrerequisitesTests: XCTestCase {
    func testAbsentOptInIsTheOnlyDisabledGate() {
        XCTAssertThrowsError(try MiMoTestPrerequisites.requireOptIn("NATIVE_TEST", environment: [:])) {
            XCTAssertTrue($0 is XCTSkip)
        }
        for value in ["", "0", "true", " 1", "2"] {
            XCTAssertThrowsError(try MiMoTestPrerequisites.requireOptIn("NATIVE_TEST",
                environment: ["NATIVE_TEST": value])) {
                guard case MiMoTestPrerequisites.Failure.invalidOptIn("NATIVE_TEST") = $0 else {
                    return XCTFail("Malformed opt-in must fail, not skip: \($0)")
                }
            }
        }
        XCTAssertNoThrow(try MiMoTestPrerequisites.requireOptIn("NATIVE_TEST",
            environment: ["NATIVE_TEST": "1"]))
    }
}
