import Foundation

/// The `providers.<id>` block in OpenCode 2's global config.
///
/// The edit is a byte splice of the JSONC file, never a re-serialisation: the owner's comments, order, other
/// providers (a V1 `provider` map too) and default model stay exactly as they are. Only the provider's own value is
/// replaced, or the provider is appended; the top-level `model` is added only when the file has none.
enum OpenCodeConfigPlan {
    static let schemaURL = "https://opencode.ai/config.json"
    /// OpenCode's package for an OpenAI-compatible endpoint.
    static let package = "@opencode/ai/providers/openai-compatible"

    /// `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`: the last existing of `opencode.json` and
    /// `opencode.jsonc` (OpenCode loads both, `.jsonc` last, and saves to the same one), else a new `opencode.jsonc`.
    static func configFile(home: URL, variables: [String: String]) -> URL {
        let base = variables["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let directory = base.appendingPathComponent("opencode", isDirectory: true)
        let existing = globalFileNames.last { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        return directory.appendingPathComponent(existing ?? "opencode.jsonc")
    }

    /// The file's new bytes. A `.json` file stays strict JSON when it was: it gets no comment line. The top-level
    /// `model` is added only when neither this file nor, by `defaultModelElsewhere`, another global file sets one.
    static func plan(
        existing: Data?, fileName: String, endpoint: IntegrationEndpoint, models listed: [IntegrationModel],
        provider: IntegrationProvider, home: URL, defaultModelElsewhere: Bool = false
    ) -> ToolConfigPlan {
        guard !listed.isEmpty else {
            return .refused(.models("Darkbloom's endpoint lists no chat models yet, so OpenCode has none to use."))
        }
        let original = [UInt8](existing ?? Data())
        let fresh = original.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
        let bytes = fresh ? Array("{\n}\n".utf8) : original
        let document: JSONCDocument
        do {
            document = try JSONCDocument(bytes)
        } catch {
            return .refused(.file("it isn't valid JSON (line \(error.line))"))
        }
        guard let root = document.root.object else { return .refused(.file("it isn't a JSON object")) }
        // The provider's own model entries stand in for what the catalog didn't say (offline, or a model it doesn't
        // list), so such a run never downgrades a name or a capability.
        let entries = root.members(named: "providers").first?.value.object?.members(named: provider.id).first
            .map { modelEntries(in: $0.value, of: document) } ?? [:]
        let models = IntegrationModels.keeping(listed, entries: entries)
        var splice = Splice(document: document)
        let block = Block(provider: provider, endpoint: endpoint, models: models, home: home,
                          withComment: fileName.hasSuffix(".jsonc"), unit: splice.unit)

        var rootMembers: [[String]] = fresh ? [["\"$schema\": \(jsonString(schemaURL))"]] : []
        let modelKeys = root.members(named: "model")
        guard modelKeys.count < 2 else { return .refused(.file("it has two \"model\" keys")) }
        let defaultModel = modelKeys.isEmpty && !defaultModelElsewhere ? "\(provider.id)/\(models[0].id)" : nil
        if let defaultModel { rootMembers.append(["\"model\": \(jsonString(defaultModel))"]) }

        let change: ToolConfigSummary.ProviderChange
        let providersKeys = root.members(named: "providers")
        switch providersKeys.count {
        case 0:
            rootMembers.append(["\"providers\": {"] + block.member.map { splice.unit + $0 } + ["}"])
            change = .added
        case 1:
            guard let providers = providersKeys[0].value.object else {
                return .refused(.file("its \"providers\" isn't an object"))
            }
            let existingBlocks = providers.members(named: provider.id)
            guard existingBlocks.count < 2 else { return .refused(.file("it has two \"\(provider.id)\" providers")) }
            if let current = existingBlocks.first {
                let replacement = block.value(indent: splice.memberIndent(of: current, in: providers))
                change = splice.replace(current.value.start..<current.value.end, with: replacement) ? .updated : .unchanged
            } else {
                splice.append([block.member], to: providers)
                change = .added
            }
        default:
            return .refused(.file("it has two \"providers\" keys"))
        }
        if !rootMembers.isEmpty { splice.append(rootMembers, to: root) }

        let summary = ToolConfigSummary(
            provider: change, models: models.map(\.id), defaultModel: defaultModel,
            undescribed: models.filter { $0.fallback != nil && entries[$0.id] == nil }.map(\.id))
        guard splice.changesBytes else { return .unchanged(summary) }
        return verified(splice.result(), original: original, document: document, fileName: fileName,
                        provider: provider, summary: summary)
    }

    /// Re-reads the new bytes before they may be written: they must hold the provider block, and a strict JSON file
    /// must stay strict JSON. Also counts the owner's comments that didn't survive (those inside an old value).
    private static func verified(
        _ bytes: [UInt8], original: [UInt8], document: JSONCDocument, fileName: String, provider: IntegrationProvider,
        summary: ToolConfigSummary
    ) -> ToolConfigPlan {
        guard let written = try? JSONCDocument(bytes), let root = written.root.object,
              root.members(named: "providers").first?.value.object?.members(named: provider.id).count == 1 else {
            return .refused(.file("Darkbloom's edit of it didn't read back; nothing was written"))
        }
        if fileName.hasSuffix(".json"), !original.isEmpty,
           (try? JSONSerialization.jsonObject(with: Data(original))) != nil,
           (try? JSONSerialization.jsonObject(with: Data(bytes))) == nil {
            return .refused(.file("Darkbloom's edit would leave it no longer strict JSON; nothing was written"))
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var summary = summary
        summary.droppedComments = document.comments.filter { range in
            !text.contains(String(decoding: document.bytes[range], as: UTF8.self))
        }.count
        return .change(Data(bytes), summary)
    }

    /// What the provider's value says of each model now, by model ID. An entry that doesn't read as one Darkbloom
    /// writes holds nothing.
    static func modelEntries(
        in value: JSONCDocument.Value, of document: JSONCDocument
    ) -> [String: IntegrationModel.Entry] {
        guard let models = value.object?.members(named: "models").first?.value.object else { return [:] }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        var entries: [String: IntegrationModel.Entry] = [:]
        for member in models.members {
            let bytes = Data(document.bytes[member.value.start..<member.value.end])
            guard let written = try? decoder.decode(WrittenModel.self, from: bytes) else { continue }
            entries[member.key] = IntegrationModel.Entry(
                displayName: written.name.map(IntegrationModel.displayName(in:)),
                contextLength: written.limit?.context, outputLimit: written.limit?.output,
                tools: written.capabilities?.tools,
                imageInput: written.capabilities?.input.map { $0.contains("image") },
                reasoning: written.capabilities.map { $0.reasoning?.supported == true })
        }
        return entries
    }

    /// `{file:…}` for the key file: under `~` when it is in the home directory, which OpenCode expands.
    static func keyReference(_ keyFile: URL, home: URL) -> String {
        "{file:\(ToolIntegration.displayPath(keyFile, home: home))}"
    }

    /// Where the provider's block in a config's `bytes` points: its `settings.baseURL`, and the file its `apiKey`
    /// reads (`keyReference`'s form); nil when the file has no such block or isn't JSONC.
    static func pointer(in bytes: Data, provider: IntegrationProvider, home: URL) -> ToolPointer? {
        guard let document = try? JSONCDocument([UInt8](bytes)), let root = document.root.object,
              let block = root.members(named: "providers").first?.value.object?.members(named: provider.id).first?
                .value.object else { return nil }
        let settings = block.members(named: "settings").first?.value.object
        func string(_ key: String) -> String? {
            guard let value = settings?.members(named: key).first?.value else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(document.bytes[value.start..<value.end]))
        }
        return ToolPointer(baseURL: string("baseURL"), keyFile: string("apiKey").flatMap { reference in
            guard reference.hasPrefix("{file:"), reference.hasSuffix("}") else { return nil }
            let path = String(reference.dropFirst("{file:".count).dropLast())
            if path == "~" || path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
        })
    }

    /// The global config files, in the order OpenCode loads them.
    static let globalFileNames = ["opencode.json", "opencode.jsonc"]

    /// Whether another global config file beside `file` sets a top-level `model`, or can't be read (so Darkbloom can't
    /// tell). OpenCode loads `opencode.json`, then `opencode.jsonc`, and Darkbloom edits the last that exists, so a
    /// `model` it added would override the owner's in the other file. Project, system and managed configs load after
    /// the global ones and win over them, so a global `model` never replaces theirs.
    static func otherGlobalConfigSetsModel(besides file: URL) -> Bool {
        let directory = file.deletingLastPathComponent()
        return globalFileNames.filter { $0 != file.lastPathComponent }.contains { name in
            let other = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: other.path) else { return false }
            guard let data = try? Data(contentsOf: other), let document = try? JSONCDocument([UInt8](data)),
                  let root = document.root.object else { return true }
            return !root.members(named: "model").isEmpty
        }
    }

    static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}

/// A model's value as Darkbloom writes it in the provider block.
private struct WrittenModel: Decodable {
    struct Limit: Decodable {
        let context: Int?
        let output: Int?
    }

