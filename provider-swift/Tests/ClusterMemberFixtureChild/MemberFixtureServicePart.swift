import Darwin
import DarkbloomClusterProcess
import Foundation

/// Process-only service fixture: no owner protocol, model, GPU, or sockets.
/// A TERM records the request; a private gate lets the test finish retirement.
func memberFixtureServicePart(arguments: [String]) throws {
    guard arguments.count >= 3, arguments[0] == "--service-part-fixture",
          arguments[1].hasPrefix("/"), ["leftover", "replacement", "leader", "member"].contains(arguments[2]) else {
        throw MemberFixtureError.invalid
    }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let role = arguments[2]
    let pid = getpid()
    let requested = directory.appendingPathComponent("\(role)-\(pid).term")
    let ready = directory.appendingPathComponent("\(role)-\(pid).ready")
    let release = directory.appendingPathComponent("release-\(role)")

    // The test also owns explicit cleanup. This bounds a fixture whose test dies.
    alarm(60)
    // The device scope a real part takes first (`ClusterDeviceExclusion`): with `gpu.lock.refusal` in the gate directory,
    // `gpu.lock` there stands in for the Mac's GPU lock. Refused, the part writes that file's words as its error line and
    // ends, as a real part does.
    var scope: ClusterDeviceExclusion?
    if let words = try? String(contentsOf: directory.appendingPathComponent("gpu.lock.refusal"), encoding: .utf8) {
        do {
            scope = try ClusterDeviceExclusion(directoryURL: directory.appendingPathComponent("lease-\(role)", isDirectory: true),
                machineLock: .init(file: directory.appendingPathComponent("gpu.lock"), heldElsewhere: words))
        } catch {
            try? Data().write(to: directory.appendingPathComponent("\(role)-\(pid).refused"))
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
    defer { withExtendedLifetime(scope) {} }
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let registered = DispatchSemaphore(value: 0)
    termination.setRegistrationHandler { registered.signal() }
    termination.setEventHandler { try? Data().write(to: requested, options: .atomic) }
    termination.resume()
    defer { termination.cancel() }
    guard registered.wait(timeout: .now() + 2) == .success else { throw MemberFixtureError.invalid }
    // The heartbeat file the service told this part to beat into (written before `ready`, so a test sees both).
    if let health = ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"] {
        try Data(health.utf8).write(to: directory.appendingPathComponent("\(role)-\(pid).health"), options: .withoutOverwriting)
    }
    try Data(String(pid).utf8).write(to: ready, options: .withoutOverwriting)

    while true {
        if FileManager.default.fileExists(atPath: release.path),
           role == "leftover" || FileManager.default.fileExists(atPath: requested.path) {
            return
        }
        usleep(20_000)
    }
}
