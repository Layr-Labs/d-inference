import SwiftUI

struct MyMacsView: View {
    let store: MyMacsStore
    let onOpenContributions: () -> Void

    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var statusFilter = MyMacsStatusFilter.all
    @State private var attentionFilter = MyMacsAttentionFilter.all
    @State private var showsCompactDetail = false
    @State private var showsLinkAnotherMac = false
    @State private var removalRequest: MyMacRemovalRequest?

    // Keep the shell interface stable. The account API no longer exposes a
    // serial, so local hardware identity cannot safely identify a fleet row.
    // Local hardware/activity/model actions remain in their own destinations.
    init(
        store: MyMacsStore,
        currentMachine _: MachineIdentity,
        onOpenContributions: @escaping () -> Void,
        onOpenHardware _: @escaping () -> Void,
        onOpenActivity _: @escaping () -> Void,
        onOpenModels _: @escaping () -> Void,
        onRunSystemCheck _: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenContributions = onOpenContributions
        _selectedID = State(initialValue: MyMacsPresentation.defaultSelection(in: store.macs))
    }

    private var filteredMacs: [MyMac] {
        MyMacsPresentation.filtered(
            store.macs, searchText: searchText, status: statusFilter, attention: attentionFilter
        )
    }

    private var selectedMac: MyMac? {
        filteredMacs.first { $0.id == selectedID }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                MyMacsPageHeader(
                    lastUpdated: store.snapshot?.asOf,
                    isPreview: store.mode == .fixture,
                    isRefreshing: store.isRefreshing,
                    canRefresh: store.canRefresh,
                    canLink: store.snapshot != nil,
                    onRefresh: store.refresh,
                    onLink: { showsLinkAnotherMac = true }
                )
                stateContent(isCompact: geometry.size.width < 800)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(ProductPalette.pageBackground)
        .onChange(of: filteredMacs.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: store.actionRevision) { _, _ in removalRequest = nil }
        .onChange(of: store.snapshot == nil) { _, isAbsent in
            if isAbsent {
                removalRequest = nil
                showsCompactDetail = false
                selectedID = nil
                searchText = ""
                statusFilter = .all
                attentionFilter = .all
            }
        }
        .task { store.start() }
        .sheet(isPresented: $showsLinkAnotherMac) { LinkAnotherMacSheet() }
        .confirmationDialog(
            MyMacRemovalPresentation.confirmationTitle(macTitle: removalRequest?.title),
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(MyMacRemovalPresentation.actionTitle, role: .destructive, action: confirmRemoval)
            Button("Cancel", role: .cancel) { removalRequest = nil }
        } message: {
            Text(MyMacRemovalPresentation.confirmationMessage)
        }
        .navigationTitle("My Macs")
    }

    @ViewBuilder
    private func stateContent(isCompact: Bool) -> some View {
        switch store.availability {
        case .loading:
            state(.loading)
        case .signedOut:
            ScrollView {
                MyMacsStateView(
                    kind: .signedOut,
                    message: store.signInErrorMessage,
                    onRetry: nil,
                    actionTitle: store.isSigningIn ? "Signing In…" : "Sign In",
                    actionSystemImage: "person.crop.circle",
                    onAction: store.signIn,
                    actionDisabled: store.isSigningIn
                )
            }
        case let .unavailable(message):
            state(.unavailable, message: message, onRetry: store.retry)
        case let .ready(_, summary):
            loadedContent(isCompact: isCompact, summary: summary, staleMessage: nil)
        case let .staleRetained(_, _, message, summary):
            loadedContent(isCompact: isCompact, summary: summary, staleMessage: message)
        }
    }

