// Test-process fixture. Never packaged or used to authorize a real VM.
import Darwin
import Foundation
import SandboxRuntime

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, ["--signal-cancel", "--signal-restore"].contains(arguments[0]) {
    exit(await SignalProbe.run(mode: arguments[0], directory: URL(fileURLWithPath: arguments[1], isDirectory: true)))
}
guard arguments.count == 1 else { exit(64) }
let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
var metadata = stat()
guard directory.lastPathComponent.hasPrefix("managed-ownership-"),
      directory.resolvingSymlinksInPath().path == directory.path,
      lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else { exit(78) }
let descriptor = open(directory.appendingPathComponent("ownership.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
guard descriptor >= 0, fstat(descriptor, &metadata) == 0,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_size == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { exit(78) }
let borrowed = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
guard borrowed >= 64 else { exit(78) }
do {
    let child = try SandboxProcessRunner().start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [directory.appendingPathComponent("child.py").path, directory.path, "hold"],
        cooperativeControl: SandboxCooperativeProcessControl(environmentVariable: "DARKBLOOM_TEST_OWNER_EOF"),
        runtimeAuthorityDescriptor: borrowed)
    close(borrowed)
    let result = await child.wait()
    close(descriptor)
    exit(result.exitCode)
} catch { close(borrowed); close(descriptor); exit(78) }
