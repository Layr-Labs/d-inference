import Foundation

/// The `providers.<id>` block and the main model in Hermes Agent's `config.yaml`.
///
/// The package has no YAML library, and a YAML round trip drops the owner's comments (Ollama's and oMLX's edits do),
/// so this is a line splice of two top-level keys, `providers` and `model`; every other line stays byte for byte.
/// What a line splice can't edit safely is refused before anything is written: several documents, tab indentation,
/// anchors or aliases, and inline or multi-line values in those two sections.
enum HermesConfigPlan {
    /// Hermes' own floor: it refuses a smaller context window for agent use with tools.
    static let minimumContext = 64_000

    /// Keys of the `model` section that pin the previous endpoint or its credential; Hermes would otherwise mix
    /// them into Darkbloom's provider. The backup keeps them.
    static let previousEndpointKeys: Set<String> = [
        "base_url", "api_key", "key_env", "key_cmd", "api", "api_mode", "transport", "context_length", "max_tokens",
        "supports_vision", "ollama_num_ctx",
    ]

    /// `$HERMES_HOME/config.yaml`, else `~/.hermes/config.yaml`.
    static func configFile(home: URL, variables: [String: String]) -> URL {
        let hermesHome = variables["HERMES_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".hermes", isDirectory: true)
        return hermesHome.appendingPathComponent("config.yaml")
    }

    /// The file's new bytes: Darkbloom's provider with the models Hermes can use (at least 64K context) and their
    /// context and vision, and Darkbloom as the main model, as `ollama launch` and `omlx launch` make theirs.
    static func plan(
        existing: Data?, endpoint: IntegrationEndpoint, models listed: [IntegrationModel], provider: IntegrationProvider
    ) -> ToolConfigPlan {
        guard !listed.isEmpty else {
            return .refused(.models("Darkbloom's endpoint lists no chat models yet, so Hermes has none to use."))
        }
        let original = String(decoding: existing ?? Data(), as: UTF8.self)
        // The provider's own model entries stand in for what the catalog didn't say (offline, or a model it doesn't
        // list), so such a run never drops a model's vision or context.
        let entries = (try? HermesEdit(text: original, provider: provider))?.modelEntries() ?? [:]
        let models = IntegrationModels.keeping(listed, entries: entries)
        let usable = models.filter { ($0.contextLength ?? 0) >= minimumContext }
        guard !usable.isEmpty else { return .refused(.models(floorReason(models))) }
        do {
            var edit = try HermesEdit(text: original, provider: provider)
            guard let main = edit.mainModel(among: usable) else {
                return .refused(.models("""
                    Hermes needs a main model with at least 64K context on this Mac or your other Macs; Darkbloom \
                    lists such models only on the network here.
                    """))
            }
            let change = try edit.setProvider(endpoint: endpoint, models: usable, main: main)
            try edit.setMainModel(main)
            let text = edit.result()
            let summary = ToolConfigSummary(
                provider: change, models: usable.map(\.id), defaultModel: main,
                leftOut: models.filter { ($0.contextLength ?? 0) < minimumContext }.map(\.id),
                droppedComments: text.map { edit.droppedComments(in: $0) } ?? 0,
                undescribed: usable.filter { $0.fallback != nil && entries[$0.id] == nil }.map(\.id))
            guard let text else { return .unchanged(summary) }
            return .change(Data(text.utf8), summary)
        } catch {
            return .refused(.file(error.reason))
        }
    }

    /// Where the provider's block in a config's `bytes` points: its `api`, and the file its `key_cmd` reads
    /// (`/bin/cat <file>`, as `plan` writes it); nil when the file has no such block or can't be read.
    static func pointer(in bytes: Data, provider: IntegrationProvider) -> ToolPointer? {
        (try? HermesEdit(text: String(decoding: bytes, as: UTF8.self), provider: provider))?.pointer()
    }

    private static func floorReason(_ models: [IntegrationModel]) -> String {
        guard let largest = models.compactMap(\.contextLength).max() else {
            return """
                Hermes needs a model with at least 64K context, and Darkbloom's models here don't say how much they \
                offer; OpenCode can use them.
                """
        }
        return """
            Hermes needs a model with at least 64K context. Darkbloom's models here offer at most \(largest / 1024)K \
            now; OpenCode can use them.
            """
    }
}

/// Why a file is refused, as the clause after "Didn't change <file>: ".
private struct HermesRefusal: Error {
    let reason: String
}

/// One line and its own line break, kept so untouched lines stay byte for byte.
private struct YAMLLine {
    var content: String
    var ending: String

