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
guard [4, 6].contains(arguments.count), let owner = UInt32(arguments[2]), let group = UInt32(arguments[3]) else {
    exit(64)
}
do {
    let authority = HostRuntimeAuthority(testDirectory: URL(fileURLWithPath: arguments[0]),
                                         ownerUID: owner, groupID: group)
    if arguments.count == 6, arguments[1] == "maintenance", let id = UUID(uuidString: arguments[4]) {
        let lease = try authority.acquireSandbox()
        let scope = try lease.beginRootMaintenance(.init(operationID: id, journalSHA256: arguments[5]))
        try scope.validate()
        FileHandle.standardOutput.write(Data("acquired\n".utf8))
        withExtendedLifetime(scope) {
            _ = readLine()
            // Deliberately bypass destructors: the crash test must prove that
            // the fence survives OS closure of every process-held descriptor.
            _exit(86)
        }
    }
    guard arguments.count == 4 else { exit(64) }
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
