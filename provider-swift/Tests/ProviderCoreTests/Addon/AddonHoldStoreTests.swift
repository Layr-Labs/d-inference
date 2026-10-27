import Darwin
import Foundation
import Security
import Testing

@testable import ProviderCore

/// A short private directory: AF_UNIX paths are limited to 104 bytes.
struct AddonRuntimeFixture {
    let directory: URL
    var paths: AddonHoldPaths { AddonHoldPaths(runtimeDirectory: directory) }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try AddonRuntimeDirectory.prepare(directory)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Holds `ownership.lock` exclusively, as the add-on does while VMs run.
    func holdMachineLock() throws -> Int32 {
        let fd = open(paths.machineLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    static func mode(_ url: URL) -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }
}

@Suite("Add-on hold persistence and machine lock")
struct AddonHoldStoreTests {
    @Test func recordRoundTripsOwnerOnlyAndEmptyRemovesIt() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let store = AddonHoldStore(url: fixture.paths.holdState)
        #expect(store.read() == .absent)
        let hold = AddonHold(addon: "io.darkbloom.sandbox", vmBytes: 8 << 30, state: .held,
                             sinceMs: 1_000, leaseSeconds: 60)
        try store.write([hold])
        #expect(store.read() == .holds([hold]))
        #expect(AddonRuntimeFixture.mode(fixture.paths.holdState) == 0o600)
        #expect(AddonRuntimeFixture.mode(fixture.directory) == 0o700)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.holdState)) as? [String: Any])
        let record = try #require((json["holds"] as? [[String: Any]])?.first)
        #expect(record["lease_expires_at_ms"] as? Int == 61_000 && record["hold_id"] as? String == hold.holdID)
        try store.write([])
        #expect(store.read() == .absent)
    }

    @Test func unsafeOrMalformedRecordsAreInvalid() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let url = fixture.paths.holdState
        let store = AddonHoldStore(url: url)
        try Data("not json".utf8).write(to: url)
        chmod(url.path, 0o600)
        #expect(store.read() == .invalid)
        try store.write([AddonHold(addon: "a.b", vmBytes: 0, state: .held, sinceMs: 0, leaseSeconds: 30)])
        chmod(url.path, 0o644)
        #expect(store.read() == .invalid)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.paths.machineLock)
        #expect(store.read() == .invalid)
    }

    @Test func runtimeDirectoryIsTightenedAndSymlinksRefused() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        chmod(fixture.directory.path, 0o755)
        try AddonRuntimeDirectory.prepare(fixture.directory)
        #expect(AddonRuntimeFixture.mode(fixture.directory) == 0o700)
        let link = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        #expect(throws: (any Error).self) { try AddonRuntimeDirectory.prepare(link) }
    }

    @Test func machineLockProbeObservesWithoutTakingTheLock() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let lock = fixture.paths.machineLock
        #expect(AddonMachineLock.observe(lock) == .free)
        let fd = try fixture.holdMachineLock()
        #expect(AddonMachineLock.observe(lock) == .held)
        flock(fd, LOCK_UN)
        #expect(AddonMachineLock.observe(lock) == .free)
        // The probe released its own shared lock: the add-on can lock again.
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        close(fd)
        #expect(AddonMachineLock.observe(lock) == .free)
    }

    @Test func socketPathOverrideIsForTestsAndRuntimePathsFollowTheInstall() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = AddonHoldPaths.production(environment: [:], home: home)
        let runtime = BuildEnvironment.current.installDirectory(home: home).appendingPathComponent("runtime")
        #expect(paths.socket.path == runtime.appendingPathComponent("addon.sock").path)
        #expect(paths.machineLock.path == runtime.appendingPathComponent("ownership.lock").path)
        #expect(paths.holdState.path == runtime.appendingPathComponent("addon-hold.json").path)
        // Like the add-on client, the override keeps the lock (and the hold
        // record) beside the socket, never at the real runtime paths.
        let overridden = AddonHoldPaths.production(
            environment: [AddonHoldPaths.socketOverrideVariable: "/tmp/x/a.sock"], home: home)
        #expect(overridden.socket.path == "/tmp/x/a.sock")
        #expect(overridden.machineLock.path == "/tmp/x/ownership.lock")
        #expect(overridden.holdState.path == "/tmp/x/addon-hold.json")
        #expect(AddonHoldPaths.production(environment: [AddonHoldPaths.socketOverrideVariable: ""], home: home) == paths)
    }
}

@Suite("Add-on peer policy")
struct AddonPeerPolicyTests {
    @Test func productionRequirementIsExactAndCompiles() throws {
        let sandbox = AddonPeerPolicy.sandbox
        #expect(sandbox.identifier == "io.darkbloom.sandbox" && sandbox.teamID == "SLDQ2GJ6TL")
        #expect(sandbox.requirement == #"anchor apple generic and identifier "io.darkbloom.sandbox" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "SLDQ2GJ6TL""#)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(sandbox.requirement as CFString, [], &requirement) == errSecSuccess)
        #expect(AddonPeerPolicy.current(environment: [:]).identities == [sandbox])
    }

    @Test func theTestProcessIsNotAnAddon() throws {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS)
        #expect(AddonPeerPolicy.current(environment: [:]).authenticate(token) == nil)
    }

    #if DEBUG
    @Test func debugBuildsAcceptOnlyAnExplicitWellFormedExtraIdentity() throws {
        let extra = try #require(AddonPeerPolicy.developmentIdentity("P7373SVQX6:io.darkbloom-test.sandbox"))
        #expect(extra.identifier == "io.darkbloom-test.sandbox" && extra.teamID == "P7373SVQX6")
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(extra.requirement as CFString, [], &requirement) == errSecSuccess)
        let policy = AddonPeerPolicy.current(environment: [AddonPeerPolicy.developmentIdentityVariable: "P7373SVQX6:io.darkbloom-test.sandbox"])
        #expect(policy.identities == [AddonPeerPolicy.sandbox, extra])
        for bad in ["", "P7373SVQX6", "p7373svqx6:io.x", "P7373SVQX6:", "SHORT:io.x", "P7373SVQX6:a\"b", "A:B:C"] {
            #expect(AddonPeerPolicy.developmentIdentity(bad) == nil, "\(bad)")
        }
    }
    #endif
}
