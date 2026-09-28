import Foundation

/// The same legacy source/host bounds, shared with LocalCorrectnessStorage.
/// These constants are not adjustable by a caller or a registered profile.
enum QwenDenseLegacySourceBounds {
    static let maximumSourceModelTensorBytes = 6 * 1024 * 1024 * 1024
    static let maximumHostTensorBytes = 512 * 1024 * 1024
}