    struct Capabilities: Decodable {
        struct Reasoning: Decodable {
            let supported: Bool?
        }

        let tools: Bool?
        let input: [String]?
        let reasoning: Reasoning?
    }

    let name: String?
    let limit: Limit?
    let capabilities: Capabilities?
}

/// The provider block as lines, indented by the file's own unit.
private struct Block {
    let provider: IntegrationProvider
    let endpoint: IntegrationEndpoint
    let models: [IntegrationModel]
    let home: URL
    let withComment: Bool
    let unit: String

    /// The value's lines, each with its nesting level; the first is the opening brace.
    private var valueLines: [(level: Int, text: String)] {
        let json = OpenCodeConfigPlan.jsonString
        var lines: [(level: Int, text: String)] = [
            (0, "{"),
            (1, "\"name\": \(json(provider.name)),"),
            (1, "\"package\": \(json(OpenCodeConfigPlan.package)),"),
            (1, "\"settings\": {"),
            (2, "\"baseURL\": \(json(endpoint.baseURL)),"),
            (2, "\"apiKey\": \(json(OpenCodeConfigPlan.keyReference(endpoint.keyFile, home: home)))"),
            (1, "},"),
            // OpenCode sends `max_completion_tokens` unless told otherwise; Darkbloom's engine reads `max_tokens`.
            (1, "\"compatibility\": { \"maxTokensField\": \"max_tokens\" },"),
            (1, "\"models\": {"),
        ]
        for (index, model) in models.enumerated() {
            var fields = ["\"name\": \(json(model.name))"]
            if let context = model.contextLength, let output = model.outputLimit {
                fields.append("\"limit\": { \"context\": \(context), \"output\": \(output) }")
            }
            fields.append("\"capabilities\": \(capabilities(model))")
            lines.append((level: 2, text: "\(json(model.id)): {"))
            for (position, field) in fields.enumerated() {
                lines.append((level: 3, text: field + (position < fields.count - 1 ? "," : "")))
            }
            lines.append((level: 2, text: "}" + (index < models.count - 1 ? "," : "")))
        }
        lines += [(level: 1, text: "}"), (level: 0, text: "}")]
        return lines
    }

