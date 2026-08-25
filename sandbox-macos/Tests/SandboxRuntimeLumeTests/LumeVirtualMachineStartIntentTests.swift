import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeVirtualMachineStartIntentTests: XCTestCase {
    func testPersistsOnePrivateIntentAndMatchesRotatedFencingToken()
        throws
    {
        let initialScope = Self.scope(fencingToken: 7)
        let fixture = try StartIntentFixture(scope: initialScope)
        defer { try? fixture.remove() }

        let intent = try fixture.persist(scope: initialScope)
        let metadata = try fixture.intentMetadata()
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(
            try fixture.intentAuthorityEntries(),
            [LumeVirtualMachineStartIntent.fileName]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.intentFile)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            object["lifecycleControl"] as? String,
            "broker_eof_v1"
        )
        XCTAssertEqual(
            (object["intentID"] as? String)?.lowercased(),
            intent.intentID.uuidString.lowercased()
        )
        XCTAssertEqual(
            (object["installationID"] as? String)?.lowercased(),
            fixture.ownership.installationID.uuidString.lowercased()
        )
        XCTAssertEqual(object["ownerKind"] as? String, "sandbox")
        XCTAssertEqual(
            (object["sandboxID"] as? String)?.lowercased(),
            initialScope.sandboxID.description
        )
        XCTAssertEqual(
            object["sandboxGeneration"] as? Int,
            Int(initialScope.generation.rawValue)
        )
        XCTAssertEqual(
            object["initiatingFencingToken"] as? Int,
            Int(initialScope.fencingToken.rawValue)
        )

        let rotatedScope = SandboxOperationScope(
            sandboxID: initialScope.sandboxID,
            generation: initialScope.generation,
            fencingToken: try XCTUnwrap(
                SandboxFencingToken(rawValue: 8)
            )
        )
        let presence = try LumeVirtualMachineStartIntent.presence(
            name: fixture.name,
            ownership: fixture.ownership,
            owner: .init(operationScope: rotatedScope),
            in: fixture.storage
        )
        guard case .unresolved(let rotatedIntent) = presence else {
            return XCTFail("rotated fence must retain the unresolved intent")
        }
        XCTAssertEqual(rotatedIntent.intentID, intent.intentID)
        XCTAssertEqual(
            rotatedIntent.initiatingFencingToken,
            initialScope.fencingToken
        )
        XCTAssertThrowsError(try fixture.persist(scope: rotatedScope))
        XCTAssertEqual(
            try fixture.intentAuthorityEntries(),
            [LumeVirtualMachineStartIntent.fileName]
        )
    }

    func testPersistsBaseTemplateOwnerWithoutSandboxFence() throws {
        let fixture = try StartIntentFixture(scope: nil)
        defer { try? fixture.remove() }

        let intent = try fixture.persist(scope: nil)

        XCTAssertEqual(intent.owner, .baseTemplate)
        XCTAssertNil(intent.initiatingFencingToken)
        let presence = try LumeVirtualMachineStartIntent.presence(
            name: fixture.name,
            ownership: fixture.ownership,
            owner: .baseTemplate,
            in: fixture.storage
        )
        guard case .unresolved(let loaded) = presence else {
            return XCTFail("base-template start intent was not durable")
        }
        XCTAssertEqual(loaded.intentID, intent.intentID)
        XCTAssertThrowsError(
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: fixture.name,
                ownership: fixture.ownership,
                owner: .baseTemplate,
                in: fixture.storage
            )
        )
        try LumeVirtualMachineStartIntent.resolveAfterRunningObserved(
            presence,
            name: fixture.name,
            ownership: fixture.ownership,
            owner: .baseTemplate,
            observedState: .running,
            in: fixture.storage
        )
        XCTAssertEqual(try fixture.load(), .absent)
    }

    func testFailedStartClearsOnlyWithTerminalProof() throws {
        let scope = Self.scope()
        let fixture = try StartIntentFixture(scope: scope)
        defer { try? fixture.remove() }
        let intent = try fixture.persist(scope: scope)

        XCTAssertThrowsError(
            try LumeVirtualMachineStartIntent.clearAfterFailedStart(
                intent,
                name: fixture.name,
                ownership: fixture.ownership,
                owner: fixture.owner,
                terminalState: .starting,
                in: fixture.storage
            )
        )
        guard case .unresolved = try fixture.load() else {
            return XCTFail("non-terminal state cleared the start intent")
        }

        try LumeVirtualMachineStartIntent.clearAfterFailedStart(
            intent,
            name: fixture.name,
            ownership: fixture.ownership,
            owner: fixture.owner,
            terminalState: .stopped,
            in: fixture.storage
        )
        XCTAssertEqual(try fixture.load(), .absent)
    }

    func testRejectsMalformedStartIntentAuthority() throws {
        let fixture = try StartIntentFixture(scope: Self.scope())
        defer { try? fixture.remove() }
        try Data("{not-json".utf8).write(to: fixture.intentFile)
        try fixture.makeIntentPrivate()

        XCTAssertThrowsError(try fixture.load())
    }

    func testRejectsPreCapabilityStartIntentVersion() throws {
        let fixture = try StartIntentFixture(scope: Self.scope())
        defer { try? fixture.remove() }
        _ = try fixture.persist(scope: fixture.scope)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.intentFile)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "lifecycleControl")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fixture.intentFile)
        try fixture.makeIntentPrivate()

        XCTAssertThrowsError(try fixture.load()) { error in
            XCTAssertEqual(
                error as? SandboxRuntimeError,
                .unsupported(
                    "VM \(fixture.name) start intent has an unsupported version"
                )
            )
        }
    }

    func testRejectsIntentFromDifferentVMInstallation() throws {
        let scope = Self.scope()
        let fixture = try StartIntentFixture(scope: scope)
        defer { try? fixture.remove() }
        _ = try fixture.persist(scope: scope)
        try fixture.replaceOwnership(scope: scope)
        let replacement = try fixture.currentOwnership(scope: scope)

        XCTAssertNotEqual(
            replacement.installationID,
            fixture.ownership.installationID
        )
        XCTAssertThrowsError(
            try LumeVirtualMachineStartIntent.presence(
                name: fixture.name,
                ownership: replacement,
                owner: .init(operationScope: scope),
                in: fixture.storage
            )
        )
    }

    func testRejectsIntentFromDifferentSandboxGeneration() throws {
        let scope = Self.scope()
        let fixture = try StartIntentFixture(scope: scope)
        defer { try? fixture.remove() }
        _ = try fixture.persist(scope: scope)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.intentFile)
            ) as? [String: Any]
        )
        object["sandboxGeneration"] = Int(scope.generation.rawValue + 1)
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fixture.intentFile)
        try fixture.makeIntentPrivate()

        XCTAssertThrowsError(try fixture.load())
    }

    func testRejectsHardlinkedSymlinkedAndACLIntentAuthority() throws {
        enum Mutation: CaseIterable {
            case hardlink
            case symlink
            case acl
        }
        for mutation in Mutation.allCases {
            let scope = Self.scope()
            let fixture = try StartIntentFixture(scope: scope)
            defer { try? fixture.remove() }
            _ = try fixture.persist(scope: scope)

            switch mutation {
            case .hardlink:
                try FileManager.default.linkItem(
                    at: fixture.intentFile,
                    to: fixture.root.appendingPathComponent("intent-alias")
                )
            case .symlink:
                let target = fixture.root.appendingPathComponent(
                    "intent-target"
                )
                try FileManager.default.copyItem(
                    at: fixture.intentFile,
                    to: target
                )
                try FileManager.default.removeItem(at: fixture.intentFile)
                try FileManager.default.createSymbolicLink(
                    at: fixture.intentFile,
                    withDestinationURL: target
                )
            case .acl:
                try Self.addExtendedACL(to: fixture.intentFile)
            }

            XCTAssertThrowsError(
                try fixture.load(),
                "\(mutation) authority must fail closed"
            )
        }
    }

    func testRejectsNonPrivateNonRegularAndOversizedIntentAuthority()
        throws
    {
        enum Mutation: CaseIterable {
            case sharedMode
            case directory
            case fifo
            case oversized
        }
        for mutation in Mutation.allCases {
            let scope = Self.scope()
            let fixture = try StartIntentFixture(scope: scope)
            defer { try? fixture.remove() }

            switch mutation {
            case .sharedMode:
                try Data("{}".utf8).write(to: fixture.intentFile)
                guard chmod(fixture.intentFile.path, 0o640) == 0 else {
                    throw POSIXError(.EACCES)
                }
            case .directory:
                try FileManager.default.createDirectory(
                    at: fixture.intentFile,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            case .fifo:
                guard mkfifo(fixture.intentFile.path, 0o600) == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            case .oversized:
                try Data(repeating: 0x41, count: 20 * 1_024).write(
                    to: fixture.intentFile
                )
                try fixture.makeIntentPrivate()
            }

            XCTAssertThrowsError(
                try fixture.load(),
                "\(mutation) authority must fail closed"
            )
        }
    }

    private static func scope(
        fencingToken: UInt64 = 1
    ) -> SandboxOperationScope {
        SandboxOperationScope(
            sandboxID: SandboxID(
                rawValue: UUID(
                    uuidString: "B09C1568-405D-4ACF-B75D-56B8930D7E53"
                )!
            ),
            generation: SandboxGeneration(rawValue: 3)!,
            fencingToken: SandboxFencingToken(
                rawValue: fencingToken
            )!
        )
    }

    private static func addExtendedACL(to url: URL) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            "everyone allow read,write",
            url.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
    }
}

