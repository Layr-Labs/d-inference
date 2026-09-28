import Foundation

/// Identity shared by trace capture and the deliberately overridden-route control.
func qwenRoutingIdentity(loaded: LoadedModel, options: Options,
                         prompt: [Int], teacher: [Int]?) throws -> [String: String] {
    [
        "configurationSHA256": loaded.configHash,
        "promptSHA256": sha256(try JSONEncoder().encode(prompt)),
        "teacherSHA256": sha256(try JSONEncoder().encode(teacher ?? [])),
        "decodeInputsSHA256": sha256(try JSONEncoder().encode(teacher ?? [])),
        "syntheticDType": options.syntheticDType,
        "syntheticProfile": options.syntheticProfile,
        "attentionOutputPrecision": options.attentionOutputPrecision.rawValue,
        "seed": String(options.seed), "chunkSize": String(options.chunkSize),
        "promptTokens": String(prompt.count), "decodeTokens": String(options.decodeCount),
    ]
}
