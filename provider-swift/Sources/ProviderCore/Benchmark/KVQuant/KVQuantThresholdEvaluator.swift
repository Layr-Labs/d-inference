import Foundation

struct KVQuantThresholdEvaluator {
    static func evaluate(report: KVQuantGateReport, thresholdsURL: URL, hardware: HardwareInfo?) -> KVQuantThresholdReport? {
        guard let data = try? Data(contentsOf: thresholdsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rules = selectedRules(object, hardware: hardware)
        let flattened = flattenThresholdRules(rules)
        guard !flattened.isEmpty else {
            return KVQuantThresholdReport(thresholdPath: thresholdsURL.path, checks: [])
        }

        let metrics = reportMetricValues(report)
        let checks = flattened.compactMap { metric, rule -> KVQuantThresholdCheck? in
            guard let value = metrics[metric] else { return nil }
            let min = rule["min"] as? Double ?? (rule["min"] as? NSNumber)?.doubleValue
            let max = rule["max"] as? Double ?? (rule["max"] as? NSNumber)?.doubleValue
            var failure: String? = nil
            if let min, value < min {
                failure = "\(metric)=\(value) is below min \(min)"
            }
            if let max, value > max {
                failure = "\(metric)=\(value) is above max \(max)"
            }
            return KVQuantThresholdCheck(
                metric: metric,
                value: value,
                min: min,
                max: max,
                status: failure == nil ? .passed : .failed,
                failureMessage: failure
            )
        }

        return KVQuantThresholdReport(thresholdPath: thresholdsURL.path, checks: checks)
    }

    private static func selectedRules(_ document: [String: Any], hardware: HardwareInfo?) -> [String: Any] {
        var rules = document["default"] as? [String: Any] ?? document["thresholds"] as? [String: Any] ?? [:]
        guard let group = chipGroup(hardware),
            let chips = document["chips"] as? [String: Any],
            let override = chips[group] as? [String: Any]
        else { return rules }
        rules = deepMerge(rules, override)
        return rules
    }

    private static func chipGroup(_ hardware: HardwareInfo?) -> String? {
        guard let family = hardware?.chipFamily.rawValue.lowercased() else { return nil }
        if family.hasPrefix("m1") || family.hasPrefix("m2") { return "m1_m2" }
        if family.hasPrefix("m3") || family.hasPrefix("m4") || family.hasPrefix("m5") { return "m3_m5" }
        return nil
    }

    private static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let lhs = result[key] as? [String: Any], let rhs = value as? [String: Any] {
                result[key] = deepMerge(lhs, rhs)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func flattenThresholdRules(_ rules: [String: Any], prefix: [String] = []) -> [(String, [String: Any])] {
        var result: [(String, [String: Any])] = []
        for (key, value) in rules {
            let path = prefix + [key]
            guard let dictionary = value as? [String: Any] else { continue }
            if dictionary.keys.contains("min") || dictionary.keys.contains("max") {
                result.append((path.joined(separator: "."), dictionary))
            } else {
                result.append(contentsOf: flattenThresholdRules(dictionary, prefix: path))
            }
        }
        return result
    }

    private static func reportMetricValues(_ report: KVQuantGateReport) -> [String: Double] {
        var values: [String: Double] = [:]
        for model in report.models {
            for suite in model.suites {
                if let quality = suite.quality {
                    for (key, summary) in quality.metrics {
                        if let value = summary.mean ?? summary.p50 ?? summary.min ?? summary.max {
                            values[key] = value
                        }
                    }
                }
                if let performance = suite.performance {
                    if let reference = performance.reference, let candidate = performance.candidate {
                        if let refDecode = reference.metrics["decode_tokens_per_second"]?.mean,
                            let candDecode = candidate.metrics["decode_tokens_per_second"]?.mean,
                            refDecode > 0
                        {
                            values["perf.decode_tps_ratio"] = candDecode / refDecode
                        }
                        if let refTotal = reference.metrics["total_time_ms"]?.mean,
                            let candTotal = candidate.metrics["total_time_ms"]?.mean,
                            refTotal > 0
                        {
                            values["perf.wall_time_ratio"] = candTotal / refTotal
                        }
                        if let refPeak = reference.memory.mlxGPUPeakBytes.max,
                            let candPeak = candidate.memory.mlxGPUPeakBytes.max,
                            refPeak > 0
                        {
                            values["memory.peak_memory_ratio"] = candPeak / refPeak
                            values["memory.memory_saved_pct"] = (1 - candPeak / refPeak) * 100
                        }
                    }
                }
            }
        }
        return values
    }
}
