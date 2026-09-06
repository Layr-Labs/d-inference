import Testing
@testable import DarkbloomApp

@Suite("Models handoff into Local API")
@MainActor
struct LocalAPIModelSelectionTests {
    @Test("Use locally selection wins over the first row and never starts a process")
    func selectedModelHandoff() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        let first = localAPIInstalledModel(id: "local/first")
        let chosen = localAPIInstalledModel(id: "local/chosen")
        store.syncLocalModelSelection(preferredID: chosen.id, models: [first, chosen])
        #expect(store.selectedLocalModelID == chosen.id)
        #expect(store.localStart.state == .idle)
        #expect(await cli.invocations.isEmpty)
        #expect(store.text(for: .command(.directOnly)) == "darkbloom start --local --model 'local/chosen' --no-replace")
    }

    @Test("Inventory arrival applies the parent selection; removal or lost eligibility clears it")
    func inventoryChanges() {
        let store = LocalAPIStore(fixture: .stopped)
        var chosen = localAPIInstalledModel(id: "local/chosen")
        let other = localAPIInstalledModel(id: "local/other")
        store.syncLocalModelSelection(preferredID: chosen.id, models: [])
        #expect(store.selectedLocalModelID == nil)
        store.syncLocalModelSelection(preferredID: chosen.id, models: [other, chosen])
        #expect(store.selectedLocalModelID == chosen.id)
        chosen.installation = .notInstalled
        store.syncLocalModelSelection(preferredID: chosen.id, models: [other, chosen])
        #expect(store.selectedLocalModelID == nil)
        chosen.installation = .installed
        chosen.fit = .runtimeIneligible(reason: "Runtime cannot serve this model")
        store.syncLocalModelSelection(preferredID: chosen.id, models: [other, chosen])
        #expect(store.selectedLocalModelID == nil)
        chosen.fit = .tooLarge(requiredMemoryGB: 64, availableMemoryGB: 16)
        store.syncLocalModelSelection(preferredID: chosen.id, models: [other, chosen])
        #expect(store.selectedLocalModelID == nil)
        #expect(store.localStart.state == .idle)
    }

    @Test("A parent selection change replaces the old choice without changing runtime state")
    func changedParentSelection() {
        let store = LocalAPIStore(fixture: .stopped)
        let first = localAPIInstalledModel(id: "local/first")
        let second = localAPIInstalledModel(id: "local/second")
        store.syncLocalModelSelection(preferredID: first.id, models: [first, second])
        store.syncLocalModelSelection(preferredID: second.id, models: [first, second])
        #expect(store.selectedLocalModelID == second.id)
        #expect(store.localStart.state == .idle)
    }

    @Test("Without a parent choice retain a valid local choice and skip ineligible defaults")
    func defaultSelection() {
        let store = LocalAPIStore(fixture: .stopped)
        var unsupported = localAPIInstalledModel(id: "local/unsupported")
        unsupported.fit = .runtimeUnknown(reason: "Refresh runtime eligibility")
        let available = localAPIInstalledModel(id: "local/available")
        store.syncLocalModelSelection(preferredID: nil, models: [unsupported, available])
        #expect(store.selectedLocalModelID == available.id)
        store.syncLocalModelSelection(preferredID: nil, models: [available, unsupported])
        #expect(store.selectedLocalModelID == available.id)
    }
}