    var indent: Int { content.prefix { $0 == " " }.count }
    var isBlank: Bool { content.allSatisfy { $0 == " " || $0 == "\t" } }
    var isComment: Bool { content.drop { $0 == " " || $0 == "\t" }.first == "#" }
    var isContent: Bool { !isBlank && !isComment }
}

/// A key's line in block style: `key: value  # comment`.
private struct YAMLEntry {
    let key: String
    let line: Int
    /// The value as written, comment removed; empty for a block (children follow) or a null.
    let value: String
    /// Where the key's region ends (exclusive): its next sibling's line, or the parent's end.
    var end: Int
}

private struct HermesEdit {
    private let lines: [YAMLLine]
    private let provider: IntegrationProvider
    private let newline: String
    /// The file's indent step (two spaces when it shows none).
    private let unit: String
    private var providers: YAMLEntry?
    private var model: YAMLEntry?
    private var edits: [(range: Range<Int>, lines: [String])] = []
    private var appended: [String] = []

    init(text: String, provider: IntegrationProvider) throws(HermesRefusal) {
        self.provider = provider
        lines = Self.split(text)
        newline = lines.contains { $0.ending == "\r\n" } ? "\r\n" : "\n"
        let stepped = lines.first { $0.isContent && $0.indent > 0 }?.indent ?? 2
        unit = String(repeating: " ", count: stepped)
        let topLevel = try Self.topLevelEntries(lines)
        for name in ["providers", "model"] where topLevel.filter({ $0.key == name }).count > 1 {
            throw HermesRefusal(reason: "it has two \"\(name)\" sections")
        }
        providers = topLevel.first { $0.key == "providers" }
        model = topLevel.first { $0.key == "model" }
        for section in [providers, model].compactMap({ $0 }) { try checkSection(section) }
    }

    // MARK: - The two sections

    /// The model `model.default` names when the main provider is already Darkbloom's and Hermes can still use it;
    /// else this Mac's first usable model, else the first on the owner's other Macs. Never a network model by choice.
    func mainModel(among usable: [IntegrationModel]) -> String? {
        if let model, let children = try? children(of: model),
           let selected = children.first(where: { $0.key == "provider" }).flatMap({ Self.scalar($0.value) }),
           ["custom:\(provider.id)", provider.id].contains(selected),
           let current = children.first(where: { $0.key == "default" || $0.key == "model" })
               .flatMap({ Self.scalar($0.value) }),
           usable.contains(where: { $0.id == current }) {
            return current
        }
        return (usable.first { $0.location == .thisMac } ?? usable.first { $0.location == .yourMacs })?.id
    }

    mutating func setProvider(
        endpoint: IntegrationEndpoint, models: [IntegrationModel], main: String
    ) throws(HermesRefusal) -> ToolConfigSummary.ProviderChange {
        func block(_ indent: String) -> [String] {
            providerBlock(indent: indent, endpoint: endpoint, models: models, main: main)
        }
        // A new block comes with a line saying where it came from. A replaced block keeps the lines above it, that one
        // included, so a re-run never adds a second.
        func newBlock(_ indent: String) -> [String] {
            [indent + "# Added by `\(provider.id) --hermes`. Run it again to refresh \(provider.name)'s models."]
                + block(indent)
        }
        guard let section = providers else {
            appended += ["providers:"] + newBlock(unit)
            return .added
        }
        switch section.value {
        case "":
            let children = try children(of: section)
            guard let first = children.first else {
                edits.append((section.line + 1..<section.line + 1, newBlock(unit)))
                return .added
            }
            let indent = String(repeating: " ", count: lines[first.line].indent)
            let mine = children.filter { $0.key == provider.id }
            guard mine.count < 2 else { throw HermesRefusal(reason: "it has two \"\(provider.id)\" providers") }
            guard let current = mine.first else {
                let end = bodyEnd(of: section)
                edits.append((end..<end, newBlock(indent)))
                return .added
            }
            return replace(current.line..<current.end, with: block(indent)) ? .updated : .unchanged
        case "{}", "~", "null", "Null", "NULL":
            try requireOneLine(section)
            edits.append((section.line..<section.line + 1, ["providers:"] + newBlock(unit)))
            return .added
        default:
            throw HermesRefusal(reason: "its \"providers\" section isn't a list of providers Darkbloom can edit")
        }
    }

