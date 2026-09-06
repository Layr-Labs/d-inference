import SwiftUI

enum StudioSection: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case library = "Library"
    case network = "Network"
    case machine = "This Mac"

    var id: Self { self }
    var destination: ProductDestination {
        switch self {
        case .studio: .overview
        case .library: .models
        case .network: .networkOverview
        case .machine: .machine
        }
    }

    init(destination: ProductDestination) {
        switch destination {
        case .overview, .chat, .localAPI: self = .studio
        case .models: self = .library
        case .networkOverview, .myMacs, .contributions: self = .network
        case .availability, .activity, .machine: self = .machine
        }
    }
}

struct StudioNavigation: View {
    let destination: ProductDestination
    let needsSetup: Bool
    let onSelect: (ProductDestination) -> Void
    let onContinueSetup: () -> Void
    let onDiagnostics: () -> Void

    private var section: StudioSection { StudioSection(destination: destination) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Button { onSelect(.overview) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(StudioPalette.accent)
                        Text("Darkbloom")
                            .font(DarkbloomTheme.chivo(23, weight: .medium))
                            .tracking(-0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Darkbloom Studio")

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    ForEach(StudioSection.allCases) { item in
                        Button { onSelect(item.destination) } label: {
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: section == item ? .semibold : .medium))
                                .foregroundStyle(section == item ? StudioPalette.ink : StudioPalette.secondaryInk)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(section == item ? StudioPalette.accentSoft : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }

                Menu {
                    Button("Connect your tools", systemImage: "chevron.left.forwardslash.chevron.right") { onSelect(.localAPI) }
                    Button("System check", systemImage: "stethoscope", action: onDiagnostics)
                    if needsSetup {
                        Button("Set up network sharing", systemImage: "network", action: onContinueSetup)
                    }
                    Divider()
                    SettingsLink()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Workspace settings and tools")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 19)

            if !secondaryDestinations.isEmpty {
                HStack(spacing: 20) {
                    ForEach(secondaryDestinations) { item in
                        Button { onSelect(item) } label: {
                            Text(item.title)
                                .font(.system(size: 12, weight: destination == item ? .semibold : .regular))
                                .foregroundStyle(destination == item ? StudioPalette.accent : StudioPalette.secondaryInk)
                                .padding(.vertical, 12)
                                .overlay(alignment: .bottom) {
                                    if destination == item {
                                        Capsule().fill(StudioPalette.accent).frame(height: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if needsSetup && section == .network {
                        Button("Set up sharing", action: onContinueSetup)
                            .buttonStyle(.plain)
                            .foregroundStyle(StudioPalette.accent)
                    }
                }
                .padding(.horizontal, 34)
            }
        }
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.surface)
        .overlay(alignment: .bottom) { StudioPalette.line.frame(height: 1) }
    }

    private var secondaryDestinations: [ProductDestination] {
        switch section {
        case .network: [.networkOverview, .myMacs, .contributions]
        case .machine: [.machine, .availability, .activity]
        case .studio: destination == .localAPI ? [.overview, .localAPI] : []
        case .library: []
        }
    }
}
