import MLXLMServer

/// Diagnostic access to the production default parser selection and outbound
/// streaming transform. No model-name mapping or replay sanitizer lives here.
@_spi(Benchmarking)
public enum BenchmarkServingContent {
    public static func parserFormat(modelType: String?) -> String {
        ProviderLoop.inferReasoningParser(for: modelType).rawValue
    }

    public static func parse(chunks: [String], modelType: String?) -> String {
        var parser = StreamingReasoningParser(
            format: ProviderLoop.inferReasoningParser(for: modelType))
        var content = ""
        for chunk in chunks {
            for parsed in parser.parse(chunk) { content += parsed.content }
        }
        for parsed in parser.finish() { content += parsed.content }
        return content
    }
}
