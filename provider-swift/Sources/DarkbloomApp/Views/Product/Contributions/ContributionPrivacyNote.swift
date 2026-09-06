import SwiftUI

struct ContributionPrivacyNote: View {
    var body: some View {
        Label("Only accounting metadata appears here. Prompts and responses stay out of this ledger.", systemImage: "lock")
            .font(.system(size: 11))
            .foregroundStyle(StudioPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}