private struct StartIntentFixture {
    let root: URL
    let storage: URL
    let virtualMachineDirectory: URL
    let intentFile: URL
    let name: String
    let scope: SandboxOperationScope?
    let owner: LumeVirtualMachineOwnership.Owner
    let specification: SandboxVirtualMachineSpecification
    let ownership: LumeVirtualMachineOwnership.Identity

    init(scope: SandboxOperationScope?) throws {
        let name = "sandbox-start-intent-test"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-start-intent-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent("vms", isDirectory: true)
        let virtualMachineDirectory = storage.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: virtualMachineDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        let specification = try SandboxVirtualMachineSpecification(
            name: name,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .localTemplate(name: "sandbox-base"),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        try LumeVirtualMachineOwnership.write(
            specification: specification,
            owner: owner,
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
        )
        let ownership = try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            owner: owner,
            in: storage
        )

        self.root = root
        self.storage = storage
        self.virtualMachineDirectory = virtualMachineDirectory
        self.name = name
        intentFile = virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineStartIntent.fileName
        )
        self.scope = scope
        self.owner = owner
        self.specification = specification
        self.ownership = ownership
    }

    func persist(
        scope: SandboxOperationScope?
    ) throws -> LumeVirtualMachineStartIntent.Intent {
        try LumeVirtualMachineStartIntent.persist(
            name: name,
            ownership: ownership,
            owner: .init(operationScope: scope),
            initiatingScope: scope,
            in: storage
        )
    }

    func load() throws -> LumeVirtualMachineStartIntent.Presence {
        try LumeVirtualMachineStartIntent.presence(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storage
        )
    }

    func currentOwnership(
        scope: SandboxOperationScope?
    ) throws -> LumeVirtualMachineOwnership.Identity {
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            owner: .init(operationScope: scope),
            in: storage
        )
    }

    func replaceOwnership(scope: SandboxOperationScope?) throws {
        try LumeVirtualMachineOwnership.write(
            specification: specification,
            owner: .init(operationScope: scope),
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
        )
    }

    func intentMetadata() throws -> stat {
        var metadata = stat()
        guard lstat(intentFile.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata
    }

    func intentAuthorityEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: virtualMachineDirectory.path
        )
        .filter { $0.contains("start-intent") }
        .sorted()
    }

    func makeIntentPrivate() throws {
        guard chmod(intentFile.path, 0o600) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }
}
