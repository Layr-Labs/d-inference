import Darwin
import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class HostUserIdentityTests: XCTestCase {
    let hostID = UUID(uuidString: "60f6a1b2-77db-40d2-bf27-98fce61c8b0d")!
    let user: [String: Any] = ["recordName": "operator", "uid": 501, "primaryGID": 20,
        "generatedUID": "9819F283-43E0-49E9-8BB3-FD44CD75B963", "homeDirectory": "/Users/operator"]

    func data(user: [String: Any]? = nil, host: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": 1,
            "host_id": host ?? hostID.uuidString.lowercased(), "host_user": user ?? self.user])
    }

    func testExactTypedBindingAndHostUUID() throws {
        let binding = try HostUserIdentityBinding.decode(data(), hostID: hostID)
        XCTAssertEqual(binding.host_user.uid, 501)
        XCTAssertThrowsError(try HostUserIdentityBinding.decode(data(host: UUID().uuidString.lowercased()), hostID: hostID))
        for (key, value): (String, Any) in [("uid", true), ("uid", "501"), ("uid", 0), ("uid", 2001),
            ("primaryGID", false), ("generatedUID", "ffffeeee-dddd-cccc-bbbb-aaaa000001f5"),
            ("generatedUID", "FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5"),
            ("generatedUID", "00000000-0000-0000-0000-000000000000"),
            ("homeDirectory", ""), ("homeDirectory", "/Users/../root"), ("homeDirectory", "/var/empty"),
            ("recordName", "../operator"), ("recordName", "operator\n"), ("password", "not accepted")] {
            var changed = user; changed[key] = value
            XCTAssertThrowsError(try HostUserIdentityBinding.decode(data(user: changed), hostID: hostID), key)
        }
        let fraction = String(decoding: try data(), as: UTF8.self).replacingOccurrences(of: "\"uid\":501", with: "\"uid\":501.5")
        XCTAssertThrowsError(try HostUserIdentityBinding.decode(Data(fraction.utf8), hostID: hostID))
    }

    func testEveryRealEffectiveUIDAndGIDMustMatchBeforeAccountLookup() throws {
        let encoded = try data()
        let selected = try HostUserIdentityBinding.decode(encoded, hostID: hostID).host_user
        let correct = HostUserProcessIdentity(realUID: 501, effectiveUID: 501, realGID: 20, effectiveGID: 20)
        XCTAssertEqual(try HostUserIdentityValidator.validate(file: URL(fileURLWithPath: "/unused"), hostID: hostID,
            read: { _ in encoded }, process: { correct }, lookup: { $0 }, home: { _ in }), selected)
        for current in [HostUserProcessIdentity(realUID: 0, effectiveUID: 501, realGID: 20, effectiveGID: 20),
            .init(realUID: 501, effectiveUID: 502, realGID: 20, effectiveGID: 20),
            .init(realUID: 501, effectiveUID: 501, realGID: 0, effectiveGID: 20),
            .init(realUID: 501, effectiveUID: 501, realGID: 20, effectiveGID: 80)] {
            var queried = false
            XCTAssertThrowsError(try HostUserIdentityValidator.validate(file: URL(fileURLWithPath: "/unused"), hostID: hostID,
                read: { _ in encoded }, process: { current }, lookup: { queried = true; return $0 }, home: { _ in }))
            XCTAssertFalse(queried)
        }
    }

    func testReusedUIDChangedHomeAndIdentityLookupFailureCannotPass() throws {
        let encoded = try data()
        let process = { HostUserProcessIdentity(realUID: 501, effectiveUID: 501, realGID: 20, effectiveGID: 20) }
        for (key, value) in [("generatedUID", UUID().uuidString), ("homeDirectory", "/Users/other"), ("recordName", "other")] {
            var changed = user; changed[key] = value
            let record = try HostUserIdentityBinding.decode(data(user: changed), hostID: hostID).host_user
            XCTAssertThrowsError(try HostUserIdentityValidator.validate(file: URL(fileURLWithPath: "/unused"), hostID: hostID,
                read: { _ in encoded }, process: process, lookup: { _ in record }, home: { _ in }))
        }
        XCTAssertThrowsError(try HostUserIdentityValidator.validate(file: URL(fileURLWithPath: "/unused"), hostID: hostID,
            read: { _ in encoded }, process: process, lookup: { _ in throw HostUserIdentityError.lookupUnavailable(EIO) }, home: { _ in }))
        XCTAssertThrowsError(try HostUserIdentityValidator.validate(file: URL(fileURLWithPath: "/unused"), hostID: hostID,
            read: { _ in encoded }, process: process, lookup: { $0 }, home: { _ in throw HostUserIdentityError.identityMismatch }))
    }

    func testReentrantLookupExpansionIsBoundedAndUnknownIsFailure() throws {
        var sizes: [Int] = []
        XCTAssertThrowsError(try HostUserAccountLookup.bounded { buffer in
            sizes.append(buffer.count); return .init(status: ERANGE, record: nil)
        }) { XCTAssertEqual($0 as? HostUserIdentityError, .lookupUnavailable(ERANGE)) }
        XCTAssertEqual(sizes, [16384, 32768, 65536, 131072, 262144, 524288, 1048576])
        XCTAssertThrowsError(try HostUserAccountLookup.bounded { _ in .init(status: 0, record: nil) })
    }

    func testOwnedHomeRejectsSymlinkComponentsAndNonDirectory() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("identity-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = HostUserIdentity(recordName: "operator", uid: geteuid(), primaryGID: getegid(),
            generatedUID: user["generatedUID"] as! String, homeDirectory: directory.path)
        try HostUserAccountLookup.requireOwnedHome(selected)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let linked = HostUserIdentity(recordName: selected.recordName, uid: selected.uid, primaryGID: selected.primaryGID,
            generatedUID: selected.generatedUID, homeDirectory: alias.path)
        XCTAssertThrowsError(try HostUserAccountLookup.requireOwnedHome(linked))
    }

    func testProductionServeRejectsUnprotectedBindingBeforeRuntimeAuthority() async throws {
        let arguments = validOptions(identity: "/private/tmp/unprotected-missing-host-user.json")
        do { try await ServeCommand.run(arguments); XCTFail("identity must fail before acquiring machine EX") }
        catch { XCTAssertEqual(error as? HostUserIdentityError, .insecureFile) }
    }

    func testEveryServeModeRequiresCanonicalIdentityFile() throws {
        for flags in [[], ["--development-ad-hoc-lume"], ["--allow-insecure-loopback"],
                      ["--development-ad-hoc-lume", "--allow-insecure-loopback"]] {
            var options = validOptions(identity: "/Library/Host/host-user.json")
            options.removeFirst(2)
            XCTAssertThrowsError(try ServeCommand.Options(options + flags))
        }
        for path in ["relative", "/Library/../host-user.json", "/Library//host-user.json", "/Library/./host-user.json"] {
            XCTAssertThrowsError(try ServeCommand.Options(validOptions(identity: path)))
        }
    }

    func validOptions(identity: String) -> [String] {
        ["--host-identity-file", identity, "--host-id", hostID.uuidString,
         "--coordinator", "wss://example.test/ws/sandbox-host", "--token-file", "/private/host/token",
         "--lume", "/Library/Host/lume", "--storage", "/private/host/vms", "--capacity-dir", "/private/host/capacity",
         "--base-images", "base-v1", "--max-cpu", "8", "--max-memory-gib", "16"]
    }
}
