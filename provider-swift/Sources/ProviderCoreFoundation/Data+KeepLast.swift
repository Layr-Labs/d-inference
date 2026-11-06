import Foundation

extension Data {
    /// Keeps only the last `maxCount` bytes, in new storage, and tells whether
    /// it dropped any.
    ///
    /// A copy, not `removeFirst` or `suffix`: those slice, and a slice keeps
    /// every byte before it in its storage, so a bounded output tail would
    /// still hold all the output it was given.
    @discardableResult
    public mutating func keepLast(_ maxCount: Int) -> Bool {
        guard count > maxCount else { return false }
        self = Data(suffix(maxCount))
        return true
    }
}
