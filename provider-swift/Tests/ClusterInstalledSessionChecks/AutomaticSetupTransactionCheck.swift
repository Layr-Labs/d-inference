import Foundation
import Darwin
@testable import InstalledContract

extension InstalledSessionCheck {
    /// Real canonical store, device locks, pointer files and compensation.
    /// Only the unchanged TOML adapter is replaced by a tiny JSON fixture.
    static func automaticSetupTransaction(_ f: InstalledFixture) throws {
        let folder = f.root.appendingPathComponent("transaction", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let first = folder.appendingPathComponent("a-provider.json"), second = folder.appendingPathComponent("b-owner.json")
        struct Pointer: Codable { var cluster: ClusterConfigurationReference; var unrelated: String }
        func parse(_ bytes: Data) throws -> ClusterConfigurationReference { try JSONDecoder().decode(Pointer.self, from: bytes).cluster }
        func update(_ bytes: Data, _ reference: ClusterConfigurationReference) throws -> Data {
            var value = try JSONDecoder().decode(Pointer.self, from: bytes)
            value.cluster = reference
            return try JSONEncoder().encode(value)
        }
        let original = try JSONEncoder().encode(Pointer(cluster: f.reference, unrelated: "preserved"))
        func reset() throws {
            for file in [first, second] { try ClusterConfigurationFiles.update(file, maximum: 1_048_576) { _ in original } }
        }
        let oldBytes = try Data(contentsOf: URL(fileURLWithPath: f.reference.configuration))
        var object = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        object["batchLanes"] = 4
        let configuration = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object),
            capability: f.capability, capabilitySHA256: f.configuration.capabilitySHA256)
        let bytes = try ClusterConfigurationCodec.encode(configuration, capability: f.capability,
            capabilitySHA256: f.configuration.capabilitySHA256)
        let change = ClusterAutomaticBatchSetup(previousSHA256: f.reference.sha256, configuration: bytes)
        func apply(_ change: ClusterAutomaticBatchSetup, before: (ClusterConfigurationReference, ClusterConfigurationReference) throws -> Void = { _, _ in },
                   updating: ((Data, ClusterConfigurationReference) throws -> Data)? = nil) throws -> ClusterConfigurationReference {
            try change.applyTransaction(paths: f.paths, providerConfigurations: [second, first, first], directory: folder,
                parseReference: parse, updateProvider: updating ?? update, beforePointerUpdate: before)
        }
        try reset()
        let selected = try apply(change)
        for file in [first, second] {
            let pointer = try JSONDecoder().decode(Pointer.self, from: ClusterConfigurationFiles.read(file, maximum: 1_048_576, privateMode: true))
            try require(pointer.cluster == selected && pointer.unrelated == "preserved", "adoption did not preserve both pointer values")
        }
        try require(try apply(change) == selected, "lost-reply retry was not idempotent")
        let rollback = ClusterAutomaticBatchSetup(previousSHA256: selected.sha256, configuration: oldBytes)
        try require(try apply(rollback) == f.reference, "rollback did not restore exact old binding")
        try require(try apply(rollback) == f.reference, "lost rollback reply was not idempotent")
        try reset()
        var calls = 0
        try rejected {
            _ = try apply(change, updating: { data, reference in
                calls += 1
                if calls == 2 { throw NSError(domain: "second-pointer-write", code: 1) }
                return try update(data, reference)
            })
        }
        for file in [first, second] {
            try require(try Data(contentsOf: file) == original, "partial pointer write was not compensated byte exactly")
        }
        try reset()
        let operatorBytes = try JSONEncoder().encode(Pointer(cluster: f.reference, unrelated: "operator edit"))
        var writes = 0
        try rejected {
            _ = try apply(change, updating: { data, reference in
                writes += 1
                if writes == 2 {
                    try ClusterConfigurationFiles.update(first, maximum: 1_048_576) { _ in operatorBytes }
                    throw NSError(domain: "concurrent-edit", code: 2)
                }
                return try update(data, reference)
            })
        }
        try require(try Data(contentsOf: first) == operatorBytes, "rollback overwrote an independent operator edit")
        try reset()
        let device = try ClusterConfigurationFiles.directory(f.paths.deviceDirectory, create: true, privateMode: true)
        defer { close(device.descriptor) }
        // The normal save gate must refuse while any native owner holds it.
        try ClusterConfigurationFiles.withLock(device, name: f.paths.deviceLeaseFile.lastPathComponent,
            requireEmpty: true, privateMode: true) {
            try rejected { _ = try apply(change) }
        }
        try require(try parse(Data(contentsOf: first)) == f.reference, "a held device gate changed a pointer")
        try reset()
        try rejected {
            _ = try change.applyTransaction(paths: f.paths, providerConfigurations: [first, second], directory: folder,
                senderMemberID: "foreign", parseReference: parse, updateProvider: update)
        }
        print("Automatic setup transaction: actual-store adoption, idempotent replies, exact rollback, partial failure, operator CAS and held-device refusal passed")
    }
}
