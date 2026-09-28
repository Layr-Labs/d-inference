import Foundation
import Testing
import TOMLKit
@testable import ProviderCore

@Suite("Saved cluster setup")
struct ClusterConfigurationTests {
    private func reference(_ character: String = "a") throws -> ClusterConfigurationReference {
        try ClusterConfigurationReference(configuration: "/Users/fixture/.config/darkbloom/clusters/fixture.cluster.json",
                                          sha256: String(repeating: character, count: 64))
    }

    @Test("absent setup retains ordinary provider defaults and remains absent on encode")
    func absent() throws {
        let original = ProviderConfig(provider: ProviderSettings(name: "fixture"))
        #expect(original.cluster == nil)
        let encoded = ConfigManager.serialize(original)
        #expect(!encoded.contains("[cluster]"))
        #expect(try ConfigManager.parseValidating(encoded) == original)
    }

    @Test("saved reference is inert and rejects extra enable or ownership fields")
    func referenceRoundTrip() throws {
        var config = ProviderConfig(provider: ProviderSettings(name: "fixture"))
        config.cluster = try reference()
        let text = ConfigManager.serialize(config)
        #expect(try ConfigManager.parseValidating(text).cluster == config.cluster)
        for extra in ["enabled = true", "capacity = 12", "device_lease = '/tmp/bypass'"] {
            let invalid = "[cluster]\nconfiguration = '/Users/fixture/config'\nsha256 = '\(String(repeating: "a", count: 64))'\n\(extra)\n"
            #expect(throws: (any Error).self) { _ = try ConfigManager.parseValidating(invalid) }
        }
    }

    @Test("pointer insertion preserves unrelated raw TOML values and migration stamp")
    func unrelatedValues() throws {
        let old = """
        config_version = 1
        [provider]
        name = 'fixture'
        [backend]
        engine_v2_max_concurrent = 8
        mtp = false
        [future_extension]
        value = 1.25
        enabled = true
        list = ['one', 'two']
        """
        let bytes = try ClusterConfigurationStore.updatingProviderData(Data(old.utf8), reference: reference())
        let updated = String(decoding: bytes, as: UTF8.self)
        let before = try TOMLTable(string: old), after = try TOMLTable(string: updated)
        #expect(after["config_version"]?.int == 1)
        #expect(after["future_extension"] != nil)
        after.remove(at: "cluster")
        #expect(before == after)
        #expect(try ConfigManager.parseValidating(updated).cluster == reference())
    }

    @Test("repeated pointer save preserves exact existing bytes")
    func repeatBytes() throws {
        let value = try reference()
        let old = Data("# keep this comment\n[cluster]\nconfiguration = '\(value.configuration)'\nsha256 = '\(value.sha256)'\n".utf8)
        #expect(try ClusterConfigurationStore.updatingProviderData(old, reference: value) == old)
    }

    @Test("malformed existing TOML is refused; new minimal setup does not encode enabled state")
    func refusalAndCreation() throws {
        #expect(throws: (any Error).self) {
            _ = try ClusterConfigurationStore.updatingProviderData(Data("[broken".utf8), reference: reference())
        }
        #expect(throws: (any Error).self) {
            _ = try ClusterConfigurationStore.updatingProviderData(Data([0xff]), reference: reference())
        }
        let fresh = try ClusterConfigurationStore.updatingProviderData(nil, reference: reference())
        let text = String(decoding: fresh, as: UTF8.self)
        #expect(try ConfigManager.parseValidating(text).cluster == reference())
        #expect(!text.contains("enabled"))
        #expect(!text.contains("capacity"))
        #expect(!text.contains("config_version"))
    }
}
