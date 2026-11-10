import Foundation
import Testing
@testable import ProviderCore

@Test func gemmaProcessorIdentityAcceptsEitherFactoryMetadataLayoutAndBindsBoth() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.json")
    let processor = directory.appendingPathComponent("processor_config.json")
    let preprocessor = directory.appendingPathComponent("preprocessor_config.json")
    try Data("{}".utf8).write(to: config)
    #expect(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu") == nil)
    // The exact incident artifact has processor_config.json and no preprocessor file.
    try Data(#"{"processor_class":"Gemma4Processor","image_seq_length":280}"#.utf8).write(to: processor)
    let processorOnly = try #require(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    #expect(processorOnly == GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    #expect(processorOnly != GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "cpu"))
    try Data(#"{"image_seq_length":140}"#.utf8).write(to: preprocessor)
    let both = try #require(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    #expect(both != processorOnly)
    try Data(#"{"processor_class":"Gemma4Processor","image_seq_length":560}"#.utf8).write(to: processor)
    #expect(both != GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    try FileManager.default.removeItem(at: processor)
    let preprocessorOnly = try #require(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    #expect(preprocessorOnly != both)
    try Data(#"{"model_type":"gemma4"}"#.utf8).write(to: config)
    #expect(preprocessorOnly != GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu"))
    try Data(repeating: 0, count: 64 * 1024 + 1).write(to: preprocessor)
    #expect(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu") == nil)
    try FileManager.default.removeItem(at: config)
    #expect(GemmaVisionProcessorIdentity.fingerprint(directory: directory, device: "gpu") == nil)
}
