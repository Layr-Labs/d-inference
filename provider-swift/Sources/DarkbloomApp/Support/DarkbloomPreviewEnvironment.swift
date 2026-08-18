import SwiftUI

private struct DarkbloomPreviewCaptureKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isCapturingDarkbloomPreview: Bool {
        get { self[DarkbloomPreviewCaptureKey.self] }
        set { self[DarkbloomPreviewCaptureKey.self] = newValue }
    }
}
