import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeBaseImageShareTests: XCTestCase, @unchecked Sendable {
    func testShareRequiresDevelopmentBasePolicyAndRejectsLeaseScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("base-share-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertThrowsError(try LumeRuntimeConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"),
            storageDirectory: canonical, guestCommandPolicy: .disabled, baseImageSharedDirectory: canonical))
        let configuration = try LumeRuntimeConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"),
            storageDirectory: canonical, guestCommandPolicy: .baseImagePreparationAndDevelopment, baseImageSharedDirectory: canonical)
        let runtime = LumeVirtualMachineRuntime(configuration: configuration)
        let arguments = try await runtime.baseImageShareArguments(scope: nil)
        XCTAssertEqual(arguments, ["--shared-dir", canonical.path + ":ro"])
        let scope = SandboxOperationScope(sandboxID: SandboxID(),
            generation: SandboxGeneration(rawValue: 1)!, fencingToken: SandboxFencingToken(rawValue: 1)!)
        do {
            _ = try await runtime.baseImageShareArguments(scope: scope)
            XCTFail("tenant scope must not receive a bootstrap share")
        } catch {}
    }
}
