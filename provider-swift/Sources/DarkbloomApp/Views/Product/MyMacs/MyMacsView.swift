import AppKit
import SwiftUI

struct MyMacsView: View {
    let store: MyMacsStore
    let currentMachine: MachineIdentity
    let onOpenContributions: () -> Void
    let onOpenHardware: () -> Void
    let onOpenActivity: () -> Void
    let onOpenModels: () -> Void
    let onRunSystemCheck: () -> Void

    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var statusFilter = MyMacsStatusFilter.all
    @State private var attentionFilter = MyMacsAttentionFilter.all
    @State private var revealedSerialID: String?
    @State private var copiedSerialID: String?
    @State private var showsLinkAnotherMac = false
    @State private var removalRequest: MyMacRemovalRequest?

    init(
        store: MyMacsStore,
        currentMachine: MachineIdentity,
        onOpenContributions: @escaping () -> Void,
        onOpenHardware: @escaping () -> Void,
        onOpenActivity: @escaping () -> Void,
        onOpenModels: @escaping () -> Void,
        onRunSystemCheck: @escaping () -> Void
    ) {
        self.store = store
        self.currentMachine = currentMachine
        self.onOpenContributions = onOpenContributions
        self.onOpenHardware = onOpenHardware
        self.onOpenActivity = onOpenActivity
        self.onOpenModels = onOpenModels
        self.onRunSystemCheck = onRunSystemCheck
        _selectedID = State(initialValue: MyMacsPresentation.defaultSelection(
            in: store.macs,
            currentSerialNumber: currentMachine.serialNumber
        ))
    }

    private var filteredMacs: [MyMac] {
        MyMacsPresentation.filtered(
            store.macs,
            searchText: searchText,
            status: statusFilter,
            attention: attentionFilter
        )
    }

    private var selectedMac: MyMac? {
        selectedID.flatMap(store.mac)
    }

