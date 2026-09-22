import Foundation
import Testing
@testable import ConnectCore

@Test func terminalHandoffRechecksExecutableBeforeRunningIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connect-handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake worker's executable")
    let marker = directory.appendingPathComponent("should-not-exist")
    try "#!/bin/sh\n/usr/bin/touch \(SetupHandoff.quote(marker.path))\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let script = directory.appendingPathComponent("handoff.command")
    let identity = WorkerIdentity(executable: executable, cdHash: Data())
    let config = directory.appendingPathComponent("fixed-provider.toml")
    let body = SetupHandoff.script(action: .login, worker: identity, home: directory.path, coordinatorConfig: config)
    #expect(body.contains("'--config' \(SetupHandoff.quote(config.path))"))
    try body.write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
