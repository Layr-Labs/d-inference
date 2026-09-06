import SwiftUI

struct ModelLibraryEmptyState: View {
    var scope: ModelScope = .installed
    var searchText = ""
    let onExplore: () -> Void

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DarkbloomTheme.chivo(23, weight: .medium))
                .foregroundStyle(StudioPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: onExplore)
                .buttonStyle(StudioPrimaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        if isSearching { return "No matching models" }
        return scope == .installed ? "Your first model starts here." : "No catalog models to show"
    }

    private var detail: String {
        if isSearching { return "Try another name or capability, or clear your search to see this collection." }
        return scope == .installed
            ? "Discover models that fit this Mac. Downloads are verified before they’re ready to use."
            : "Refresh the catalog to check which models are available."
    }

    private var buttonTitle: String {
        if isSearching { return "Clear search" }
        return scope == .installed ? "Discover models" : "Refresh catalog"
    }
}
