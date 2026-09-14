import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeInheritedTestProbe {
    private var child: pid_t = 0
    private var inputWriter: Int32 = -1
    let readiness: String
    init(descriptor: Int32) throws {
        var input = [Int32](repeating: -1, count: 2)
        var output = [Int32](repeating: -1, count: 2)
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw POSIXError(.EIO) }
        defer { close(input[0]); close(output[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptor, 4) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw POSIXError(.EIO) }
        let executable = Bundle(for: HostRuntimeCoordinationTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("HostRuntimeLockProbe").path
        let values: [String] = [executable, "inherited", "4"]
        let strings = values.map { value in value.withCString { strdup($0) } }
        defer { for string in strings { free(string) } }
        var arguments = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = posix_spawn(&child, executable, &actions, &attributes, &arguments, &environment)
        guard status == 0 else {
            close(input[1]); close(output[0])
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        inputWriter = input[1]
        let reader = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
        readiness = String(decoding: reader.readData(ofLength: 9), as: UTF8.self)
    }
    func finish() {
        guard child > 0 else { return }
        close(inputWriter)
        inputWriter = -1
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        child = 0
    }
    deinit { finish() }
}
