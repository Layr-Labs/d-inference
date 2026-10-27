import MLXLMCommon

extension CBv2LayerKind {
    /// How many committed tokens a row of this kind holds at a frontier: every
    /// one for full attention, at most its window for a sliding layer.
    func retainedTokens(atFrontier count: Int) -> Int {
        switch attention {
        case .full: return count
        case .slidingWindow(let window): return min(count, window)
        }
    }
}
