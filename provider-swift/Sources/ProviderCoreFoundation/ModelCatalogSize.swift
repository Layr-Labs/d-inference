import Foundation

/// Converts catalog size metadata into a non-negative byte count without
/// allowing malformed legacy `size_gb` values to trap at an integer cast.
public enum ModelCatalogSize {
    public static func bytes(
        totalSizeBytes: Int64?,
        sizeGB: Double
    ) -> Int64 {
        if let totalSizeBytes {
            return max(0, totalSizeBytes)
        }

        let estimate = (sizeGB * 1_000_000_000).rounded()
        guard !estimate.isNaN, estimate > 0 else {
            return 0
        }
        guard estimate.isFinite, estimate < Double(Int64.max) else {
            return Int64.max
        }
        return Int64(estimate)
    }
}
