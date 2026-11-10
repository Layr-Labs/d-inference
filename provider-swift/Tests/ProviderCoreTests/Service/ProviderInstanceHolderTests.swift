import Foundation
import Darwin
import Testing
@testable import ProviderCore

/// Who holds this Mac's provider instance lock decides what the pair's screens say (0.10.8: a single-Mac provider was
/// called "another update operation").
@Suite("Provider instance lock holder", .serialized)
struct ProviderInstanceHolderTests {
    private func lockFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("holder-\(UUID().uuidString)").appendingPathComponent("provider.pid.lock")
    }

    @Test("a single-Mac provider, a part of the pair, and a child of the cluster service are told apart")
    func kinds() {
        typealias H = ProviderInstanceHolder
        let service = ["/Applications/Darkbloom.app/Contents/MacOS/darkbloom", "cluster", "service", "--config", "c.toml"]
        #expect(H.kind(arguments: ["darkbloom", "start", "--foreground"], parentArguments: ["launchd"]) == .singleMac)
        #expect(H.kind(arguments: ["darkbloom", "start", "--local", "--distributed"], parentArguments: service) == .pairPart)
        #expect(H.kind(arguments: ["darkbloom", "start", "--foreground", "--cluster-member"], parentArguments: nil) == .pairPart)
        // The cluster service's own degraded server runs `start --local`, as the app's local mode does: its parent tells.
        #expect(H.kind(arguments: ["darkbloom", "start", "--local"], parentArguments: service) == .pairPart)
        #expect(H.kind(arguments: ["darkbloom", "start", "--local"], parentArguments: ["launchd"]) == .singleMac)
        // Arguments that can't be read are not assumed to be a part.
        #expect(H.kind(arguments: nil, parentArguments: nil) == .singleMac)
    }

    @Test("the holder is read from a held lock, and none from a free one")
    func current() throws {
        let file = lockFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(ProviderInstanceHolder.current(lockFile: file) == nil) // No provider ever ran here.
        let held = try UpdateProcessLock.acquire(at: file, operation: ProviderInstanceHolder.operation)
        let found = ProviderInstanceHolder.current(lockFile: file, arguments: { _ in ["darkbloom", "start"] }, parent: { _ in 1 })
        #expect(found == .init(pid: getpid(), kind: .singleMac))
        #expect(ProviderInstanceHolder.clause(found!) == "a single-Mac Darkbloom provider (process \(getpid())) is serving on this Mac")
        held.release()
        #expect(ProviderInstanceHolder.current(lockFile: file) == nil) // Released: nothing holds it.
    }

    @Test("the lock's message names each owner, in the running identity's command")
    func busyDescriptions() {
        func owner(_ operation: String) -> UpdateProcessLock.Owner {
            .init(pid: 9523, processIdentity: nil, operation: operation, acquiredAt: 1)
        }
        let solo = UpdateProcessLock.busyDescription(owner("provider-instance"), cli: "darkbloom-dev", kind: { _ in .singleMac })
        #expect(solo == "a single-Mac Darkbloom provider (process 9523) is serving on this Mac; `darkbloom-dev stop --solo` stops it")
        let part = UpdateProcessLock.busyDescription(owner("provider-instance"), cli: "darkbloom", kind: { _ in .pairPart })
        #expect(part == "this Mac's part of the two-Mac pair (process 9523) is running")
        #expect(UpdateProcessLock.busyDescription(owner("cluster-auto-update")).hasPrefix("an update (process 9523"))
        #expect(UpdateProcessLock.busyDescription(owner("operator-rollback")) == "a rollback (process 9523) is in progress on this Mac")
        #expect(UpdateProcessLock.busyDescription(owner("addon_hold")).hasPrefix("another Darkbloom operation (process 9523, addon_hold)"))
    }

    @Test("a cluster part's error while single-Mac serving holds it back names it, with `stop --solo`")
    func serviceError() {
        let text = ClusterService.soloServingError(.init(pid: 2282, kind: .singleMac))
        #expect(text == "a single-Mac Darkbloom provider (process 2282) is serving on this Mac, so this Mac's part can't start: "
            + "`\(BuildEnvironment.current.cliName) stop --solo` stops it")
    }

    @Test("a cluster status carries the single-Mac provider, and an older one without it still decodes")
    func statusWire() throws {
        let older = #"{"serving":false,"sessionLeader":false,"child":{"running":false,"starts":0}}"#
        let decoded = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(older.utf8))
        #expect(decoded.soloServing == nil)
        var status = decoded
        status.soloServing = .init(pid: 2282)
        let again = try JSONDecoder().decode(ClusterServiceStatus.self, from: try JSONEncoder().encode(status))
        #expect(again.soloServing?.pid == 2282)
    }
}
