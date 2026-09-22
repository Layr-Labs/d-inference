import ConnectCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: ConnectStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "asterisk").font(.system(size: 26, weight: .medium)).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("darkbloom").font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text("CONNECT").font(.system(size: 9, weight: .semibold)).tracking(2.8).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 22).padding(.top, 35).padding(.bottom, 38)
                VStack(spacing: 5) {
                    ForEach(ConnectStore.Page.allCases, id: \.self) { page in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { store.page = page }
                        } label: {
                            Label(page.rawValue, systemImage: icon(page))
                                .font(.system(size: 13, weight: store.page == page ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .background(store.page == page ? Color.purple.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(store.page == page ? Color.purple : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("This Mac", systemImage: "laptopcomputer").font(.headline)
                    Text("\(MacHardware.chip) · \(MacHardware.memoryGB) GB").font(.caption).foregroundStyle(.secondary)
                    Text("Ollama companion · POC").font(.caption2).foregroundStyle(.tertiary)
                }.padding(22)
            }.frame(width: 220).background(.quaternary.opacity(0.22))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(store.page.rawValue).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if store.refreshing { ProgressView().controlSize(.small) }
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh connection (⌘R)")
                    Text("LIVE").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                }.padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch store.page {
                        case .connection: ConnectionView(store: store)
                        case .library: LibraryView(store: store)
                        case .privacy: PrivacyView(store: store)
                        }
                    }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = store.message {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(message).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(16).background(.quaternary.opacity(0.5))
                }
                Divider()
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Ollama discovery only. Private requests stay in the Darkbloom worker.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
        }.background(.background)
        .alert("Start contributing with this model?", isPresented: Binding(
            get: { store.pendingAction != nil }, set: { if !$0 { store.pendingAction = nil } }
        )) {
            Button("Continue in Terminal") {
                if let action = store.pendingAction { Task { await store.handoff(action) } }
                store.pendingAction = nil
            }
            Button("Cancel", role: .cancel) { store.pendingAction = nil }
        } message: {
            Text("The signed provider will start a background network service. It uses a separate verified model copy, memory, and power. Starting agrees to Darkbloom's terms. The coordinator must approve this connection before serving.")
        }
    }

    private func icon(_ page: ConnectStore.Page) -> String {
        switch page { case .connection: "point.3.connected.trianglepath.dotted"; case .library: "square.stack.3d.up"; case .privacy: "lock.shield" }
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CheckRow: View {
    let title: String
    let detail: String
    let ready: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 19)).foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 10)
    }
}
