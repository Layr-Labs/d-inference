import SwiftUI

struct ProductSidebarView: View {
    @Binding var selection: ProductDestination?
    let snapshot: ProviderSnapshot

    var body: some View {
        List(selection: $selection) {
            BrandWordmarkView(color: .primary)
                .padding(.horizontal, 4)
                .padding(.top, 5)
                .padding(.bottom, 12)
                .listRowBackground(Color.clear)

            Section {
                destinationRow(.overview)
            }

            Section("Use Darkbloom") {
                destinationRow(.chat)
                destinationRow(.localAPI)
            }

            Section("Network") {
                destinationRow(.myMacs)
                destinationRow(.contributions)
            }

            Section("This Mac") {
                destinationRow(.availability)
                destinationRow(.activity)
                destinationRow(.models)
                destinationRow(.machine)
            }

            Section {
                SidebarProviderStatus(snapshot: snapshot)
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Darkbloom")
    }

    private func destinationRow(_ destination: ProductDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
            .contentShape(Rectangle())
            .accessibilityHint("Show \(destination.title)")
    }
}
