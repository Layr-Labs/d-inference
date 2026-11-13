// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// The declared tools of one request as the Qwen 3.5 XML call grammar sees
/// them. Not implemented yet: nothing compiles.
struct QwenStrictToolSchema: Sendable {
    struct ParserConversion: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case text, integer, number, boolean, object, array, null }
        let kind: Kind
        let acceptsNull: Bool
    }

    static func parserConversion(_ schema: MLXLMCommon.JSONValue?) -> ParserConversion {
        ParserConversion(kind: .text, acceptsNull: false)
    }
}
