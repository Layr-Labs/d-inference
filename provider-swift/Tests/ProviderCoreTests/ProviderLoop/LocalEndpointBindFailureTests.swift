import Darwin
import Foundation
import Testing

@testable import ProviderCore

/// A provider serving Darkbloom and its owner (Both) whose local API can't listen keeps serving Darkbloom, and its
/// state says why (`DaemonState.localAPIFailure`), so `status` and `local` never read the missing API as "Darkbloom
/// network only". The busy port is one this test holds on loopback; nothing loads a model or opens the GPU.
@Suite("The local API that couldn't listen", .serialized)
struct LocalEndpointBindFailureTests {
    /// A loopback listener on a port the system picks: another program holding the local API's port.
    final class HeldPort {
        let fd: Int32
        let port: UInt16

        init() throws {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw POSIXError(.EBADF) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                    bind(socketFD, pointer, length) == 0 && listen(socketFD, 1) == 0
                        && getsockname(socketFD, pointer, &length) == 0
                }
            }
            guard bound else {
                close(socketFD)
                throw POSIXError(.EADDRINUSE)
            }
            fd = socketFD
            port = UInt16(bigEndian: address.sin_port)
        }

        deinit { close(fd) }
    }

    /// The loop's state once its local API has had `seconds` to bind.
    private func failure(of loop: ProviderLoop, within seconds: Double = 5) async -> DaemonState.LocalAPIFailure? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let failure = await loop.currentDaemonState().localAPIFailure { return failure }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    @Test("a port another program holds: the state names the port, and Darkbloom serving is untouched")
    func portInUseIsRecorded() async throws {
        let held = try HeldPort()
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let endpoint = LocalInferenceHTTPConfig(host: "127.0.0.1", port: held.port, authToken: "dk-local-fixture")
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox, localEndpoint: endpoint)
        await loop.startLocalEndpoint(endpoint)
        let recorded = await failure(of: loop)
        #expect(recorded == DaemonState.LocalAPIFailure(host: "127.0.0.1", port: held.port, portInUse: true))
        // The state file the loop writes carries it too, for `status` in another process.
        let written = DaemonStateFile.read(from: sandbox.daemonStateFile)
        #expect(written?.localAPIFailure == recorded)
        await loop.stopLocalEndpoint()
        #expect(await loop.currentDaemonState().localAPIFailure == nil, "stopped: nothing to say")
    }

    @Test("the failure round-trips through the state file, and an older file without it still reads")
    func failureRoundTrips() throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let failure = DaemonState.LocalAPIFailure(host: "100.64.0.9", port: 8001, portInUse: false,
                                                  reason: "Can't assign requested address")
        DaemonStateFile.write(DaemonState(pid: 1, version: "test", writtenAt: 0, startedAt: 0, localAPIFailure: failure),
                              to: sandbox.daemonStateFile)
        #expect(DaemonStateFile.read(from: sandbox.daemonStateFile)?.localAPIFailure == failure)
        DaemonStateFile.write(DaemonState(pid: 1, version: "test", writtenAt: 0, startedAt: 0), to: sandbox.daemonStateFile)
        let older = try #require(DaemonStateFile.read(from: sandbox.daemonStateFile))
        #expect(older.localAPIFailure == nil)
    }
}
