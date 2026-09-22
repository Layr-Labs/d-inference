import AppKit
import ConnectCore
import Foundation
import Observation

@MainActor @Observable
final class ConnectStore {
    enum Page: String, CaseIterable { case connection = "Connection", library = "Model library", privacy = "Privacy & verification" }
    var page: Page = .connection
    var snapshot: ConnectSnapshot?
    var selectedID = ""
    var refreshing = false
    var handoffBusy = false
    var message: String?
    var pendingAction: SetupAction?
    private var monitoring = false

    var selectedModel: NetworkModel? { snapshot?.catalog.first { $0.id == selectedID } }
    var hasRunningWorker: Bool {
        guard let identity = snapshot?.local?.process_identity else { return false }
        return KernelIdentity.read(identity.pid) == identity
    }
    var limitation: String? {
        guard let model = selectedModel else { return "Select a network model" }
        return CatalogPolicy.limitation(model, memoryGB: MacHardware.memoryGB, chip: MacHardware.chip)
    }

    func monitor() async {
        guard !monitoring else { return }
        monitoring = true
        defer { monitoring = false }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await ConnectSnapshot.capture()
        snapshot = result
        if !result.catalog.contains(where: { $0.id == selectedID }) {
            // Selection is a UI preference only, not an artifact mapping.
            selectedID = result.catalog.first(where: { $0.display_name == "Qwen 3.8 27B" })?.id ?? result.catalog.first?.id ?? ""
        }
    }

    func handoff(_ action: SetupAction) async {
        guard !handoffBusy else { return }
        handoffBusy = true
        defer { handoffBusy = false }
        do {
            let url = try await SetupHandoff.prepare(action)
            guard NSWorkspace.shared.open(url) else { throw ConnectError.commandFailed }
            message = "Continue in Terminal. The signed provider handles this step; refresh here when it finishes."
        } catch {
            message = (error as? ConnectError)?.rawValue ?? "Setup could not continue. Refresh and try again."
        }
    }

    func open(_ url: String) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
}