    private func capabilities(_ model: IntegrationModel) -> String {
        var parts = [
            "\"tools\": \(model.tools)",
            "\"input\": \(model.imageInput ? "[\"text\", \"image\"]" : "[\"text\"]")",
            "\"output\": [\"text\"]",
        ]
        if model.reasoning { parts.append("\"reasoning\": { \"supported\": true }") }
        return "{ " + parts.joined(separator: ", ") + " }"
    }

    /// The value as it replaces an old one at `valueStart`: lines after the first are indented from `indent`.
    func value(indent: String) -> String {
        valueLines.enumerated().map { index, line in
            index == 0 ? line.text : indent + String(repeating: unit, count: line.level) + line.text
        }.joined(separator: "\n")
    }

    /// The whole member, the comment line first in a `.jsonc` file, as lines relative to the member's indent.
    var member: [String] {
        let comment = "// Added by `\(provider.id) start --opencode`. Run it again to refresh \(provider.name)'s models."
        let lines = valueLines.enumerated().map { index, line in
            index == 0 ? "\(OpenCodeConfigPlan.jsonString(provider.id)): {"
                : String(repeating: unit, count: line.level) + line.text
        }
        return (withComment ? [comment] : []) + lines
    }
}

/// Byte edits of one JSONC document, applied at once.
private struct Splice {
    let document: JSONCDocument
    /// The file's line break (`\r\n` when it uses them) and indent unit (two spaces when it shows none).
    let newline: String
    let unit: String
    private var edits: [(range: Range<Int>, bytes: [UInt8])] = []

