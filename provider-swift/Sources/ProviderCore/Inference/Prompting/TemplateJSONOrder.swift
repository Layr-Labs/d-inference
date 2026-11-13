// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMServer
import ProviderCoreFoundation

/// Tool declarations and earlier tool calls as the request wrote them, for a
/// request that asks for Transformers' rendering (`HFTemplateFilters`).
///
/// Transformers renders the client's own JSON: object members in the order
/// they were sent, `null` members and array items kept, and a number written
/// `1.0` printed as `1.0`. The prompt path decodes tools and arguments into
/// Swift dictionaries, which have no order, and `Jinja.Value(any:)` sorts
/// every object it bridges. Here the normalized values, which stay the
/// authority on content (schema repairs, family normalization), are rebuilt
/// as ordered `Jinja.Value`s against the request's own JSON:
/// - an object's members follow the request's order, then members the
///   provider added, sorted;
/// - a member or array item the request sent as `null`, which the generic
///   sanitizer drops, is restored;
/// - a number or Boolean equal to the request's keeps the request's type.
/// Tools come from the body's `tools` member (`Evidence`); arguments from
/// each call's own `function.arguments` string.
///
/// A request asks with `"_darkbloom_template_json": "transformers"` (the
/// coordinator sets it per build, together with its prompt sidecar's
/// matching render); `DARKBLOOM_TEMPLATE_JSON=transformers` asks for every
/// request of the process. Any other request renders as before.
enum TemplateJSONOrder {
    static let environmentKey = "DARKBLOOM_TEMPLATE_JSON"
    static let transformers = "transformers"

    /// Whether the request asked, and its `tools` member in its own order.
    /// `tools` is nil when the request did not ask, has none, or they do not
    /// parse within `NemotronSuperOrderedJSON`'s bounds (tools then keep the
    /// sorted order).
    struct Evidence: Sendable, Equatable {
        var requested = false
        var tools: [Value]?

        func capturing(
            body: Data, environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Evidence {
            guard TemplateJSONOrder.asks(self, environment: environment),
                case .array(let tools)? = try? NemotronSuperOrderedJSON.member("tools", of: body)
            else { return self }
            return Evidence(requested: requested, tools: tools)
        }
    }

    static func asks(
        _ evidence: Evidence, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !HFTemplateFilters.legacyRequested(environment: environment) else { return false }
        return evidence.requested
            || environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() == transformers
    }

    /// The template input with Transformers' filters, ordered tools (passed
    /// as the `tools` context variable, since the tokenizer's `tools`
    /// parameter takes dictionaries it would sort) and ordered tool-call
    /// arguments. Unchanged unless the request asks and its family is listed
    /// in `HFTemplateFilters`, or is Nemotron-H, whose own filters already
    /// match Transformers' and which takes only the order.
    static func apply(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?, request: OpenAIChatCompletionRequest,
        evidence: Evidence, modelType: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
          additionalContext: [String: any Sendable]?) {
        let transformersFilters = HFTemplateFilters.applies(modelType: modelType, environment: environment)
        guard asks(evidence, environment: environment),
            transformersFilters || NemotronTemplateFilters.applies(modelType: modelType)
        else { return (messages, tools, additionalContext) }
        var context = additionalContext ?? [:]
        if transformersFilters {
            context.merge(HFTemplateFilters.requestContext()) { _, filter in filter }
        }
        if let tools { context["tools"] = Value.array(orderedTools(tools, evidence: evidence)) }
        return (orderingToolCalls(in: messages, request: request), nil, context)
    }

    // MARK: - Tools

    static func orderedTools(_ tools: [[String: any Sendable]], evidence: Evidence) -> [Value] {
        var byName: [String: Value] = [:]
        var repeated: Set<String> = []
        for tool in evidence.tools ?? [] {
            guard let name = declaredName(tool) else { continue }
            if byName.updateValue(tool, forKey: name) != nil { repeated.insert(name) }
        }
        return tools.map { tool in
            let name = stringValue(tool["function"].flatMap(objectMembers)?["name"]) ?? stringValue(tool["name"])
            let order = name.flatMap { repeated.contains($0) ? nil : byName[$0] }
            // The declaration's and its function's own members as sent: the
            // typed decode keeps only OpenAI's fields and the generic path
            // drops `strict`, which Transformers renders.
            return overlay(tool, order: order.map(wrappedDeclaration), restoringLevels: 2)
        }
    }

    private static func declaredName(_ tool: Value) -> String? {
        guard case .object(let members) = tool else { return nil }
        if case .object(let function)? = members["function"], case .string(let name)? = function["name"] {
            return name
        }
        if case .string(let name)? = members["name"] { return name }
        return nil
    }

    /// The provider renders a flat declaration (`{name, parameters}`) in the
    /// OpenAI wrapper; its members then order the wrapper's `function`.
    private static func wrappedDeclaration(_ tool: Value) -> Value {
        guard case .object(let members) = tool, members["function"] == nil else { return tool }
        return .object(["type": .string("function"), "function": tool])
    }

    // MARK: - Tool calls

