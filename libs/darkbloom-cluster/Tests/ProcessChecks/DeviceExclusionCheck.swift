import Foundation
import Darwin

@main enum DeviceExclusionCheck {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    static func refused(_ action: () throws -> Void) throws {
        do { try action() } catch is ClusterDeviceExclusionError { return }
        throw Failure(message: "Unsafe device acquisition/journal operation succeeded")
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let record = Data("{\"syntheticNativeOwner\":true}\n".utf8)
        if args.count == 2 && args[0] == "--record-and-exit" {
            let gate = try ClusterDeviceExclusion(directoryURL: URL(fileURLWithPath: args[1]))
            try gate.recordNativeOwnership(record)
            return // Simulated owner ends without native release acknowledgement.
        }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(15)
        defer { alarm(0) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("device-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("new/device", isDirectory: true)
        let file = directory.appendingPathComponent("native-device.lease")
        var gate: ClusterDeviceExclusion? = try ClusterDeviceExclusion(directoryURL: directory)
        var information = stat()
        try require(lstat(file.path, &information) == 0 && information.st_mode & 0o777 == 0o600 && information.st_size == 0,
                    "New journal is not private and empty")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try refused { try gate!.resolveNativeOwnership() }
        try refused { try gate!.recordNativeOwnership(Data()) }
        try refused { try gate!.recordNativeOwnership(Data(repeating: 1, count: 16385)) }
        try require(try Data(contentsOf: file).isEmpty, "Invalid record or resolve changed empty gate")
        gate = nil
        gate = try ClusterDeviceExclusion(directoryURL: directory)
        try gate!.recordNativeOwnership(record)
        try refused { try gate!.recordNativeOwnership(record) }
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try gate!.resolveNativeOwnership()
        try require(try Data(contentsOf: file).isEmpty, "Resolved own journal stayed nonempty")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try refused { try gate!.resolveNativeOwnership() }
        gate = nil

        gate = try ClusterDeviceExclusion(directoryURL: directory)
        try gate!.recordNativeOwnership(record)
        let replacement = Data("unknown external ownership\n".utf8)
        try replacement.write(to: file)
        try refused { try gate!.resolveNativeOwnership() }
        gate = nil
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try require(try Data(contentsOf: file) == replacement, "Unknown journal was cleared")
        try FileManager.default.removeItem(at: file) // Explicit fixture recovery only.

        let victim = root.appendingPathComponent("victim")
        try record.write(to: victim)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: victim, to: file)
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try FileManager.default.removeItem(at: file)
        try require(mkfifo(file.path, 0o600) == 0, "Cannot create FIFO")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try FileManager.default.removeItem(at: file)
        try Data().write(to: file); try require(chmod(file.path, 0o644) == 0, "Cannot change fixture mode")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try FileManager.default.removeItem(at: file)
        try require(try Data(contentsOf: victim) == record, "Linked victim changed")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--record-and-exit", directory.path]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        try require(child.terminationReason == .exit && child.terminationStatus == 0, "Actual journal child failed")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try require(try Data(contentsOf: file) == record, "Owner exit erased its native journal")
        try FileManager.default.removeItem(at: file)

        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        try refused { _ = try ClusterDeviceExclusion(directoryURL: alias) }
        try require(chmod(directory.path, 0o777) == 0, "Cannot change directory fixture mode")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: directory) }
        try require(chmod(directory.path, 0o700) == 0, "Cannot restore directory fixture mode")

        gate = try ClusterDeviceExclusion(directoryURL: directory)
        try gate!.recordNativeOwnership(record)
        let saved = directory.appendingPathComponent("moved-journal")
        try FileManager.default.moveItem(at: file, to: saved)
        try Data().write(to: file)
        try refused { try gate!.resolveNativeOwnership() }
        try require(try Data(contentsOf: saved) == record, "Replaced-path journal was cleared")
        gate = nil
        let raced = root.appendingPathComponent("raced", isDirectory: true)
        let detached = root.appendingPathComponent("detached", isDirectory: true)
        try refused {
            _ = try ClusterDeviceExclusion(directoryURL: raced, beforeFinalValidation: {
                try FileManager.default.moveItem(at: raced, to: detached)
                try FileManager.default.createDirectory(at: raced, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            })
        }
        // Throwing initialization released its old FD/lock, without clearing
        // either directory. The new canonical directory has its own exclusion.
        gate = try ClusterDeviceExclusion(directoryURL: detached)
        let other = try ClusterDeviceExclusion(directoryURL: raced)
        withExtendedLifetime(other) {}
        gate = nil
        let inserted = root.appendingPathComponent("late-journal", isDirectory: true)
        let insertedFile = inserted.appendingPathComponent("native-device.lease")
        try refused {
            _ = try ClusterDeviceExclusion(directoryURL: inserted, beforeFinalValidation: {
                try record.write(to: insertedFile)
            })
        }
        try require(try Data(contentsOf: insertedFile) == record, "Late journal was cleared")
        try refused { _ = try ClusterDeviceExclusion(directoryURL: inserted) }
        print("Device exclusion: 10 actual-file/child groups passed; no native model or network")
    }
}
