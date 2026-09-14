import Foundation
import Testing

@testable import ProviderCore

// Scan-integration coverage for the template-render self-check: the scanner's
// `parseModelInfo` must stamp `templateRenderOK` on the advertised ModelInfo
// (true / false / nil per TemplateRenderCheck), and the scan must survive any
// template content without throwing. The check logic itself is covered in
// ProviderCoreFoundationTests/TemplateRenderCheckTests; these tests pin the
// wiring.

private func makeSnapshot(template: String?, configJSON: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-template-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(configJSON.utf8).write(to: dir.appendingPathComponent("config.json"))
    // Non-empty weight file so parseModelInfo's sizeBytes > 0 guard passes.
    try Data("mlx!".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
    if let template {
        try Data(template.utf8).write(to: dir.appendingPathComponent("chat_template.jinja"))
    }
    return dir
}

@Test func parseModelInfoStampsTemplateRenderOKTrue() throws {
    let dir = try makeSnapshot(
        template: "{% for m in messages %}{{ m['role'] }}{% endfor %}",
        configJSON: #"{"model_type": "qwen3"}"#
    )
    defer { try? FileManager.default.removeItem(at: dir) }

    let info = try #require(ModelScanner.parseModelInfo(snapshotDir: dir, modelName: "org/healthy"))
    #expect(info.templateRenderOK == true)
}

@Test func parseModelInfoStampsTemplateRenderOKFalse() throws {
    // Incident class: the template indexes a key that legitimate tool
    // declarations don't carry, throwing only on the tool fixture.
    let dir = try makeSnapshot(
        template: "{% if tools %}{% for t in tools %}{{ t['function']['response']['type'] | upper }}{% endfor %}{% endif %}ok",
        configJSON: #"{"model_type": "qwen3"}"#
    )
    defer { try? FileManager.default.removeItem(at: dir) }

    let info = try #require(ModelScanner.parseModelInfo(snapshotDir: dir, modelName: "org/broken"))
    #expect(info.templateRenderOK == false)
}

@Test func parseModelInfoLeavesTemplateRenderOKNilWithoutTemplate() throws {
    let dir = try makeSnapshot(template: nil, configJSON: #"{"model_type": "qwen3"}"#)
    defer { try? FileManager.default.removeItem(at: dir) }

    let info = try #require(ModelScanner.parseModelInfo(snapshotDir: dir, modelName: "org/templateless"))
    #expect(info.templateRenderOK == nil)
}
