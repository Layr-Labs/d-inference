import SwiftUI

struct AvailabilityView: View {
    let store: AvailabilityStore
    let providerSnapshot: ProviderSnapshot
    let onRequestProviderAction: (ProviderAction) -> Void
    let onRunSystemCheck: () -> Void

    @State private var editorIsPresented = false
    @State private var horizonObservationAnchor = Date.now
    @State private var horizonWallClockAnchor = Date.now

    /// Process state follows the live provider snapshot so actions update this
    /// page immediately. The availability store owns the schedule observation
    /// time and next boundary; those remain separate from provider controls.
    private var currentRuntime: AvailabilityRuntimeSnapshot {
        var current = AvailabilityRuntimeSnapshot(providerSnapshot: providerSnapshot)
        if let policyRuntime = store.runtime {
            current.sampledAt = policyRuntime.sampledAt
            current.sourceUpdatedAt = policyRuntime.sourceUpdatedAt
            current.nextObservedTransitionAt = policyRuntime.nextObservedTransitionAt
        }
        return current
    }

    var body: some View {
        Group {
            switch store.loadState {
            case .loading:
                statePage(.loading)

            case .malformed(let message, let issues):
                statePage(.malformed(message: message, issues: issues))

            case .ready, .stale:
                if let policy = store.savedPolicy {
                    policyPage(policy)
                } else {
                    statePage(.loading)
                }
            }
        }
        .navigationTitle("Availability")
        .sheet(isPresented: $editorIsPresented) {
            AvailabilityScheduleEditor(
                store: store,
                providerIsServing: providerSnapshot.isServing,
                onCancel: { editorIsPresented = false },
                onSaved: { editorIsPresented = false }
            )
        }
        .onAppear {
            synchronizeHorizonClock(to: currentRuntime.sampledAt)
        }
        .task {
            await store.refresh()
        }
        .onChange(of: currentRuntime.sampledAt) { _, sampledAt in
            synchronizeHorizonClock(to: sampledAt)
        }
    }

    private func policyPage(_ policy: AvailabilityPolicy) -> some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "This Mac",
                title: "Available on your terms.",
                subtitle: "Choose when this Mac joins the Darkbloom network—and see exactly what it’s doing right now."
            ) {
                Button(
                    policy.mode == .scheduled ? "Edit Schedule…" : "Edit Plan…",
                    systemImage: "calendar.badge.clock",
                    action: presentEditor
                )
                .buttonStyle(.bordered)
            }

            notices
                .padding(.top, 20)

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                BloomHorizon(
                    policy: policy,
                    runtime: currentRuntime,
                    now: horizonTime(at: timeline.date)
                )
            }
            .padding(.top, 16)

            AvailabilityRuntimeControlSection(
                policy: policy,
                runtime: currentRuntime,
                providerSnapshot: providerSnapshot,
                onRequestProviderAction: onRequestProviderAction,
                onRunSystemCheck: onRunSystemCheck
            )
            .padding(.top, 28)

            sectionDivider

            AvailabilityPlanSection(
                policy: policy,
                onSelectMode: selectMode,
                onEdit: presentEditor
            )

            sectionDivider

            AvailabilityScheduleSummarySection(
                policy: policy,
                onEdit: presentEditor
            )

            sectionDivider

            AvailabilityIdleUnloadSection(
                policy: policy,
                onEdit: presentEditor
            )

            sectionDivider

            AvailabilityBehaviorSection()

            Text(store.isLive
                ? "Availability is evaluated in this Mac’s current local timezone. Saving writes the provider configuration; the provider applies it on its next restart."
                : "Availability is evaluated in this Mac’s current local timezone. Schedule changes in this UI preview do not edit the provider configuration or restart a process.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 9) {
            if case .stale(_, let message) = store.loadState {
                AvailabilityInlineNotice(
                    title: "Showing an older observation",
                    detail: message,
                    systemImage: "clock.badge.exclamationmark",
                    tint: ProductPalette.warning
                )
            }

            switch store.saveState {
            case .savedAndRestarted:
                AvailabilityInlineNotice(
                    title: "Availability preview saved",
                    detail: "The sample policy was updated. No provider configuration changed and no process restarted.",
                    systemImage: "checkmark.circle.fill",
                    tint: ProductPalette.positive,
                    onDismiss: { store.dismissSaveResult() }
                )

            case .savedRequiresRestart:
                AvailabilityInlineNotice(
                    title: "Schedule saved — restart to apply",
                    detail: "The provider configuration is updated. Restart the provider for the new availability to take effect.",
                    systemImage: "arrow.clockwise.circle.fill",
                    tint: ProductPalette.warning,
                    onDismiss: { store.dismissSaveResult() }
                )
                Button("Restart Provider Now", systemImage: "arrow.clockwise") {
                    onRequestProviderAction(.restart)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)

            case .failed(let message):
                AvailabilityInlineNotice(
                    title: "Changes were not saved",
                    detail: store.isLive
                        ? message
                        : "\(message) No provider configuration or process changed.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: ProductPalette.critical
                )

            case .validationFailed:
                AvailabilityInlineNotice(
                    title: "Schedule needs review",
                    detail: "Open the editor to review the schedule. No provider configuration or process changed.",
                    systemImage: "exclamationmark.circle.fill",
                    tint: ProductPalette.critical
                )

            case .idle, .saving:
                EmptyView()
            }
        }
    }

    private func statePage(_ kind: AvailabilityStateView.Kind) -> some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "This Mac",
                title: "Available on your terms.",
                subtitle: "Choose when this Mac joins the Darkbloom network."
            )

            AvailabilityStateView(
                kind: kind,
                onRunSystemCheck: onRunSystemCheck
            )
            .padding(.top, 20)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 26)
    }

    private func selectMode(_ mode: AvailabilityPolicyMode) {
        if store.draft?.mode != mode {
            store.setMode(mode)
        }
        editorIsPresented = true
    }

    private func presentEditor() {
        editorIsPresented = true
    }

    private func synchronizeHorizonClock(to observation: Date) {
        horizonObservationAnchor = observation
        horizonWallClockAnchor = .now
    }

    private func horizonTime(at wallClock: Date) -> Date {
        horizonObservationAnchor.addingTimeInterval(
            max(0, wallClock.timeIntervalSince(horizonWallClockAnchor))
        )
    }
}
