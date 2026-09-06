import SwiftUI

struct ProviderOverviewView: View {
    let identity: MachineIdentity
    let store: ProviderStore
    let needsSetup: Bool
    let localSessionIsActive: Bool
    let onContinueSetup: () -> Void
    let onOpenChat: () -> Void
    let onOpenAvailability: () -> Void
    let onOpenMachine: () -> Void
    let onRequestAction: (ProviderAction) -> Void

    private var snapshot: ProviderSnapshot { store.snapshot }
    private var presentation: ProviderStatePresentation { snapshot.presentation }

    var body: some View {
        ProductPage {
            NetworkIntroductionView()
                .padding(.bottom, 30)
            ProductSectionHeader("Share this Mac’s compute", detail: identity.displayName)
            Text("Network sharing is separate from local AI in Studio. Choose when this Mac can accept network work, and pause sharing whenever you need it.")
                .font(.system(size: 13))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            if localSessionIsActive {
                HStack(spacing: 16) {
                    Text("End your local Studio session before starting network sharing.")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.secondaryInk)
                    Spacer(minLength: 0)
                    Button("Open Studio", action: onOpenChat)
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioPalette.accent)
                }
                .padding(.vertical, 18)
            }

            if needsSetup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your account, verify this Mac, and choose a model to contribute.")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioPalette.secondaryInk)
                    Button("Connect this Mac", action: onContinueSetup)
                        .buttonStyle(StudioPrimaryButtonStyle())
                        .disabled(localSessionIsActive)
                }
                .padding(.vertical, 20)
            } else {
                providerHero
            }

            if let problem = snapshot.lastProblem {
                problemBanner(problem)
                    .padding(.top, 14)
            }

            if !needsSetup, snapshot.pid != nil {
                metrics.padding(.top, 28)
            }

            if !needsSetup {
                providerDetails.padding(.top, 14)
            }
        }
        .navigationTitle("Network status")
        .task {
            store.startMonitoring()
        }
    }

    private var providerHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Circle().fill(presentation.tint).frame(width: 7, height: 7)
                Text(presentation.overline.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.secondaryInk)
                Spacer()
                Text(identity.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
            }
            Text(presentation.title)
                .font(DarkbloomTheme.chivo(26))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.detail)
                .font(.system(size: 14))
                .foregroundStyle(StudioPalette.secondaryInk)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button {
                    if snapshot.runState == .scheduledOff { onOpenAvailability() }
                    else if needsVerificationReview { onOpenMachine() }
                    else { onRequestAction(store.primaryAction) }
                } label: {
                    if store.pendingAction != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(needsVerificationReview ? "Review verification" : presentation.primaryActionTitle)
                    }
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(store.pendingAction != nil ||
                    (localSessionIsActive && (store.primaryAction == .start || store.primaryAction == .restart)) ||
                    (snapshot.runState != .scheduledOff && !needsVerificationReview && !store.canPerform(store.primaryAction)))
                Button("Manage availability", action: onOpenAvailability)
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioPalette.accent)
                if store.canPerform(.restart) {
                    Button("Restart provider") { onRequestAction(.restart) }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .disabled(localSessionIsActive)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { StudioPalette.line.frame(height: 1) }
    }

    private var needsVerificationReview: Bool {
        snapshot.runState == .attention || (snapshot.runState == .online && snapshot.trust.state != .verified)
    }

    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            ProductMetricTile(
                label: "Requests",
                value: snapshot.activity.requestsServed.formatted(),
                detail: "Since provider started"
            )
            ProductMetricTile(
                label: "Tokens",
                value: ProductFormat.compactCount(snapshot.activity.tokensGenerated),
                detail: "Since provider started"
            )
            ProductMetricTile(
                label: "Uptime",
                value: ProductFormat.duration(snapshot.uptime),
                detail: snapshot.pid.map { "Process \($0)" } ?? "Provider is offline"
            )
            ProductMetricTile(
                label: "Inference memory",
                value: ProductFormat.memory(snapshot.capacity?.usedMemoryGB),
                detail: snapshot.capacity.map { "of \(ProductFormat.memory($0.totalMemoryGB))" } ?? "Available when online"
            )
        }
    }

    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Network provider")

            VStack(spacing: 17) {
                Button(action: onOpenMachine) {
                    ProductDisclosureRow(
                        icon: snapshot.trust.state == .verified ? "checkmark.shield.fill" : "shield.lefthalf.filled.badge.checkmark",
                        title: snapshot.trust.level,
                        detail: snapshot.trust.reason,
                        tint: snapshot.trust.state == .verified ? ProductPalette.positive : ProductPalette.warning
                    )
                }
                .buttonStyle(.plain)

                Divider()

                Button(action: onOpenAvailability) {
                    ProductDisclosureRow(
                        icon: "calendar.badge.clock",
                        title: snapshot.availability.summary,
                        detail: ProductFormat.nextChange(snapshot.availability.nextChangeAt),
                        tint: DarkbloomTheme.accent
                    )
                }
                .buttonStyle(.plain)

                Divider()

                ProductDisclosureRow(
                    icon: "cube.transparent",
                    title: snapshot.currentModel?.displayName ?? "Models ready",
                    detail: warmModelDetail,
                    tint: DarkbloomTheme.accent,
                    showsChevron: false
                )
            }
            .padding(17)
            .productSurface()
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }


    private func problemBanner(_ problem: ProviderProblem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: problem.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(problem.severity == .critical ? ProductPalette.critical : ProductPalette.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(problem.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let recoveryTitle = problem.recoveryTitle {
                Button(recoveryTitle) {
                    if snapshot.runState == .stale {
                        onRequestAction(.restart)
                    } else {
                        onOpenMachine()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(ProductPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(ProductPalette.warning.opacity(0.18), lineWidth: 1)
        }
    }

    private var warmModelDetail: String {
        guard !snapshot.warmModels.isEmpty else { return "No models are resident" }
        let names = snapshot.warmModels.map(\.displayName).joined(separator: ", ")
        return "Warm: \(names)"
    }

}