    private func loadedContent(
        isCompact: Bool,
        summary: MyMacsSummaryAvailability,
        staleMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let staleMessage {
                MyMacsBanner(
                    title: "Showing an earlier snapshot",
                    detail: staleMessage,
                    systemImage: "clock.arrow.circlepath"
                )
            }
            if let removalError = store.removalErrorMessage {
                MyMacsBanner(
                    title: "Saved record was not removed",
                    detail: removalError,
                    systemImage: "exclamationmark.circle"
                )
            }
            if store.isEmpty {
                ScrollView {
                    MyMacsStateView(
                        kind: .empty, message: nil, onRetry: nil,
                        actionTitle: "Link Another Mac",
                        actionSystemImage: "plus.rectangle.on.rectangle",
                        onAction: { showsLinkAnotherMac = true }
                    )
                }
            } else if isCompact {
                if showsCompactDetail, selectedMac != nil {
                    Button("All Macs", systemImage: "chevron.left") {
                        showsCompactDetail = false
                    }
                    detailPane
                } else {
                    inventoryList(isCompact: true)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    inventoryList(isCompact: false)
                        .frame(width: 280)
                    Divider()
                    detailPane
                }
            }
            MyMacsAccountSummaryView(
                summary: store.snapshot?.accountSummary,
                availability: summary,
                onOpenContributions: onOpenContributions
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inventoryList(isCompact: Bool) -> some View {
        MyMacsInventoryList(
            macs: filteredMacs, fleet: store.macs, isCompact: isCompact,
            selection: $selectedID, searchText: $searchText,
            statusFilter: $statusFilter, attentionFilter: $attentionFilter,
            onOpenMac: { id in
                selectedID = id
                showsCompactDetail = true
            }
        )
    }

    private var detailPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let mac = selectedMac {
                        MyMacDetailView(
                            mac: mac, fleet: store.macs,
                            isRemoving: store.removingMacID == mac.id,
                            removalDisabled: store.isRefreshing || store.removingMacID != nil,
                            onRequestRemoval: { requestRemoval(of: mac) }
                        )
                        .id(mac.id)
                    } else {
                        ContentUnavailableView {
                            Label("Select a Mac", systemImage: "cursorarrow.click.2")
                        } description: {
                            Text(filteredMacs.isEmpty
                                ? "Clear the filters to see your linked Macs."
                                : "Choose a Mac to read its latest report.")
                        }
                        .frame(minHeight: 240)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.trailing, 8)
                .padding(.bottom, 16)
            }
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .accessibilityLabel("Selected Mac report")
        }
    }

    private func state(
        _ kind: MyMacsStateView.Kind,
        message: String? = nil,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        ScrollView { MyMacsStateView(kind: kind, message: message, onRetry: onRetry) }
    }

    private func reconcileSelection() {
        selectedID = MyMacsPresentation.reconciledSelection(selectedID, in: filteredMacs)
        if selectedID == nil { showsCompactDetail = false }
    }

    private func requestRemoval(of mac: MyMac) {
        guard mac.canRemove, !store.isRefreshing, store.removingMacID == nil else { return }
        removalRequest = MyMacRemovalRequest(
            macID: mac.id,
            title: MyMacsPresentation.title(for: mac, in: store.macs),
            revision: store.actionRevision
        )
    }

    private func confirmRemoval() {
        guard let request = removalRequest else { return }
        removalRequest = nil
        Task {
            if await store.removeMac(id: request.macID, expectedRevision: request.revision) {
                reconcileSelection()
                AccessibilityNotification.Announcement(MyMacRemovalPresentation.successAnnouncement).post()
            }
        }
    }
}

private struct MyMacRemovalRequest {
    let macID: String
    let title: String
    let revision: UInt64
}

enum MyMacRemovalPresentation {
    static let actionTitle = "Remove Saved Record"
    static let confirmationMessage =
        "This removes only the saved My Macs record; it does not unlink a running Mac or clear that Mac’s local credentials. Contribution history remains on your account, and the Mac may appear here again if it reconnects."
    static let successAnnouncement = "Saved Mac record removed"

    static func confirmationTitle(macTitle: String?) -> String {
        macTitle.map { "Remove \($0) from My Macs?" }
            ?? "Remove this saved record from My Macs?"
    }
}
