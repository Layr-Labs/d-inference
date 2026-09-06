import SwiftUI

/// A still from Darkbloom's own spatial field gives the working surface its
/// identity without continuously competing with inference for GPU time.
struct StudioPresence: View {
    var body: some View {
        SpatialFieldView(presentation: .bloom, focus: 0.38, activity: 0.24, allowsAnimation: false)
            .frame(width: 172, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 56, style: .continuous))
            .rotationEffect(.degrees(-12))
            .accessibilityHidden(true)
    }
}
