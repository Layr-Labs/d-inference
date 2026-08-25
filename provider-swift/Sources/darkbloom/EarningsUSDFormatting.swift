/// Renders integer micro-USD without converting through floating point.
/// `Int64.magnitude` keeps `Int64.min` representable, so every wire-valid
/// amount is formatted exactly.
func exactUSD(microUSD: Int64) -> String {
    let magnitude = microUSD.magnitude
    let whole = magnitude / 1_000_000
    let fractionalRaw = String(magnitude % 1_000_000)
    let fractional = String(repeating: "0", count: 6 - fractionalRaw.count) + fractionalRaw
    return "\(microUSD < 0 ? "-" : "")\(whole).\(fractional)"
}
