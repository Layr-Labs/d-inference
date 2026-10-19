import Darwin
import Foundation

/// Process-only service fixture: no owner protocol, model, GPU, or sockets.
/// A TERM records the request; a private gate lets the test finish retirement.
func memberFixtureServicePart(arguments: [String]) throws {
    guard arguments.count >= 3, arguments[0] == "--service-part-fixture",
          arguments[1].hasPrefix("/"), ["leftover", "replacement"].contains(arguments[2]) else {
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
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let registered = DispatchSemaphore(value: 0)
    termination.setRegistrationHandler { registered.signal() }
    termination.setEventHandler { try? Data().write(to: requested, options: .atomic) }
    termination.resume()
    defer { termination.cancel() }
    guard registered.wait(timeout: .now() + 2) == .success else { throw MemberFixtureError.invalid }
    try Data(String(pid).utf8).write(to: ready, options: .withoutOverwriting)

    while true {
        if FileManager.default.fileExists(atPath: release.path),
           role == "leftover" || FileManager.default.fileExists(atPath: requested.path) {
            return
        }
        usleep(20_000)
    }
}
