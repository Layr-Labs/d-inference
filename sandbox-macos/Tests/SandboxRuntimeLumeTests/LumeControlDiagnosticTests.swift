import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeControlDiagnosticTests: XCTestCase {
    func testKeepsManagementFailureWhenRuntimeUsesStandardOutput() {
        let result = SandboxProcessResult(exitCode: 70, standardOutput: Data("installer failed\n".utf8),
            standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
        XCTAssertEqual(LumeControlDiagnostic.failure(result), "installer failed")
        let both = SandboxProcessResult(exitCode: 70, standardOutput: Data("noise".utf8),
            standardError: Data("specific failure".utf8), standardOutputTruncated: false, standardErrorTruncated: false)
        XCTAssertEqual(LumeControlDiagnostic.failure(both), "specific failure")
    }
}
