// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// The model-scoped template filters a family binds, selected by the
/// artifact's `model_type`. The scan-time render check and the runtime
/// tokenizer both read them here, so a template renders the same in both.
public enum ReferenceTemplateFilters {
    public static func additionalContext(modelType: String?) -> [String: any Sendable]? {
        NemotronTemplateFilters.additionalContext(modelType: modelType)
            ?? MuseGlimmerTemplateFilters.additionalContext(modelType: modelType)
    }

    public static func install(in environment: Environment, modelType: String?) {
        NemotronTemplateFilters.install(in: environment, modelType: modelType)
        MuseGlimmerTemplateFilters.install(in: environment, modelType: modelType)
    }
}
