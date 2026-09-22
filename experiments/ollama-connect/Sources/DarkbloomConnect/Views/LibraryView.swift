import ConnectCore
import SwiftUI

struct LibraryView: View {
    @Bindable var store: ConnectStore
    var body: some View {
        SectionTitle(title: "Your model library", subtitle: "Discovery is read-only. Local model names never grant permission to serve network requests.")
        HStack { Text("IN OLLAMA").font(.caption.weight(.semibold)).tracking(1.4); Spacer(); Text(store.snapshot?.ollama.source ?? "Discovering…").font(.caption).foregroundStyle(.secondary) }
        if let models = store.snapshot?.ollama.models, !models.isEmpty {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    HStack(spacing: 14) {
                        Image(systemName: "cube.transparent").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.name).font(.headline).lineLimit(1).textSelection(.enabled)
                            Text("\(model.details?.format?.uppercased() ?? "Local model") · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.snapshot?.ollama.runningNames.contains(model.name) == true ? "Loaded locally" : "On disk")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 18)
                    Divider()
                }
            }
        } else {
            ContentUnavailableView("No Ollama models discovered", systemImage: "cube", description: Text("Start Ollama with a downloaded model, then refresh."))
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Separate work. Shared hardware.").font(.title3.weight(.medium))
            Text("An Ollama tag does not prove which weights or code are running. Network work uses an approved Darkbloom artifact in its signed worker. This POC does not import or convert Ollama files.")
                .foregroundStyle(.secondary)
            Text("Running both engines can load two copies into memory. Review available memory before starting the network worker.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Button("Choose a network model") { withAnimation { store.page = .connection } }.controlSize(.large)
    }
}
