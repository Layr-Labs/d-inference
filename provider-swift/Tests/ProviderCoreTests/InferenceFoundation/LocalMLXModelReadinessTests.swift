import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Test func localMLXReadinessAcceptsMinimalLocalDirectory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let modelDirectory = root.appendingPathComponent("models--local--tiny/snapshots/abc", isDirectory: true)
    try createFakeModelDirectory(at: modelDirectory)

    let configuration = LocalMLXModelConfiguration(
        modelID: "local/tiny",
        modelDirectory: modelDirectory
    )
    let readiness = LocalMLXModelReadiness.inspect(configuration)

    #expect(readiness.canAttemptLoad)
    #expect(readiness.issues.isEmpty)
    #expect(readiness.configJSON == modelDirectory.appendingPathComponent("config.json").standardizedFileURL)
    #expect(readiness.tokenizerFiles.map(\.url.lastPathComponent) == ["tokenizer.json"])
    #expect(readiness.weightFiles.map(\.url.lastPathComponent) == ["model.safetensors"])
    #expect(readiness.totalWeightBytes == 4)

    switch configuration.modelConfiguration.id {
    case .directory(let url):
        #expect(url == modelDirectory.standardizedFileURL)
    case .id:
        Issue.record("local configuration must not resolve through a remote model id")
    }
    #expect(configuration.modelConfiguration.tokenizerSource == nil)
}

@Test func localMLXReadinessSupportsSeparateTokenizerDirectory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
    let tokenizerDirectory = root.appendingPathComponent("tokenizer", isDirectory: true)
    try createFakeModelDirectory(at: modelDirectory, includeTokenizer: false)
    try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
    try "{}".write(
        to: tokenizerDirectory.appendingPathComponent("tokenizer.json"),
        atomically: true,
        encoding: .utf8
    )

    let configuration = LocalMLXModelConfiguration(
        modelDirectory: modelDirectory,
        tokenizerDirectory: tokenizerDirectory
    )
    let readiness = LocalMLXModelReadiness.inspect(configuration)

    #expect(readiness.canAttemptLoad)
    #expect(readiness.issues.isEmpty)
    #expect(readiness.tokenizerFiles.map(\.url.lastPathComponent) == ["tokenizer.json"])
    #expect(
        configuration.modelConfiguration.tokenizerSource
            == TokenizerSource.directory(tokenizerDirectory.standardizedFileURL)
    )
}

@Test func localMLXReadinessReportsMissingRequiredFiles() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let modelDirectory = root.appendingPathComponent("empty-model", isDirectory: true)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

    let configuration = LocalMLXModelConfiguration(modelDirectory: modelDirectory)
    let readiness = LocalMLXModelReadiness.inspect(configuration)
    let issueKinds = Set(readiness.issues.map(\.kind))

    #expect(!readiness.canAttemptLoad)
    #expect(
        issueKinds == [
            .configJSONMissing,
            .tokenizerFilesMissing,
            .weightFilesMissing,
        ]
    )
}

@Test func localMLXReadinessReportsMissingModelDirectory() {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
    let configuration = LocalMLXModelConfiguration(modelDirectory: missingDirectory)
    let readiness = LocalMLXModelReadiness.inspect(configuration)

    #expect(!readiness.canAttemptLoad)
    #expect(readiness.issues.map(\.kind) == [.modelDirectoryMissing])
    #expect(readiness.weightFiles.isEmpty)
    #expect(readiness.tokenizerFiles.isEmpty)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderCoreFoundationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func createFakeModelDirectory(
    at directory: URL,
    includeTokenizer: Bool = true
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"model_type":"llama"}"#.write(
        to: directory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
    )
    if includeTokenizer {
        try "{}".write(
            to: directory.appendingPathComponent("tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
    }
    try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("model.safetensors"))
}
