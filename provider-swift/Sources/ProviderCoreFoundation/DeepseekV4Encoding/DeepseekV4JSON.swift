// Copyright © 2026 Eigen Labs.
//
// Canonical JSON serialization for the DeepSeek-V4 DSML encoder, mirroring
// Python's `json.dumps(value, ensure_ascii=False)` (used by `to_json` in
// `encoding_dsv4.py`): `", "` / `": "` separators, non-ASCII passed through
// verbatim, standard control-character escaping.
//
// KNOWN DEVIATION from the reference encoder: Python dicts (and hence
// `json.dumps`) preserve source-JSON key insertion order. Swift's
// `[String: any Sendable]` does not — by the time a tool schema or
// tool-call-arguments object reaches this layer (via `OpenAITool`'s
// `JSONValue`, or `decodeToolCallArguments`'s `JSONSerialization` round
// trip), its original wire key order is already unrecoverable. We sort
// object keys alphabetically instead of guessing: this keeps prompts
// byte-*stable* across process restarts (Swift's default `Dictionary`
// iteration order is salted per-process, which would otherwise make
// prefix-cache reuse and golden-fixture testing non-deterministic) even
// though it does not reproduce the reference implementation's exact byte
// layout for schema JSON. This is a systemic property shared by every other
// model family's Jinja tool-schema rendering in this codebase (none of them
// preserve wire key order either) — see `DeepseekV4EncodingTests` for how
// the golden fixtures verify schema JSON by parsed (semantic) equality
// instead of raw string equality.

import Foundation

enum DeepseekV4JSON {
    /// Serialize a `Sendable` value (String/Bool/Int/Double/NSNumber/NSNull/
    /// Array/Dictionary — the shapes produced by `JSONSerialization` and by
    /// hand-built Swift literals) to a JSON string.
    static func toJSON(_ value: any Sendable) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    /// Parse a JSON string into a `Sendable` value tree (String/NSNumber/
    /// Bool/NSNull/`[any Sendable]`/`[String: any Sendable]`), mirroring
    /// Python's `json.loads`. Used by `encodeArgumentsToDsml` to decode a
    /// tool call's raw `function.arguments` string — the shape the OpenAI
    /// wire actually carries before any upstream convenience decoding.
    /// Returns `nil` on malformed JSON, matching `json.loads` raising.
    static func parse(_ jsonString: String) -> (any Sendable)? {
        guard let data = jsonString.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return asSendable(object)
    }

    /// Recursively convert a `JSONSerialization` output tree (`Any`,
    /// dynamically String/NSNumber/NSNull/[Any]/[String: Any]) to `any
    /// Sendable`. All of `JSONSerialization`'s output types are themselves
    /// `Sendable`; this just re-expresses that under the existential the
    /// rest of the encoder is typed against.
    static func asSendable(_ value: Any) -> any Sendable {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v
        case is NSNull: return NSNull()
        case let v as [Any]: return v.map(asSendable)
        case let v as [String: Any]: return v.mapValues(asSendable)
        default: return String(describing: value)
        }
    }

    private static func write(_ value: any Sendable, into out: inout String) {
        switch value {
        case is NSNull:
            out += "null"
        case let v as String:
            writeString(v, into: &out)
        case let v as Bool:
            out += v ? "true" : "false"
        case let v as Int:
            out += String(v)
        case let v as Int64:
            out += String(v)
        case let v as Int32:
            out += String(v)
        case let v as Double:
            out += formatDouble(v)
        case let v as Float:
            out += formatDouble(Double(v))
        case let v as [any Sendable]:
            out += "["
            for (index, element) in v.enumerated() {
                if index > 0 { out += ", " }
                write(element, into: &out)
            }
            out += "]"
        case let v as [String: any Sendable]:
            out += "{"
            for (index, key) in v.keys.sorted().enumerated() {
                if index > 0 { out += ", " }
                writeString(key, into: &out)
                out += ": "
                write(v[key]!, into: &out)
            }
            out += "}"
        case let n as NSNumber:
            writeNSNumber(n, into: &out)
        default:
            // Best-effort fallback for unexpected Sendable payloads (should
            // not occur for well-formed OpenAI tool schemas/arguments).
            writeString(String(describing: value), into: &out)
        }
    }

    /// `NSNumber` from `JSONSerialization`/`decodeToolCallArguments` can wrap
    /// a bool, integer, or double; `CFNumberIsFloatType` is the reliable way
    /// to tell integers from doubles (Swift's `as? Bool`/`as? Int` dynamic
    /// casts already route true CFBoolean-backed numbers to the `Bool` case
    /// above, matching the existing `ParserUtilities.asSendable` convention
    /// used elsewhere in this codebase).
    private static func writeNSNumber(_ n: NSNumber, into out: inout String) {
        if CFNumberIsFloatType(n) {
            out += formatDouble(n.doubleValue)
        } else {
            out += String(n.int64Value)
        }
    }

    /// Format a double the way Python's `repr`/`json.dumps` would for the
    /// common cases our tool arguments exercise (finite, non-scientific
    /// magnitudes): shortest round-trip digits, always with a decimal point
    /// so `5.0` does not collapse into the integer `5`.
    private static func formatDouble(_ value: Double) -> String {
        if value.isNaN || value.isInfinite {
            // Not valid JSON; fall back to a literal Swift description
            // rather than emitting malformed output.
            return String(value)
        }
        var text = "\(value)"
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            text += ".0"
        }
        return text
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
