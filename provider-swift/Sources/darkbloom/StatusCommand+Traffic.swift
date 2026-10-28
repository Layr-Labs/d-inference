import ProviderCore

extension Status {
    /// "Is the coordinator routing work to this Mac?" A connected provider
    /// with a warm model can still receive nothing; this line says why.
    static func trafficLines(_ verdict: ServingReadiness.Verdict) -> [String] {
        switch verdict {
        case .authorized(let detail):
            return ["Traffic: eligible for coordinator work (\(detail))"]
        case .pending(let detail):
            return ["Traffic: not yet eligible (\(detail))"]
        case .unconfirmed(let detail):
            return ["Traffic: unconfirmed (\(detail))"]
        case .blocked(let advice):
            return ["Traffic: NOT receiving coordinator work: \(advice.message)"]
                + (advice.fix.map { ["  → fix: \($0)"] } ?? [])
        }
    }
}
