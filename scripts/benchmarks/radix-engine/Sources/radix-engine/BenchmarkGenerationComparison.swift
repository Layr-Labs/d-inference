import Foundation
import CryptoKit

/// Offline benchmark policy only. Structural validation is independent of this policy.
enum BenchmarkGenerationComparisonPolicy: String, Sendable {
    case strict, record

    func rejectsTokenDifference(_ equal: Bool) -> Bool { self == .strict && !equal }
}

enum BenchmarkGenerationComparison {
    private static func digest(_ tokens: [Int]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: tokens)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Compare every available same-prompt observation, including all original
    /// repeat/tenant/donor/recovery relations. Paths disambiguate repeated row IDs.
    static func records(_ report: [String: Any]) throws -> [[String: Any]] {
        var rows: [(String, [String: Any])] = []
        for key in ["rows", "tenant_checks"] {
            for (index, row) in ((report[key] as? [[String: Any]]) ?? []).enumerated() {
                rows.append(("\(key)[\(index)]", row))
            }
        }
        for key in ["cancel_donor", "cancelled", "recovered"] {
            if let row = report[key] as? [String: Any] { rows.append((key, row)) }
        }
        func identity(_ path: String, _ row: [String: Any], _ tokens: [Int], _ prompt: [Int]) throws -> [String: Any] {
            ["path": path, "id": row["id"] ?? NSNull(), "kind": row["kind"] ?? NSNull(),
             "scope": row["scope"] ?? NSNull(), "finish": row["finish"] ?? NSNull(),
             "completion_tokens": row["completion_tokens"] ?? NSNull(),
             "token_ids_sha256": try digest(tokens), "prompt_token_ids_sha256": try digest(prompt)]
        }
        var result: [[String: Any]] = []
        for i in rows.indices {
            let (lp, left) = rows[i]
            guard let lt = left["token_ids"] as? [Int], !lt.isEmpty,
                  let prompt = left["prompt_token_ids"] as? [Int], !prompt.isEmpty else { continue }
            for j in rows.indices where j > i {
                let (rp, right) = rows[j]
                guard let rt = right["token_ids"] as? [Int], !rt.isEmpty,
                      right["prompt_token_ids"] as? [Int] == prompt else { continue }
                let prefix = lp == "cancelled" || rp == "cancelled"
                let count = prefix ? (lp == "cancelled" ? lt.count : rt.count) : max(lt.count, rt.count)
                let difference = (0..<count).first { $0 >= lt.count || $0 >= rt.count || lt[$0] != rt[$0] }
                result.append(["left": try identity(lp, left, lt, prompt),
                               "right": try identity(rp, right, rt, prompt),
                               "comparison": prefix ? "cancelled_prefix" : "exact_generated_tokens",
                               "tokens_equal": difference == nil,
                               "first_difference_zero_based": difference as Any? ?? NSNull(),
                               "outcome": difference == nil ? "PASS" : "FAIL"])
            }
        }
        return result
    }
}
