// Test-process helper. Never packaged with the provider or sandbox release.
import Darwin
import Foundation
import HostRuntimeCoordination

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "inherited", let descriptor = Int32(arguments[1]) {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_size == 0 else { exit(78) }
    FileHandle.standardOutput.write(Data("acquired\n".utf8))
    _ = readLine()
    close(descriptor)
    exit(0)
}
guard arguments.count == 4, let owner = UInt32(arguments[2]), let group = UInt32(arguments[3]) else {
    exit(64)
}
do {
    let authority = HostRuntimeAuthority(testDirectory: URL(fileURLWithPath: arguments[0]),
                                         ownerUID: owner, groupID: group)
    let lease: HostRuntimeLease?
    if arguments[1] == "inference" { lease = try authority.acquireInferenceIfInstalled() }
    else if arguments[1] == "sandbox" { lease = try authority.acquireSandbox() }
    else { exit(64) }
    guard let lease else { exit(78) }
    FileHandle.standardOutput.write(Data("acquired\n".utf8))
    withExtendedLifetime(lease) { _ = readLine() }
} catch HostRuntimeOwnershipError.occupied {
    exit(75)
} catch {
    FileHandle.standardError.write(Data("ownership validation failed\n".utf8))
    exit(78)
}