    var body: some View {
        ProductPage {
            VStack(alignment: .leading, spacing: 22) {
                ProductPageHeader(
                    eyebrow: "Network",
                    title: "Your Macs, together.",
                    subtitle: "See every Mac linked to your Darkbloom account—what is connected, what it has reported, and what may need your attention."
                ) {
                    if let lastUpdated {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("Updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            if store.canRefresh {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    store.refresh()
                                }
                                .controlSize(.small)
                                .help(store.mode == .live
                                    ? "Refresh linked Macs"
                                    : "Refresh this UI preview snapshot")
                            }
                        }
                    }
                }

                stateContent
            }
        }
        .onChange(of: selectedID) { _, _ in
            hideSensitiveDetails()
        }
        .onChange(of: searchText) { _, _ in
            reconcileFilteredSelection()
        }
        .onChange(of: statusFilter) { _, _ in
            reconcileFilteredSelection()
        }
        .onChange(of: attentionFilter) { _, _ in
            reconcileFilteredSelection()
        }
        .onChange(of: store.macs.map(\.id)) { _, _ in
            reconcileFilteredSelection()
        }
        .onChange(of: currentMachine.serialNumber) { _, _ in
            reconcileCurrentMachineIdentity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hideSensitiveDetails()
        }
        .onDisappear(perform: hideSensitiveDetails)
        // Live mode only: session check + first fleet fetch when the
        // destination appears. Fixture previews ignore it (deterministic).
        .task { store.start() }
        .sheet(isPresented: $showsLinkAnotherMac) {
            LinkAnotherMacSheet()
        }
        .confirmationDialog(
            removalRequest.map { "Remove \($0.title) from this account?" }
                ?? "Remove this Mac from this account?",
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Account", role: .destructive) {
                confirmRemoval()
            }
            Button("Cancel", role: .cancel) {
                removalRequest = nil
            }
        } message: {
            Text(MyMacRemovalPresentation.confirmationMessage)
        }
        .navigationTitle("My Macs")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.availability {
        case .loading:
            MyMacsStateView(kind: .loading, message: nil, onRetry: nil)

        case .signedOut:
            MyMacsStateView(
                kind: .signedOut,
                message: store.signInErrorMessage,
                onRetry: nil,
                actionTitle: store.isSigningIn ? "Signing In…" : "Sign In",
                actionSystemImage: "person.crop.circle",
                onAction: signIn,
                actionDisabled: store.isSigningIn
            )

        case let .unavailable(message):
            MyMacsStateView(
                kind: .unavailable,
                message: message,
                onRetry: store.retry
            )

        case let .ready(_, summaryAvailability):
            loadedContent(summaryAvailability: summaryAvailability, staleMessage: nil)

        case let .staleRetained(_, _, message, summaryAvailability):
            loadedContent(summaryAvailability: summaryAvailability, staleMessage: message)
        }
    }

    @ViewBuilder
    private func loadedContent(
        summaryAvailability: MyMacsSummaryAvailability,
        staleMessage: String?
    ) -> some View {
        if store.isEmpty {
            MyMacsStateView(
                kind: .empty,
                message: nil,
                onRetry: nil,
                actionTitle: "How to Link Another Mac",
                actionSystemImage: "plus.rectangle.on.rectangle",
                onAction: { showsLinkAnotherMac = true }
            )
        } else if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 18) {
                if let staleMessage {
                    MyMacsBanner(
                        title: "Showing an earlier snapshot",
                        detail: staleMessage,
                        systemImage: "clock.arrow.circlepath"
                    )
                }

                FleetBloomline(
                    macs: snapshot.macs,
                    selectedID: selectedID,
                    onSelect: selectFromBloomline
                )

                inventoryAndDetail

                MyMacsAccountSummaryView(
                    summary: snapshot.accountSummary,
                    availability: summaryAvailability,
                    onOpenContributions: onOpenContributions
                )
            }
        } else {
            MyMacsStateView(
                kind: .unavailable,
                message: "The inventory response did not include a usable snapshot.",
                onRetry: nil
            )
        }
    }

    private var inventoryAndDetail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                inventoryList
                    .frame(width: 205)
                    .frame(maxHeight: .infinity)

                Divider()

                ScrollView(.vertical) {
                    detail
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.trailing, 10)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .accessibilityLabel("Selected Mac details")
            }
            .frame(
                minWidth: 590,
                minHeight: 420,
                idealHeight: 420,
                maxHeight: 420,
                alignment: .leading
            )

            VStack(alignment: .leading, spacing: 22) {
                inventoryList
                Divider()
                detail
            }
        }
    }

    private var inventoryList: some View {
        MyMacsInventoryList(
            macs: filteredMacs,
            fleet: store.macs,
            currentSerialNumber: currentMachine.serialNumber,
            selection: $selectedID,
            searchText: $searchText,
            statusFilter: $statusFilter,
            attentionFilter: $attentionFilter
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let mac = selectedMac {
            MyMacDetailView(
                mac: mac,
                fleet: store.macs,
                isThisMac: MyMacsPresentation.isThisMac(
                    mac,
                    currentSerialNumber: currentMachine.serialNumber
                ),
                serialIsRevealed: revealedSerialID == mac.id,
                serialWasCopied: copiedSerialID == mac.id,
                onToggleSerial: {
                    copiedSerialID = nil
                    revealedSerialID = revealedSerialID == mac.id ? nil : mac.id
                },
                onCopySerial: { copySerial(for: mac) },
                onOpenHardware: onOpenHardware,
                onOpenActivity: onOpenActivity,
                onOpenModels: onOpenModels,
                onRunSystemCheck: onRunSystemCheck,
                onRequestRemoval: { requestRemoval(of: mac) }
            )
        } else {
            ContentUnavailableView {
                Label("Select a Mac", systemImage: "cursorarrow.click.2")
            } description: {
                Text("Choose a linked Mac to inspect its latest report.")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private var lastUpdated: Date? {
        switch store.availability {
        case let .ready(lastUpdated, _), let .staleRetained(lastUpdated, _, _, _):
            lastUpdated
        case .loading, .signedOut, .unavailable:
            nil
        }
    }

    private func selectFromBloomline(_ id: String) {
        if !filteredMacs.contains(where: { $0.id == id }) {
            searchText = ""
            statusFilter = .all
            attentionFilter = .all
        }
        selectedID = id
    }

    private func reconcileInventorySelection() {
        if let selectedID, store.mac(id: selectedID) != nil {
            return
        }
        selectedID = MyMacsPresentation.defaultSelection(
            in: store.macs,
            currentSerialNumber: currentMachine.serialNumber
        )
    }

    private func reconcileCurrentMachineIdentity() {
        if let thisMac = store.macs.first(where: {
            MyMacsPresentation.isThisMac(
                $0,
                currentSerialNumber: currentMachine.serialNumber
            )
        }) {
            if !filteredMacs.contains(where: { $0.id == thisMac.id }) {
                searchText = ""
                statusFilter = .all
                attentionFilter = .all
            }
            selectedID = thisMac.id
            return
        }
        reconcileInventorySelection()
    }

    private func reconcileFilteredSelection() {
        guard !filteredMacs.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, filteredMacs.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = MyMacsPresentation.defaultSelection(
            in: filteredMacs,
            currentSerialNumber: currentMachine.serialNumber
        )
    }

    private func hideSensitiveDetails() {
        revealedSerialID = nil
        copiedSerialID = nil
    }

    private func copySerial(for mac: MyMac) {
        guard let serialNumber = mac.serialNumber else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serialNumber, forType: .string)
        copiedSerialID = mac.id
        AccessibilityNotification.Announcement("Serial number copied").post()
    }

    private func signIn() {
        store.signIn()
        reconcileFilteredSelection()
        // Fixture sign-in resolves synchronously; live sign-in is async — the
        // announcement only fires for the deterministic preview transition.
        if store.mode == .fixture, case .ready = store.availability {
            AccessibilityNotification.Announcement("Signed in to the My Macs UI preview").post()
        }
    }

    private func requestRemoval(of mac: MyMac) {
        guard mac.canRemove, mac.removalToken != nil else { return }
        hideSensitiveDetails()
        removalRequest = MyMacRemovalRequest(
            macID: mac.id,
            title: MyMacsPresentation.title(for: mac, in: store.macs)
        )
    }

    private func confirmRemoval() {
        guard let removalRequest else { return }
        self.removalRequest = nil
        Task {
            // Fixture removals apply synchronously; live removals await the
            // coordinator DELETE before local bookkeeping lands.
            let removed = await store.removeMac(id: removalRequest.macID)
            if removed {
                reconcileFilteredSelection()
                AccessibilityNotification.Announcement("Mac removed from this account").post()
            }
        }
    }
}

private struct MyMacRemovalRequest: Identifiable {
    let macID: String
    let title: String

    var id: String { macID }
}

enum MyMacRemovalPresentation {
    static let confirmationMessage =
        "This removes only the saved My Macs record; it does not unlink a running Mac or clear that Mac’s local credentials. Contribution history remains on your account, and the Mac may appear here again if it reconnects."
}