    mutating func setMainModel(_ main: String) throws(HermesRefusal) {
        let providerLine = "provider: " + Self.quoted("custom:\(provider.id)")
        let defaultLine = "default: " + Self.quoted(main)
        let mapping = [unit + providerLine, unit + defaultLine]
        guard let section = model else {
            appended += ["model:"] + mapping
            return
        }
        let children = section.value.isEmpty ? try children(of: section) : []
        if let first = children.first {
            let indent = String(repeating: " ", count: lines[first.line].indent)
            var top: [String] = []
            if !children.contains(where: { $0.key == "provider" }) { top.append(indent + providerLine) }
            if !children.contains(where: { $0.key == "default" || $0.key == "model" }) { top.append(indent + defaultLine) }
            if !top.isEmpty { edits.append((section.line + 1..<section.line + 1, top)) }
            for child in children {
                switch child.key {
                case "provider": _ = replace(child.line..<child.end, with: [indent + providerLine])
                case "default": _ = replace(child.line..<child.end, with: [indent + defaultLine])
                case "model": _ = replace(child.line..<child.end, with: [indent + "model: " + Self.quoted(main)])
                case _ where HermesConfigPlan.previousEndpointKeys.contains(child.key):
                    edits.append((child.line..<child.end, []))
                default: break
                }
            }
            return
        }
        if section.value.isEmpty {
            // `model:` with nothing under it: the children go below, and the line keeps its comment.
            edits.append((section.line + 1..<section.line + 1, mapping))
            return
        }
        // A model ID or Hermes' fresh-install `model: ""`: the line becomes the mapping.
        guard section.value == "{}" || Self.scalar(section.value) != nil else {
            throw HermesRefusal(reason: "its \"model\" section isn't one Darkbloom can edit")
        }
        try requireOneLine(section)
        edits.append((section.line..<section.line + 1, ["model:"] + mapping))
    }

    private func providerBlock(
        indent: String, endpoint: IntegrationEndpoint, models: [IntegrationModel], main: String
    ) -> [String] {
        let (one, two, three) = (indent + unit, indent + unit + unit, indent + unit + unit + unit)
        // Hermes sends no output cap to a custom endpoint, and Darkbloom's default is 4096 tokens; the cap must suit
        // every model Hermes can switch to on this provider.
        let maxTokens = models.map { $0.outputLimit ?? min(IntegrationModels.defaultOutputCap, ($0.contextLength ?? 0) / 4) }
            .min() ?? IntegrationModels.defaultOutputCap
        var block = [
            indent + Self.key(provider.id) + ":",
            one + "name: " + Self.quoted(provider.name),
            one + "api: " + Self.quoted(endpoint.baseURL),
            one + "transport: " + Self.quoted("chat_completions"),
            one + "key_cmd: " + Self.quoted(Self.keyCommand(reading: endpoint.keyFile)),
            one + "default_model: " + Self.quoted(main),
            one + "extra_body:",
            two + "max_tokens: \(maxTokens)",
            one + "models:",
        ]
        for model in models {
            block.append(two + Self.quoted(model.id) + ":")
            if let context = model.contextLength { block.append(three + "context_length: \(context)") }
            if model.imageInput { block.append(three + "supports_vision: true") }
        }
        return block
    }

