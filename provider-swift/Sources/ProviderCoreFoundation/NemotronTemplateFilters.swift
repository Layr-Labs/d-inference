// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// Hugging Face-compatible filters for the Nemotron chat template.
///
/// The pinned template renders JSON-schema metadata with `string` and
/// `tojson`. Swift-Jinja's defaults intentionally follow Swift/Foundation,
/// while Transformers uses Python `str` and `json.dumps(ensure_ascii=False)`.
/// Keep this compatibility layer model-scoped so other families retain their
/// existing prompt bytes until independently qualified.
public enum NemotronTemplateFilters {
    private static let outputLimit = 16 << 20

    public static func applies(modelType: String?) -> Bool {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "nemotron_h"
    }

    public static func additionalContext(modelType: String?) -> [String: any Sendable]? {
        guard applies(modelType: modelType) else { return nil }
        return [
            stringFilterName: stringFilter,
            "tojson": toJSONFilter,
        ]
    }

    public static func install(in environment: Environment, modelType: String?) {
        guard applies(modelType: modelType) else { return }
        environment[stringFilterName] = stringFilter
        environment["tojson"] = toJSONFilter
    }

    private static let stringFilter = Value.function { args, kwargs, _ in
        let value = try soleDefaultArgument(args, kwargs)
        switch value {
        case .boolean(let flag): return .string(flag ? "True" : "False")
        case .null: return .string("None")
        case .undefined: return .string("")
        default: return .string(value.description)
        }
    }

    private static let toJSONFilter = PythonJSONTemplateFilter.make(
        family: "Nemotron", outputLimit: outputLimit)

    private static func soleDefaultArgument(
        _ args: [Value], _ kwargs: [String: Value]
    ) throws -> Value {
        guard args.count == 1, kwargs.isEmpty else {
            throw JinjaError.runtime(
                "Nemotron reference filters only support their pinned default arguments")
        }
        return args[0]
    }
}
