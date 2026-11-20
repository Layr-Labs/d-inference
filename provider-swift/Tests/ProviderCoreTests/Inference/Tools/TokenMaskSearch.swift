/// Membership in token masks. `allowedTokenIDs` returns ascending ids (the
/// mask-equals-simulation checks of the constraint suites compare against
/// sorted lists). The masks inside strings hold most of a 248k- or 262k-piece
/// vocabulary, so a linear scan for each token can read most of the mask.
extension Array where Element == Int {
    /// Whether this ascending mask holds `token`, by binary search.
    func ascendingMaskContains(_ token: Int) -> Bool {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < token { low = middle + 1 } else { high = middle }
        }
        return low < count && self[low] == token
    }

    /// Whether the mask holds `token`, whatever its order: the binary search
    /// finds a held token of an ascending mask, and only a miss pays the scan.
    func maskContains(_ token: Int) -> Bool {
        ascendingMaskContains(token) || contains(token)
    }
}
