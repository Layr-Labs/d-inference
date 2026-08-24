import AppKit
import SwiftUI

struct LocalAPIView: View {
    let store: LocalAPIStore
    let onOpenChat: () -> Void
    let onOpenModels: () -> Void
    let onOpenDiagnostics: () -> Void

    var body: some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "On this Mac",
                title: "Your Mac is an endpoint.",
                subtitle: "Connect any OpenAI-compatible client to models available on this Mac. Darkbloom does not route local requests through its coordinator."
            ) {
                if let item = store.lastCopiedItem {
                    Label(item.confirmation, systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProductPalette.positive)
                        .transition(.opacity)
                        .accessibilityLabel(item.confirmation)
                }
            }

            stateContent
                .padding(.top, 24)
        }
        .navigationTitle("Local API")
        // Live stores poll ~/.darkbloom/local.json + probe the endpoint while
        // this surface is visible; fixture stores no-op so previews stay frozen.
        .task { store.startMonitoring() }
        .task(id: store.lastCopiedItem) {
            guard store.lastCopiedItem != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                store.clearCopyConfirmation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.hideAPIKey()
        }
        .onDisappear {
            store.stopMonitoring()
            store.hideAPIKey()
            store.clearCopyConfirmation()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.state {
        case .running(let endpoint):
            endpointContent(endpoint)

        case .starting(let message):
            LocalAPIStateView(
                kind: .starting,
                message: message,
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .stopped(let message):
            LocalAPIStateView(
                kind: .stopped,
                message: message,
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

            LocalAPIStartCommandsView(
                store: store,
                copiedItem: store.lastCopiedItem,
                onCopy: copy
            )

            footerActions

        case .unavailable(let message):
            LocalAPIStateView(
                kind: .unavailable,
                message: message,
                isLive: store.isLive,
                onRetry: store.retryPreviewDiscovery,
                onOpenDiagnostics: onOpenDiagnostics
            )

            troubleshootingNote
                .padding(.top, 18)
        }
    }

    @ViewBuilder
    private func endpointContent(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        switch endpoint.health {
        case .checking:
            LocalAPIStateView(
                kind: .starting,
                message: "A provider process was discovered. Darkbloom is checking whether its HTTP endpoint responds before showing connection details.",
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .unreachable:
            LocalAPIStateView(
                kind: .unavailable,
                message: "The provider process is running, but the local API did not answer its health check. Connection details stay hidden until it responds.",
                isLive: store.isLive,
                onRetry: store.retryPreviewHealth,
                onOpenDiagnostics: onOpenDiagnostics
            )

            troubleshootingNote
                .padding(.top, 18)

        case .reachable:
            reachableContent(endpoint)
        }
    }

    @ViewBuilder
    private func reachableContent(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        LocalAPIConnectionSurface(
            endpoint: endpoint,
            isLive: store.isLive,
            isAPIKeyRevealed: store.isAPIKeyRevealed,
            copiedItem: store.lastCopiedItem,
            onRevealAPIKey: store.setAPIKeyRevealed,
            onCopy: copy,
            onOpenModels: onOpenModels
        )

        if endpoint.bindScope != .thisMac {
            networkExposureWarning(endpoint)
                .padding(.top, 14)
        }

        LocalAPICodeExampleView(
            store: store,
            endpoint: endpoint,
            onCopy: copy,
            onOpenModels: onOpenModels,
            onRetryCatalog: store.retryPreviewModelCatalog,
            onOpenDiagnostics: onOpenDiagnostics
        )

        LocalAPIExplanationView(endpoint: endpoint)

        footerActions
    }

    private func networkExposureWarning(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.isLive
                    ? "This endpoint is exposed beyond this Mac"
                    : "This sample endpoint is exposed beyond this Mac")
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalAPIPresentation.accessDetail(endpoint.bindScope))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if endpoint.bindScope == .allInterfaces {
                    Text("The copied base URL intentionally uses loopback for this Mac. Other devices need this Mac’s trusted network address and the API key.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var troubleshootingNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductSectionHeader("What to check")

            Text("Confirm the configured port is free, ~/.darkbloom is writable by your account, and the provider process is still running. Discovery records prove process liveness—not HTTP health—so Darkbloom checks the endpoint separately.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Local requests stay on the path you choose.")
                    .font(.system(size: 12, weight: .semibold))
                Text(store.isLive
                    ? "Use Chat in Darkbloom, or connect your own client with the endpoint above."
                    : "Use Chat for the sample in-app experience, or connect your own client with the endpoint above.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(store.isLive ? "Open Chat" : "Preview in Chat", action: onOpenChat)
            Button("Open Models", action: onOpenModels)
        }
        .padding(.top, 18)
    }

    private func copy(_ item: LocalAPICopyItem) {
        guard let value = store.text(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.16)) {
            store.markCopied(item)
        }
        AccessibilityNotification.Announcement(item.confirmation).post()
    }
}
