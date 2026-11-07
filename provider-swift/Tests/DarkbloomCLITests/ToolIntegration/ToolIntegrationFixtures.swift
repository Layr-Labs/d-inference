import Foundation
import Testing

@testable import darkbloom

/// Inputs shared by the tool integration tests. The planners are pure, so their home and key file are fixed paths
/// that are never read; the writer and end-to-end tests use temp directories.
enum ToolIntegrationFixtures {
    static let provider = IntegrationProvider(id: "darkbloom", name: "Darkbloom")
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    static let endpoint = IntegrationEndpoint(
        baseURL: "http://127.0.0.1:8123/v1",
        keyFile: URL(fileURLWithPath: "/Users/tester/.darkbloom/local_token"))

    /// 32K context: OpenCode can use it, Hermes can't.
    static let gemma = IntegrationModel(
        id: "gemma-4-26b-qat-4bit", name: "Gemma 4 26B QAT (this Mac)", location: .thisMac,
        contextLength: 32_768, outputLimit: 8_192, tools: true, imageInput: true, reasoning: false)
    static let qwen = IntegrationModel(
        id: "qwen3.8-27b", name: "Qwen 3.8 27B (this Mac)", location: .thisMac,
        contextLength: 131_072, outputLimit: 32_768, tools: true, imageInput: false, reasoning: true)
    static let glm = IntegrationModel(
        id: "glm-5.3-flash", name: "GLM-5.3-Flash (your Macs)", location: .yourMacs,
        contextLength: 98_304, outputLimit: 24_576, tools: true, imageInput: true, reasoning: true)

    static let models = [gemma, qwen, glm]

    /// A key in Darkbloom's format, made fresh per test so a leak can't match by accident.
    static func freshToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return "dk-local-" + String((0..<43).map { _ in alphabet.randomElement()! })
    }

    static func utf8(_ data: Data?) -> String { String(decoding: data ?? Data(), as: UTF8.self) }

    static func newText(_ plan: ToolConfigPlan) -> String? {
        if case .change(let data, _) = plan { return utf8(data) }
        return nil
    }

    static func summary(_ plan: ToolConfigPlan) -> ToolConfigSummary? {
        switch plan {
        case .change(_, let summary), .unchanged(let summary): summary
        case .refused: nil
        }
    }

    static func refusal(_ plan: ToolConfigPlan) -> ToolConfigRefusal? {
        if case .refused(let refusal) = plan { return refusal }
        return nil
    }
}

/// A temp directory that is removed at the end of the test.
final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "tool-integration") throws {
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ text: String, to relative: String, mode: mode_t? = nil) throws -> URL {
        let target = file(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        if let mode { chmod(target.path, mode) }
        return target
    }

    /// Every regular file under the directory, at any depth.
    func allFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

func posixMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o7777
}