    /// What Darkbloom's provider block says of each model now, by model ID: its context and vision, with the block's
    /// output cap. A block it can't read holds nothing.
    func modelEntries() -> [String: IntegrationModel.Entry] {
        guard let fields = providerFields() else { return [:] }
        let cap = fields.first { $0.key == "extra_body" }.flatMap { try? children(of: $0) }
            .flatMap { Self.value("max_tokens", in: $0) }.flatMap { Int($0) }
        guard let models = fields.first(where: { $0.key == "models" }), let listed = try? children(of: models) else {
            return [:]
        }
        var entries: [String: IntegrationModel.Entry] = [:]
        for model in listed {
            let values = (try? children(of: model)) ?? []
            entries[model.key] = IntegrationModel.Entry(
                contextLength: Self.value("context_length", in: values).flatMap { Int($0) }, outputLimit: cap,
                imageInput: Self.value("supports_vision", in: values)?.lowercased() == "true")
        }
        return entries
    }

    /// Where Darkbloom's provider block points (`HermesConfigPlan.pointer`); nil without one it can read.
    func pointer() -> ToolPointer? {
        guard let fields = providerFields() else { return nil }
        return ToolPointer(baseURL: Self.value("api", in: fields),
                           keyFile: Self.value("key_cmd", in: fields).flatMap(Self.keyFile(readBy:)))
    }

    /// The fields of Darkbloom's provider block; nil without one it can read.
    private func providerFields() -> [YAMLEntry]? {
        guard let providers, providers.value.isEmpty,
              let mine = (try? children(of: providers))?.first(where: { $0.key == provider.id }) else { return nil }
        return try? children(of: mine)
    }

    /// `key`'s scalar value among `entries`.
    private static func value(_ key: String, in entries: [YAMLEntry]) -> String? {
        entries.first { $0.key == key }.flatMap { scalar($0.value) }
    }

    // MARK: - The key command

    /// The `key_cmd` Hermes runs for Darkbloom's key: `/bin/cat` and the key file's path as one shell word.
    static func keyCommand(reading keyFile: URL) -> String {
        keyReader + ToolIntegration.shellQuoted(keyFile.path, onlyIfNeeded: true)
    }

    /// The key file a `keyCommand` reads; nil for any other command, or a path that isn't absolute.
    static func keyFile(readBy command: String) -> URL? {
        guard command.hasPrefix(keyReader) else { return nil }
        var path = String(command.dropFirst(keyReader.count))
        // `ToolIntegration.shellQuoted`'s single quotes, each quote inside as '\''.
        if path.hasPrefix("'") {
            guard path.count >= 2, path.hasSuffix("'") else { return nil }
            path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    private static let keyReader = "/bin/cat "

    // MARK: - Result

    /// Comments of the original that `text` no longer holds: those on the lines the edit replaced or removed.
    func droppedComments(in text: String) -> Int {
        lines.compactMap(Self.comment).filter { !text.contains($0) }.count
    }

    /// The new text, or nil when it is the same as the file's. Edits apply from the end; an insertion and a
    /// replacement at one line put the inserted lines first.
    func result() -> String? {
        var result = lines
        for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound) }) {
            result.replaceSubrange(edit.range, with: edit.lines.map { YAMLLine(content: $0, ending: newline) })
        }
        result += appended.map { YAMLLine(content: $0, ending: newline) }
        // A file without a final line break: its last line gets one when lines now follow it.
        for index in result.indices.dropLast() where result[index].ending.isEmpty { result[index].ending = newline }
        let text = result.map { $0.content + $0.ending }.joined()
        return text == lines.map({ $0.content + $0.ending }).joined() ? nil : text
    }

    /// Records the replacement when it differs from the lines there; true when it does.
    private mutating func replace(_ range: Range<Int>, with replacement: [String]) -> Bool {
        guard lines[range].map(\.content) != replacement else { return false }
        edits.append((range, replacement))
        return true
    }

    // MARK: - Structure

