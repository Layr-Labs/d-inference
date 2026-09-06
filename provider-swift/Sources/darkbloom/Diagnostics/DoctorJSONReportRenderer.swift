import Foundation
import ProviderCore

/// Renders a `DoctorReport` as ONE JSON document on a single line. Sorted
/// keys make the bytes deterministic — the golden test pins the exact string,
/// and stdout carries nothing else (the command skips the update banner and
/// the human report in `--json` mode).
enum DoctorJSONReportRenderer {
    static func render(_ report: DoctorReport) throws -> String {
        let encoder = JSONEncoder()
        // Sorted keys make the bytes deterministic (golden-pinned);
        // unescaped slashes keep the operator-facing details (URLs, model
        // ids like `mlx-community/Qwen...`, shell snippets) readable and
        // stable for the app's decoder either way.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }
}