    /// Each call's arguments ordered by its own `function.arguments` string,
    /// found by call ID, or by position among calls of the same name when IDs
    /// repeat or are missing.
    static func orderingToolCalls(
        in messages: [[String: any Sendable]], request: OpenAIChatCompletionRequest
    ) -> [[String: any Sendable]] {
        let sent = request.messages.flatMap { $0.toolCalls ?? [] }
        guard !sent.isEmpty else { return messages }
        var byID: [String: String] = [:]
        var repeatedIDs: Set<String> = []
        var byName: [String: [String]] = [:]
        for call in sent {
            if !call.id.isEmpty, byID.updateValue(call.function.arguments, forKey: call.id) != nil {
                repeatedIDs.insert(call.id)
            }
            byName[call.function.name, default: []].append(call.function.arguments)
        }
        var seenByName: [String: Int] = [:]
        return messages.map { message in
            guard let calls = message["tool_calls"].flatMap(arrayItems), !calls.isEmpty else { return message }
            var ordered = message
            ordered["tool_calls"] = Value.array(calls.map { call -> Value in
                guard let members = objectMembers(call),
                    let function = members["function"].flatMap(objectMembers)
                else { return overlay(call, order: nil) }
                let id = stringValue(members["id"]) ?? ""
                let name = stringValue(function["name"]) ?? ""
                let index = seenByName[name, default: 0]
                seenByName[name] = index + 1
                let raw = (!id.isEmpty && !repeatedIDs.contains(id) ? byID[id] : nil)
                    ?? byName[name].flatMap { index < $0.count ? $0[index] : nil }
                let arguments = raw.flatMap { try? NemotronSuperOrderedJSON.parse($0) }
                let argumentOrder: Value? = if case .object? = arguments { arguments } else { nil }
                // OpenAI's member order for the call itself; templates read
                // its members by name.
                let order = Value.object([
                    "id": .undefined, "type": .undefined,
                    "function": .object(["name": .undefined, "arguments": argumentOrder ?? .undefined]),
                ])
                return overlay(call, order: order)
            })
            return ordered
        }
    }

    // MARK: - Overlay

    /// `value` (the normalized content) as a `Jinja.Value`, ordered and
    /// typed by `order` (the request's JSON) where the two agree. In the
    /// outermost `restoringLevels` objects a member only the request has is
    /// restored as sent.
    static func overlay(_ value: Any, order: Value?, restoringLevels: Int = 0) -> Value {
        if let members = objectMembers(value) {
            guard case .object(let sent)? = order else { return sortedObject(members) }
            var result = OrderedDictionary<String, Value>()
            for (key, sentValue) in sent {
                if let content = members[key] {
                    result[key] = overlay(content, order: sentValue, restoringLevels: restoringLevels - 1)
                } else if sentValue == .null || restoringLevels > 0 {
                    result[key] = sentValue
                }
            }
            for key in members.keys.sorted() where result[key] == nil {
                result[key] = overlay(members[key]!, order: nil)
            }
            return .object(result)
        }
        if let items = arrayItems(value) {
            guard case .array(let sent)? = order else { return .array(items.map { overlay($0, order: nil) }) }
            if items.count == sent.count {
                return .array(zip(items, sent).map { overlay($0, order: $1) })
            }
            // The sanitizer dropped the request's null items: put them back.
            guard items.count == sent.count(where: { $0 != .null }) else {
                return .array(items.map { overlay($0, order: nil) })
            }
            var remaining = items[...]
            return .array(sent.map { sentItem in
                sentItem == .null ? .null : overlay(remaining.removeFirst(), order: sentItem)
            })
        }
        let scalar = scalarValue(value)
        if let order, sameScalar(scalar, order) { return order }
        return scalar
    }

    private static func objectMembers(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: any Sendable] { return dictionary }
        if let dictionary = value as? [String: Any] { return dictionary }
        if case .object(let members)? = value as? Value {
            return Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value as Any) })
        }
        return nil
    }

    private static func arrayItems(_ value: Any) -> [Any]? {
        if case .array(let items)? = value as? Value { return items }
        if value is String { return nil }
        return value as? [Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if case .string(let text)? = value as? Value { return text }
        return nil
    }

    /// `Jinja.Value(any:)`'s ordering for content the request did not send.
    private static func sortedObject(_ members: [String: Any]) -> Value {
        var result = OrderedDictionary<String, Value>()
        for key in members.keys.sorted() { result[key] = overlay(members[key]!, order: nil) }
        return .object(result)
    }

    /// `Jinja.Value(any:)` for a leaf, with JSON nulls as `.null`.
    private static func scalarValue(_ value: Any) -> Value {
        if let value = value as? Value { return value }
        if let converted = try? Value(any: value) { return converted }
        if value is NSNull || isJSONNull(value) { return .null }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return .null }
            return overlay(wrapped.value, order: nil)
        }
        return .string("\(value)")
    }

    /// A normalized leaf the request sent as `order`: equal numbers of either
    /// kind, a Boolean bridged to an integer, or equal text.
    private static func sameScalar(_ value: Value, _ order: Value) -> Bool {
        switch (value, order) {
        case (.int(let lhs), .int(let rhs)): lhs == rhs
        case (.int(let lhs), .double(let rhs)): Double(lhs) == rhs
        case (.double(let lhs), .int(let rhs)): lhs == Double(rhs)
        case (.double(let lhs), .double(let rhs)): lhs == rhs || (lhs.isNaN && rhs.isNaN)
        case (.boolean(let lhs), .boolean(let rhs)): lhs == rhs
        case (.int(let lhs), .boolean(let rhs)): lhs == (rhs ? 1 : 0)
        case (.string(let lhs), .string(let rhs)): lhs == rhs
        case (.null, .null): true
        default: false
        }
    }

    private static func isJSONNull(_ value: Any) -> Bool {
        String(describing: type(of: value)) == "JSONNull"
            || String(reflecting: type(of: value)).contains("JSONNull")
    }
}
