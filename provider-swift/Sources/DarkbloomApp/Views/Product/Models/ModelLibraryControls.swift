import SwiftUI

struct ModelLibraryControls: View {
    @Binding var scope: ModelScope
    @Binding var searchText: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                scopePicker
                Spacer(minLength: 0)
                searchField.frame(maxWidth: 300)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    scopePicker
                    Spacer()
                    refreshButton
                }
                searchField
            }
        }
    }

    private var scopePicker: some View {
        Picker("Model collection", selection: $scope) {
            ForEach(ModelScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 202)
        .accessibilityLabel("Model collection")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StudioPalette.secondaryInk)
                .accessibilityHidden(true)
            TextField("Search models", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .accessibilityLabel("Search models in the selected collection")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioPalette.secondaryInk)
                .accessibilityLabel("Clear model search")
                .help("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: 180)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchIsFocused ? StudioPalette.accent : StudioPalette.line, lineWidth: 1)
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(StudioPalette.secondaryInk)
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "Refreshing models" : "Refresh models")
        .help(isRefreshing ? "Refreshing models…" : "Refresh catalog and installed models")
    }
}