    init(document: JSONCDocument) {
        self.document = document
        let bytes = document.bytes
        newline = bytes.indices.dropLast().contains { bytes[$0] == 0x0D && bytes[$0 + 1] == 0x0A } ? "\r\n" : "\n"
        var unit = "  "
        if let root = document.root.object,
           let first = root.members.first(where: { Self.startsLine(bytes, at: $0.keyStart) }) {
            let indent = Self.lineIndent(bytes, at: first.keyStart)
            if !indent.isEmpty { unit = indent }
        }
        self.unit = unit
    }

    var changesBytes: Bool { !edits.isEmpty }

    /// Records the replacement when it differs from the bytes there; true when it does.
    mutating func replace(_ range: Range<Int>, with text: String) -> Bool {
        let replacement = Array(text.replacingOccurrences(of: "\n", with: newline).utf8)
        guard Array(document.bytes[range]) != replacement else { return false }
        edits.append((range, replacement))
        return true
    }

    /// Appends members (each a group of lines relative to the member indent) after `object`'s last member, in the
    /// object's trailing-comma style; the closing brace keeps its own line when it has one.
    mutating func append(_ groups: [[String]], to object: JSONCDocument.Object) {
        let bytes = document.bytes
        let trailing = object.members.last?.comma != nil
        if let last = object.members.last, last.comma == nil { edits.append((last.value.end..<last.value.end, [0x2C])) }
        let indent = object.members.first(where: { Self.startsLine(bytes, at: $0.keyStart) })
            .map { Self.lineIndent(bytes, at: $0.keyStart) } ?? Self.lineIndent(bytes, at: object.open) + unit
        var lines: [String] = []
        for (index, group) in groups.enumerated() {
            var group = group
            if index < groups.count - 1 || trailing { group[group.count - 1] += "," }
            lines += group.map { indent + $0 }
        }
        let body = lines.joined(separator: newline)
        if Self.startsLine(bytes, at: object.close) {
            let lineStart = Self.lineStart(bytes, at: object.close)
            edits.append((lineStart..<lineStart, Array((body + newline).utf8)))
        } else {
            let text = newline + body + newline + Self.lineIndent(bytes, at: object.open)
            edits.append((object.close..<object.close, Array(text.utf8)))
        }
    }

    func memberIndent(of member: JSONCDocument.Member, in object: JSONCDocument.Object) -> String {
        Self.startsLine(document.bytes, at: member.keyStart)
            ? Self.lineIndent(document.bytes, at: member.keyStart)
            : Self.lineIndent(document.bytes, at: object.open) + unit
    }

    /// The edited bytes. Edits apply from the end; of two at one offset (a comma and the member after it), the one
    /// recorded first ends up first.
    func result() -> [UInt8] {
        var bytes = document.bytes
        let ordered = edits.enumerated().sorted {
            ($0.element.range.lowerBound, $0.offset) > ($1.element.range.lowerBound, $1.offset)
        }
        for (_, edit) in ordered {
            bytes.replaceSubrange(edit.range, with: edit.bytes)
        }
        return bytes
    }

    private static func lineStart(_ bytes: [UInt8], at offset: Int) -> Int {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        return start
    }

    /// True when only spaces and tabs come before `offset` on its line.
    private static func startsLine(_ bytes: [UInt8], at offset: Int) -> Bool {
        bytes[lineStart(bytes, at: offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String {
        let start = lineStart(bytes, at: offset)
        let indent = bytes[start..<offset].prefix { $0 == 0x20 || $0 == 0x09 }
        return String(decoding: indent, as: UTF8.self)
    }
}
