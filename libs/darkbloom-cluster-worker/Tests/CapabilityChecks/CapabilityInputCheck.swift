import Darwin
import Foundation

func checkCapabilityFiles(_ checks: inout CapabilityCheckResults) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = temporary.appendingPathComponent("bytes"), link = temporary.appendingPathComponent("link"), fifo = temporary.appendingPathComponent("fifo")
    try Data("abc".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    guard mkfifo(fifo.path, 0o600) == 0 else { throw CapabilityCheckFailure(message: "Cannot create fixture FIFO") }
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    try checks.yes("regular-file-and-streaming-hash") {
        try capabilityCheck(try WorkerCapabilityInput.read(file.path, maximumBytes: 3, deadline: deadline) == Data("abc".utf8), "Read differs")
        try capabilityCheck(try WorkerCapabilityInput.hash(file.path, maximumBytes: 3, deadline: deadline) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Hash differs")
    }
    try checks.no("read-size-bound") { _ = try WorkerCapabilityInput.read(file.path, maximumBytes: 2, deadline: deadline) }
    try checks.no("read-symlink") { _ = try WorkerCapabilityInput.read(link.path, maximumBytes: 3, deadline: deadline) }
    try checks.no("read-directory") { _ = try WorkerCapabilityInput.read(temporary.path, maximumBytes: 3, deadline: deadline) }
    try checks.no("read-fifo-does-not-block") { _ = try WorkerCapabilityInput.read(fifo.path, maximumBytes: 3, deadline: deadline) }
    try checks.no("expired-read") { _ = try WorkerCapabilityInput.read(file.path, maximumBytes: 3, deadline: 0) }
    let validArgs = ["--describe-runtime", "--config", "/config", "--manifest", "/manifest", "--expected-executable-sha256", String(repeating: "1", count: 64)]
    try checks.yes("explicit-command") { _ = try WorkerCapabilityCommand.Arguments(validArgs) }
    try checks.no("command-extra") { _ = try WorkerCapabilityCommand.Arguments(validArgs + ["--mtp"]) }
    try checks.no("command-empty") { var a = validArgs; a[2] = ""; _ = try WorkerCapabilityCommand.Arguments(a) }
    try checks.no("command-wrong-binary-pin") { var a = validArgs; a[6] = String(repeating: "A", count: 64); _ = try WorkerCapabilityCommand.Arguments(a) }
}
