import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeTestProbe {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let readiness: String
    private var finished = false
    init(fixture: HostRuntimeTestFixture, role: String, intent: HostRuntimeMaintenanceIntent? = nil) throws {
        let executable = Bundle(for: HostRuntimeCoordinationTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("HostRuntimeLockProbe")
        process.executableURL = executable
        process.arguments = [fixture.directory.path, role, String(geteuid()), String(getegid())]
        if let intent { process.arguments! += [intent.operationID.uuidString, intent.journalSHA256] }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        readiness = String(decoding: output.fileHandleForReading.readData(ofLength: 9), as: UTF8.self)
    }
    func finish() {
        guard !finished else { return }
        finished = true
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
    deinit { finish() }
}
