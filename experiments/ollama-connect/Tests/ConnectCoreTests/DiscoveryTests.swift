import Darwin
import Foundation
import Testing
@testable import ConnectCore

@Test func onlyFixedMetadataEndpointsExist() {
    let paths = Set(MetadataEndpoint.allCases.map { $0.url.path })
    #expect(paths == ["/api/tags", "/api/ps", "/v1/models/catalog", "/v1/providers/attestation"])
    for endpoint in MetadataEndpoint.allCases {
        #expect(endpoint.url.user == nil && endpoint.url.password == nil && endpoint.url.query == nil)
        #expect(endpoint.url.host == "127.0.0.1" || endpoint.url.host == "api.darkbloom.dev")
    }
}

@Test func hostileOllamaNamesRemainInertData() throws {
    let data = Data(#"{"models":[{"name":"$(touch /tmp/compromised)","size":1,"digest":"fake"},{"name":"valid","size":2,"digest":"fake"},{"name":"valid","size":2,"digest":"fake"},{"name":"bad\nline","size":2,"digest":"fake"}]}"#.utf8)
    let models = try OllamaDiscovery.decode(data)
    #expect(models.count == 2)
    #expect(throws: ConnectError.invalidModel) { try SetupHandoff.validate(.download(models[0].name), catalog: []) }
    #expect(throws: ConnectError.invalidModel) { try SetupHandoff.validate(.start(models[1].name), catalog: []) }
}

@Test func oversizedDiscoveryRejected() {
    #expect(throws: ConnectError.oversized) { try OllamaDiscovery.decode(Data(repeating: 32, count: 1_048_577)) }
}

@Test func diskInventoryDoesNotFollowSymlinksOrReadLargeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("registry.ollama.ai/library/qwen3.8")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = Data(#"{"layers":[{"size":1234}]}"#.utf8)
    let manifest = directory.appendingPathComponent("27b")
    try fixture.write(to: manifest)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked"), withDestinationURL: manifest)
    #expect(OllamaDiscovery.diskModels(at: root).map(\.name) == ["qwen3.8:27b"])
    let namespaced = root.appendingPathComponent("registry.ollama.ai/custom/qwen3.8")
    try FileManager.default.createDirectory(at: namespaced, withIntermediateDirectories: true)
    try fixture.write(to: namespaced.appendingPathComponent("27b"))
    #expect(Set(OllamaDiscovery.diskModels(at: root).map(\.name)) == ["qwen3.8:27b", "custom/qwen3.8:27b"])
    #expect(throws: ConnectError.unsafeFile) { try SafeFile.read(directory.appendingPathComponent("linked")) }
    let large = root.appendingPathComponent("oversized")
    try Data(repeating: 0, count: 1025).write(to: large)
    #expect(throws: ConnectError.unsafeFile) { try SafeFile.read(large, limit: 1024) }
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: ConnectError.unsafeFile) { try SafeFile.read(fifo) }
}

@Test func signedUnrelatedExecutableIsNotOurWorker() {
    #expect(throws: ConnectError.untrustedWorker) { try WorkerIdentity.inspect(URL(fileURLWithPath: "/usr/bin/true")) }
    #expect(KernelIdentity.read(-1) == nil)
    #expect(KernelIdentity.read(getpid())?.pid == getpid())
}
