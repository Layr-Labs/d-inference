import Foundation

/// Compiled review-controlled data only. A malformed/invalid/duplicate record
/// disables the entire catalog, retaining the ordinary conservative predictor.
/// This never reads a provider/operator path at runtime.
enum DeadlineProfileCatalog {
    static func decode(_ json: String) -> [DeadlinePerformanceProfile] {
        guard let profiles = try? JSONDecoder().decode([DeadlinePerformanceProfile].self,
            from: Data(json.utf8)) else { return [] }
        var ids = Set<String>()
        for profile in profiles {
            guard profile.isValid, ids.insert(profile.id).inserted else { return [] }
        }
        return profiles
    }
}
