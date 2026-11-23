import Foundation

extension MemoryOnlyCheckpointPool {
    /// Local `/metrics` text: counts and bytes only, never a tag, scope or token.
    var prometheusMetrics: String {
        let counts = snapshot
        var lines: [String] = []
        func family(_ name: String, _ type: String, _ help: String) {
            lines.append("# HELP \(name) \(help)")
            lines.append("# TYPE \(name) \(type)")
        }
        family("darkbloom_zdr_prefix_ram_lookups_total", "counter",
               "memory_only prefix lookups in the RAM-only tier, by outcome.")
        for outcome in LookupOutcome.allCases {
            lines.append("darkbloom_zdr_prefix_ram_lookups_total{outcome=\"\(outcome.rawValue)\"} \(counts.lookups[outcome] ?? 0)")
        }
        family("darkbloom_zdr_prefix_ram_hit_tokens_total", "counter",
               "Prompt tokens restored from the RAM-only tier.")
        lines.append("darkbloom_zdr_prefix_ram_hit_tokens_total \(counts.hitTokens)")
        family("darkbloom_zdr_prefix_ram_stores_total", "counter",
               "memory_only checkpoint donations to the RAM-only tier, by outcome.")
        for outcome in StoreOutcome.allCases {
            lines.append("darkbloom_zdr_prefix_ram_stores_total{outcome=\"\(outcome.rawValue)\"} \(counts.stores[outcome] ?? 0)")
        }
        family("darkbloom_zdr_prefix_ram_evictions_total", "counter",
               "RAM-only tier entries released, by reason.")
        for reason in EvictionReason.allCases {
            lines.append("darkbloom_zdr_prefix_ram_evictions_total{reason=\"\(reason.rawValue)\"} \(counts.evictions[reason] ?? 0)")
        }
        family("darkbloom_zdr_prefix_ram_unmarked_refusals_total", "counter",
               "RAM-only tier calls made for an ordinary request and refused; stays 0.")
        lines.append("darkbloom_zdr_prefix_ram_unmarked_refusals_total \(counts.unmarkedRefusals)")
        family("darkbloom_zdr_prefix_ram_bytes", "gauge", "Wired bytes the RAM-only tier holds.")
        lines.append("darkbloom_zdr_prefix_ram_bytes \(counts.bytes)")
        family("darkbloom_zdr_prefix_ram_entries", "gauge", "Checkpoints the RAM-only tier holds.")
        lines.append("darkbloom_zdr_prefix_ram_entries \(counts.entries)")
        family("darkbloom_zdr_prefix_ram_budget_bytes", "gauge", "The RAM-only tier's current budget; 0 is off.")
        lines.append("darkbloom_zdr_prefix_ram_budget_bytes \(counts.budgetBytes)")
        return lines.joined(separator: "\n") + "\n"
    }
}
