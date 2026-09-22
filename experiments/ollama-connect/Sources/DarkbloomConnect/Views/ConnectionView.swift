import ConnectCore
import SwiftUI

struct ConnectionView: View {
    @Bindable var store: ConnectStore
    var body: some View {
        SectionTitle(title: "Share this Mac", subtitle: "Connect your Ollama setup to Darkbloom. Keep personal inference separate from network work.")
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let confirmed = store.snapshot?.evidence.isCurrent(at: timeline.date.timeIntervalSince1970) == true
            HStack(spacing: 16) {
                Image(systemName: confirmed ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 35, weight: .light)).foregroundStyle(confirmed ? Color.green : Color.purple)
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmed ? "Your worker is authorized" : "Set up your private worker").font(.title3.weight(.semibold))
                    Text(confirmed ? "Confirmed by the coordinator. Permission expires automatically." : "A signed worker handles customer requests. Ollama stays yours.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        }
        VStack(alignment: .leading, spacing: 0) {
            CheckRow(title: "Ollama library", detail: ollamaDetail, ready: !(store.snapshot?.ollama.models.isEmpty ?? true))
            Divider().padding(.leading, 34)
            HStack {
                CheckRow(title: "Signed Darkbloom provider", detail: store.snapshot?.worker == nil ? "Install the official provider to continue." : "Developer ID and hardened runtime checked on this Mac.", ready: store.snapshot?.worker != nil)
                if store.snapshot?.worker == nil {
                    Button("Get provider") { store.open("https://darkbloom.dev/earn") }.controlSize(.small)
                }
            }
            Divider().padding(.leading, 34)
            HStack {
                CheckRow(title: store.hasRunningWorker ? "Existing worker" : "Link your account", detail: store.hasRunningWorker ? "This companion leaves the running service in place." : "Link your account in the signed provider; App Attest approval follows on connection.", ready: store.snapshot?.processVerified == true && store.hasRunningWorker)
                if !store.hasRunningWorker {
                    Button("Link account") { Task { await store.handoff(.login) } }
                        .disabled(store.snapshot?.worker == nil || store.handoffBusy).controlSize(.small)
                }
            }
        }
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Network model").font(.headline); Spacer(); Text("From the live catalog").font(.caption).foregroundStyle(.secondary) }
            if store.snapshot?.catalogAvailable == true {
                Picker("Network model", selection: $store.selectedID) {
                    ForEach(store.snapshot?.catalog ?? []) { model in Text(model.display_name).tag(model.id) }
                }.labelsHidden().controlSize(.large).frame(maxWidth: 420, alignment: .leading)
                if let model = store.selectedModel {
                    HStack(spacing: 18) {
                        Label(String(format: "%.1f GB download", model.size_gb), systemImage: "arrow.down.circle")
                        Text("\(model.min_ram_gb ?? 0) GB minimum memory")
                    }.font(.caption).foregroundStyle(.secondary)
                    if let limit = store.limitation {
                        Label(limit, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                    }
                    Text("Darkbloom downloads and verifies its network artifact separately. Existing Ollama files stay untouched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !store.hasRunningWorker {
                        Text("Prepare the model first, then start contributing. Both steps continue in Terminal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(store.refreshing ? "Loading the current model catalog…" : "Catalog unavailable. Setup actions remain disabled until it refreshes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 12) {
            if store.hasRunningWorker {
                Button("View my providers") { store.open("https://console.darkbloom.dev/providers") }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Run provider diagnostics") { Task { await store.handoff(.doctor) } }.controlSize(.large)
            } else {
                Button("Prepare model") { Task { await store.handoff(.download(store.selectedID)) } }
                    .controlSize(.large).disabled(!canStart)
                Button("Start contributing") { store.pendingAction = .start(store.selectedID) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canStart)
            }
            Spacer()
            Button("How privacy works") { withAnimation(.easeInOut(duration: 0.2)) { store.page = .privacy } }.buttonStyle(.plain).foregroundStyle(.purple)
        }
    }
    private var canStart: Bool {
        store.snapshot?.worker != nil && store.snapshot?.catalogAvailable == true && store.selectedModel != nil && store.limitation == nil
            && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && !store.handoffBusy
    }
    private var ollamaDetail: String {
        guard let snapshot = store.snapshot else { return "Looking for your local setup…" }
        let count = snapshot.ollama.models.count
        return count == 0 ? "Open Ollama, then refresh. You can also browse the network catalog." : "\(count) model\(count == 1 ? "" : "s") discovered · \(snapshot.ollama.source)"
    }
}
