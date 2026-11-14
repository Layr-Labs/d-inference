// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// Hugging Face-compatible `tojson` for the Muse Glimmer chat template.
///
/// The template writes every tool's name, description and JSON schema, and
/// every structured tool-call argument, through `tojson`. Transformers renders
/// that as Python `json.dumps(ensure_ascii=False)`; Swift-Jinja's default
/// would write compact separators and escape non-ASCII text and slashes, a
/// tool block the model was not trained on. Mapping keys still arrive sorted,
/// as the Jinja bridge orders them for every family.
public enum MuseGlimmerTemplateFilters {
    private static let outputLimit = 16 << 20

    private static let toJSONFilter = PythonJSONTemplateFilter.make(
        family: "Muse Glimmer", outputLimit: outputLimit)

    public static func additionalContext(modelType: String?) -> [String: any Sendable]? {
        guard MuseGlimmerModelPolicy.isModelType(modelType) else { return nil }
        return ["tojson": toJSONFilter]
    }

    public static func install(in environment: Environment, modelType: String?) {
        guard MuseGlimmerModelPolicy.isModelType(modelType) else { return }
        environment["tojson"] = toJSONFilter
    }
}
