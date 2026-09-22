import ConnectCore
import SwiftUI

struct PrivacyView: View {
    @Bindable var store: ConnectStore
    var body: some View {
        SectionTitle(title: "A clear privacy boundary", subtitle: "The companion handles setup and status. It never receives customer prompts or inference keys.")
        HStack(spacing: 12) {
            BoundaryNode(symbol: "network", title: "Coordinator", caption: "Authorizes requests")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            BoundaryNode(symbol: "lock.shield", title: "Encrypted hop", caption: "Bound to the worker")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            BoundaryNode(symbol: "cpu", title: "Signed worker", caption: "Private inference")
        }.frame(maxWidth: .infinity).padding(.vertical, 18)
        Divider()
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let ready = store.snapshot?.evidence.isCurrent(at: timeline.date.timeIntervalSince1970) == true
            VStack(alignment: .leading, spacing: 0) {
                CheckRow(title: "Worker identity", detail: "Apple Developer ID, Darkbloom identity, hardened runtime, and unsafe entitlement checks.", ready: store.snapshot?.worker != nil)
                CheckRow(title: "Live App Attest authorization", detail: ready ? "Fresh local status agrees with the coordinator for this connection and Secure Enclave key." : "Unconfirmed or expired. The coordinator's serving checks remain authoritative.", ready: ready)
                CheckRow(title: "Ollama stays outside the request path", detail: "Only GET /api/tags and GET /api/ps are used. No chat, generation, upload, or mutation endpoint exists in the companion.", ready: true)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            Text("What this POC proves").font(.headline)
            Text("Existing Ollama users can discover their setup and reach the official provider flow without giving Ollama access to network prompts. The provider's existing encryption, model checks, App Attest policy, and revocation remain in force.")
                .font(.callout).foregroundStyle(.secondary)
            Text("It does not attest Ollama, reuse its running engine, or certify all possible attacks. The coordinator and signed worker process plaintext in memory; inference does not run inside the Secure Enclave.")
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Button("View security model") { store.open("https://github.com/Layr-Labs/d-inference/blob/master/docs/architecture/security/encryption.md") }
            Button("Run provider diagnostics") { Task { await store.handoff(.doctor) } }.disabled(store.snapshot?.worker == nil)
        }.controlSize(.large)
    }
}

private struct BoundaryNode: View {
    let symbol: String
    let title: String
    let caption: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.purple)
            Text(title).font(.callout.weight(.medium))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