    private static func split(_ text: String) -> [YAMLLine] {
        var lines: [YAMLLine] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            guard byte == 0x0A else {
                current.append(byte)
                continue
            }
            let crlf = current.last == 0x0D
            if crlf { current.removeLast() }
            lines.append(YAMLLine(content: String(decoding: current, as: UTF8.self), ending: crlf ? "\r\n" : "\n"))
            current.removeAll(keepingCapacity: true)
        }
        if !current.isEmpty { lines.append(YAMLLine(content: String(decoding: current, as: UTF8.self), ending: "")) }
        return lines
    }

    private static func topLevelEntries(_ lines: [YAMLLine]) throws(HermesRefusal) -> [YAMLEntry] {
        var entries: [YAMLEntry] = []
        for (index, line) in lines.enumerated() where line.isContent {
            if line.content.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw HermesRefusal(reason: "it indents with tabs, which YAML doesn't allow")
            }
            guard line.indent == 0 else {
                if entries.isEmpty { throw HermesRefusal(reason: "it isn't a YAML mapping of settings") }
                continue
            }
            if line.content.hasPrefix("---") {
                guard entries.isEmpty, splitComment(line.content.dropFirst(3)).value.isEmpty else {
                    throw HermesRefusal(reason: "it holds more than one YAML document, which Darkbloom doesn't edit")
                }
                continue
            }
            if line.content.hasPrefix("...") || line.content.hasPrefix("%") {
                throw HermesRefusal(reason: "it holds more than one YAML document, which Darkbloom doesn't edit")
            }
            if isListItem(Substring(line.content)) {
                // A list at its key's own indent (PyYAML's style, so oMLX's and older Hermes') belongs to that key.
                guard entries.last?.value.isEmpty == true else {
                    throw HermesRefusal(reason: "it isn't a YAML mapping of settings")
                }
                continue
            }
            guard let entry = splitKey(Substring(line.content)) else {
                throw HermesRefusal(reason: "it isn't a YAML mapping of settings")
            }
            if !entries.isEmpty { entries[entries.count - 1].end = index }
            entries.append(YAMLEntry(key: entry.key, line: index, value: splitComment(entry.rest).value, end: lines.count))
        }
        return entries
    }

    /// A block mapping's children, each with its region (its deeper lines; trailing blank lines and comments that
    /// aren't indented under it belong to what follows).
    private func children(of entry: YAMLEntry) throws(HermesRefusal) -> [YAMLEntry] {
        let body = (entry.line + 1)..<entry.end
        guard let first = body.first(where: { lines[$0].isContent }) else { return [] }
        let indent = lines[first].indent
        var children: [YAMLEntry] = []
        for index in body where lines[index].isContent {
            if lines[index].indent < indent {
                throw HermesRefusal(reason: "its \"\(entry.key)\" section is indented unevenly")
            }
            let isListItem = Self.isListItem(Substring(lines[index].content).dropFirst(indent))
            guard lines[index].indent == indent, !isListItem else {
                // Deeper lines, and a list at its key's own indent, belong to the child above.
                guard let last = children.indices.last, lines[index].indent > indent || children[last].value.isEmpty else {
                    throw HermesRefusal(reason: "its \"\(entry.key)\" section isn't a mapping Darkbloom can edit")
                }
                children[last].end = index + 1
                continue
            }
            guard let child = Self.splitKey(Substring(lines[index].content)) else {
                throw HermesRefusal(reason: "its \"\(entry.key)\" section isn't a mapping Darkbloom can edit")
            }
            children.append(YAMLEntry(key: child.key, line: index, value: Self.splitComment(child.rest).value,
                                      end: index + 1))
        }
        // An indented comment right after a child's last line is part of it.
        for position in children.indices {
            let limit = position + 1 < children.count ? children[position + 1].line : entry.end
            var end = children[position].end
            while end < limit, lines[end].isComment, lines[end].indent > indent {
                end += 1
            }
            children[position].end = end
        }
        return children
    }

    /// After the section's last line that is content or an indented comment: where a new child goes.
    private func bodyEnd(of entry: YAMLEntry) -> Int {
        let last = ((entry.line + 1)..<entry.end).last { lines[$0].isContent || (lines[$0].isComment && lines[$0].indent > 0) }
        return (last ?? entry.line) + 1
    }

    private func requireOneLine(_ entry: YAMLEntry) throws(HermesRefusal) {
        if ((entry.line + 1)..<entry.end).contains(where: { lines[$0].isContent }) {
            throw HermesRefusal(reason: "its \"\(entry.key)\" value spans lines, which Darkbloom doesn't edit")
        }
    }

    /// Refuses what a line splice can't edit safely in `entry`'s section: anchors, aliases and merge keys, block
    /// text, and inline collections (only an empty `{}` is fine).
    private func checkSection(_ entry: YAMLEntry) throws(HermesRefusal) {
        let name = entry.key
        if entry.value.first == "&" || entry.value.first == "*" || entry.value.first == "!" {
            throw HermesRefusal(reason: "its \"\(name)\" section uses YAML anchors, aliases or tags, which Darkbloom doesn't edit")
        }
        if entry.value.first == "|" || entry.value.first == ">" {
            throw HermesRefusal(reason: "its \"\(name)\" section is a block of text, which Darkbloom doesn't edit")
        }
        if (entry.value.first == "{" || entry.value.first == "[") && entry.value != "{}" {
            throw HermesRefusal(reason: "its \"\(name)\" section is written inline, which Darkbloom doesn't edit")
        }
        var textIndent: Int?
        for index in (entry.line + 1)..<entry.end where lines[index].isContent {
            let line = lines[index]
            if let indent = textIndent, line.indent > indent { continue }
            textIndent = nil
            var body = Substring(line.content).drop { $0 == " " }
            while body.hasPrefix("- ") { body = body.dropFirst(2).drop { $0 == " " } }
            let value: String
            if let entry = Self.splitKey(body) {
                if entry.key == "<<" {
                    throw HermesRefusal(reason: "its \"\(name)\" section uses YAML merge keys, which Darkbloom doesn't edit")
                }
                value = Self.splitComment(entry.rest).value
            } else {
                value = Self.splitComment(body).value
            }
            if value.first == "&" || value.first == "*" || Self.flowUsesAnchors(value) {
                throw HermesRefusal(reason: "its \"\(name)\" section uses YAML anchors or aliases, which Darkbloom doesn't edit")
            }
            if !Self.flowIsClosed(value) {
                throw HermesRefusal(reason: "its \"\(name)\" section has an inline list or map over several lines, which Darkbloom doesn't edit")
            }
            if value.first == "|" || value.first == ">" { textIndent = line.indent }
        }
    }

    /// A block list item, `- …` or a bare `-`, with the line's indent already removed.
    static func isListItem(_ content: Substring) -> Bool {
        content.first == "-" && (content.count == 1 || content.dropFirst().first == " " || content.dropFirst().first == "\t")
    }

    // MARK: - Scalars

    /// `key:` and the rest of the line, for a plain or quoted key; nil when the line isn't a mapping entry.
    static func splitKey(_ content: Substring) -> (key: String, rest: Substring)? {
        let text = content.drop { $0 == " " }
        guard let first = text.first else { return nil }
        if first == "\"" || first == "'" {
            guard let closing = closingQuote(in: text) else { return nil }
            var after = text[text.index(after: closing)...].drop { $0 == " " }
            guard after.first == ":" else { return nil }
            after = after.dropFirst()
            guard after.isEmpty || after.first == " " || after.first == "\t",
                  let key = scalar(String(text[...closing])) else { return nil }
            return (key, after)
        }
        if "[]{}#&*!|>%@`,".contains(first) { return nil }
        if "-?:".contains(first), text.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true { return nil }
        var index = text.startIndex
        var previous: Character = " "
        while index < text.endIndex {
            let character = text[index]
            if character == "#", previous == " " || previous == "\t" { return nil }
            let next = text.index(after: index)
            if character == ":", next == text.endIndex || text[next] == " " || text[next] == "\t" {
                let key = text[..<index].reversed().drop { $0 == " " }.reversed()
                return key.isEmpty ? nil : (String(key), text[next...])
            }
            previous = character
            index = next
        }
        return nil
    }

    /// The value after a key, and the comment after it; a `#` inside a quoted value isn't a comment.
    static func splitComment(_ rest: Substring) -> (value: String, comment: String?) {
        let text = rest.drop { $0 == " " || $0 == "\t" }
        var scanFrom = text.startIndex
        if text.first == "\"" || text.first == "'" {
            scanFrom = closingQuote(in: text).map { text.index(after: $0) } ?? text.endIndex
        }
        var index = scanFrom
        while index < text.endIndex {
            if text[index] == "#", index == text.startIndex || [" ", "\t"].contains(text[text.index(before: index)]) {
                return (trimmedTrailing(text[..<index]), String(text[index...]))
            }
            index = text.index(after: index)
        }
        return (trimmedTrailing(text), nil)
    }

    /// A plain or quoted scalar's value; nil for anything else (a collection, an anchor, block text, a broken quote).
    static func scalar(_ value: String) -> String? {
        guard let first = value.first else { return "" }
        if first == "'" {
            guard value.count >= 2, value.last == "'", closingQuote(in: Substring(value)) == value.index(before: value.endIndex) else { return nil }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if first == "\"" {
            guard value.count >= 2, closingQuote(in: Substring(value)) == value.index(before: value.endIndex) else { return nil }
            return unescape(value.dropFirst().dropLast())
        }
        return "[]{}&*!|>%@`".contains(first) ? nil : value
    }

    /// A double-quoted YAML string: `\` and `"` escaped, control characters as `\x`, so IDs with `/`, `:` or quotes
    /// never need YAML judgement.
    static func quoted(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case "\r": quoted += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: quoted += String(format: "\\x%02X", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    private static func key(_ name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
        return plain ? name : quoted(name)
    }

    /// The index of the quote that closes the one `text` starts with.
    private static func closingQuote(in text: Substring) -> Substring.Index? {
        guard let quote = text.first else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"", character == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if character == quote {
                let next = text.index(after: index)
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func unescape(_ body: Substring) -> String? {
        var result = ""
        var scalars = body.unicodeScalars.makeIterator()
        func hex(_ count: Int) -> Unicode.Scalar? {
            var digits = ""
            for _ in 0..<count {
                guard let next = scalars.next() else { return nil }
                digits.unicodeScalars.append(next)
            }
            return UInt32(digits, radix: 16).flatMap(Unicode.Scalar.init)
        }
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let escaped = scalars.next() else { return nil }
            let decoded: Unicode.Scalar?
            switch escaped {
            case "\"", "\\", "/", " ": decoded = escaped
            case "n": decoded = "\n"
            case "t": decoded = "\t"
            case "r": decoded = "\r"
            case "0": decoded = "\0"
            case "x": decoded = hex(2)
            case "u": decoded = hex(4)
            case "U": decoded = hex(8)
            default: decoded = nil
            }
            guard let decoded else { return nil }
            result.unicodeScalars.append(decoded)
        }
        return result
    }

    /// Whether an inline `{…}` / `[…]` value closes on its own line.
    private static func flowIsClosed(_ value: String) -> Bool {
        guard value.first == "{" || value.first == "[" else { return true }
        var depth = 0
        var quote: Character?
        var previous: Character = " "
        for character in value {
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
            }
            previous = character
        }
        return depth == 0 && quote == nil
    }

    /// An anchor or alias inside an inline collection: `&name` or `*name` after an opener, a comma or a space.
    private static func flowUsesAnchors(_ value: String) -> Bool {
        guard value.first == "{" || value.first == "[" else { return false }
        let characters = Array(value)
        return characters.indices.dropFirst().dropLast().contains { index in
            ["&", "*"].contains(characters[index]) && ["[", "{", ",", " "].contains(characters[index - 1])
                && (characters[index + 1].isLetter || characters[index + 1].isNumber || characters[index + 1] == "_")
        }
    }

    /// A line's comment: the whole line for a comment line, else the text from an unquoted ` #`.
    private static func comment(_ line: YAMLLine) -> String? {
        if line.isComment { return line.content.trimmingCharacters(in: .whitespaces) }
        guard line.isContent else { return nil }
        var body = Substring(line.content).drop { $0 == " " }
        while body.hasPrefix("- ") { body = body.dropFirst(2) }
        let rest = splitKey(body)?.rest ?? body
        return splitComment(rest).comment
    }

    private static func trimmedTrailing(_ text: Substring) -> String {
        String(text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
