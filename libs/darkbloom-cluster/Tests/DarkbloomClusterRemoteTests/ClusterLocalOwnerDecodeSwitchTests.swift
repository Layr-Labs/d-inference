import Darwin
import Foundation
import XCTest
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// The GLM tensor-parallel decode switches (`ClusterGLMTensorParallel.decodeSwitches`)
/// cross from a cluster service to the owner child it starts with their fixed
/// names and values only; anything else is refused before a launch.
final class ClusterLocalOwnerDecodeSwitchTests: XCTestCase {
    func testKnownDecodeSwitchesReachTheOwnerChildAndOthersAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-switches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("darkbloom")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o755), 0)
        let owner = URL(fileURLWithPath: file.resolvingSymlinksInPath().path)

        let switches = [ClusterGLMTensorParallel.depthPolicySwitch: "load",
                        ClusterGLMTensorParallel.loadLanesSwitch: "4",
                        ClusterGLMTensorParallel.widthInvariantSwitch: "1"]
        let launch = try ClusterLocalOwnerConfiguration(installedDarkbloom: owner, batchLanes: 8,
            glmDecodeSwitches: switches).launch()
        for (name, value) in switches { XCTAssertEqual(launch.environment[name], value, name) }
        XCTAssertEqual(launch.environment["DARKBLOOM_CLUSTER_BATCH_LANES"], "8")

        // None set: the owner child's environment has no decode switch.
        let plain = try ClusterLocalOwnerConfiguration(installedDarkbloom: owner).launch()
        XCTAssertTrue(plain.environment.keys.allSatisfy { ClusterGLMTensorParallel.decodeSwitches[$0] == nil })

        for refused in [[ClusterGLMTensorParallel.depthPolicySwitch: "acceptance"],
                        [ClusterGLMTensorParallel.loadLanesSwitch: "12"],
                        ["DARKBLOOM_GLM_TP_OTHER": "1"]] {
            XCTAssertThrowsError(try ClusterLocalOwnerConfiguration(installedDarkbloom: owner,
                glmDecodeSwitches: refused), "\(refused)")
        }
    }
}
