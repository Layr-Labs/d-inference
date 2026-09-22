import Foundation
import Testing
@testable import ConnectCore

private func catalog(_ overrides: [String: Any] = [:]) throws -> [NetworkModel] {
    var entry: [String: Any] = ["id": "approved/model-4bit", "display_name": "Approved Model", "size_gb": 16.3, "min_ram_gb": 36, "active": true, "model_type": "text", "aggregate_sha256": String(repeating: "a", count: 64), "required_provider_capabilities": ["apple_m5", "mlx_nax"]]
    entry.merge(overrides) { _, new in new }
    return try CatalogPolicy.decode(JSONSerialization.data(withJSONObject: ["models": [entry]]))
}

@Test(arguments: ["--coordinator", "../key", "org/../key", "org//model", "model;touch x", "$(id)", "x\ny", "/absolute", "org/model?host=evil"])
func injectedIdentifiersAreRejected(id: String) throws {
    #expect(!CatalogPolicy.validID(id))
    #expect(try catalog(["id": id]).isEmpty)
    #expect(throws: ConnectError.invalidModel) { try SetupHandoff.validate(.download(id), catalog: []) }
}

@Test func catalogPinsHashesAndHardwareRequirements() throws {
    #expect(try catalog(["aggregate_sha256": "not-a-hash"]).isEmpty)
    #expect(try catalog(["active": false]).isEmpty)
    #expect(try catalog(["size_gb": -1]).isEmpty)
    let model = try #require(catalog().first)
    #expect(CatalogPolicy.limitation(model, memoryGB: 128, chip: "Apple M4 Max") != nil)
    #expect(CatalogPolicy.limitation(model, memoryGB: 32, chip: "Apple M5 Max") != nil)
    #expect(CatalogPolicy.limitation(model, memoryGB: 128, chip: "Apple M5 Max") == nil)
    let unknown = try #require(catalog(["required_provider_capabilities": ["future-capability"]]).first)
    #expect(CatalogPolicy.limitation(unknown, memoryGB: 128, chip: "Apple M5 Max") != nil)
}

@Test func onlyCatalogIdentityReachesSetup() throws {
    let models = try catalog()
    try SetupHandoff.validate(.download("approved/model-4bit"), catalog: models)
    #expect(throws: ConnectError.invalidModel) { try SetupHandoff.validate(.download("ollama/model"), catalog: models) }
    #expect(throws: ConnectError.invalidModel) { try SetupHandoff.validate(.start("approved/model-4bit"), catalog: []) }
    let worker = WorkerIdentity(executable: URL(fileURLWithPath: "/a user's folder/darkbloom"), cdHash: Data())
    let script = SetupHandoff.script(action: .download("approved/model-4bit"), worker: worker, home: "/a user's folder")
    #expect(script.contains("codesign --verify --strict"))
    #expect(script.contains("exec /usr/bin/env -i"))
    #expect(script.contains("'approved/model-4bit'"))
    #expect(script.contains("'\"'\"'"))
    #expect(!script.contains("--no-auth") && !script.contains("--local-endpoint"))
}
