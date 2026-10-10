import Foundation
import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// What each Mac holds while a session of the saved Plan is up: read
    /// through a stand-in for the plan tool installed beside the worker, and
    /// shown on the screen and in the plain output with this Mac's own size.
    static func holdings() throws {
        let fixture = try installedFixture("holdings")
        let gib = 1_073_741_824, page = Int(getpagesize())
        let part = ClusterModelLayout.Part(storedBytes: gib / 4, loadedBytes: gib / 4, largestTensorBytes: gib / 8, tensorCount: 10)
        func layout(artifact: String) -> ClusterModelLayout {
            .init(runtimeModelID: fixture.capability.runtimeModelID, artifactSHA256: artifact,
                configurationSHA256: fixture.capability.configurationSHA256,
                layers: (0..<32).map { .init(index: $0, kind: "block", weights: part, stateFixedBytes: 1_000_000, stateBytesPerToken: 1024, cost: 1) },
                ingress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 1),
                egress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 2),
                excluded: .init(), admittedCuts: [4], structuralCuts: [4], generationModes: [.pipeline], prefillSchedules: [.serial],
                maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, boundaryBytesPerToken: 8192,
                requestChargeEveryRankBytes: 0)
        }
        let real = layout(artifact: fixture.capability.artifactSHA256)
        let computed = try ClusterInstalledHoldings.compute(configuration: fixture.configuration, capability: fixture.capability,
            layout: real, localPhysicalMemoryBytes: 256 * gib, pageSizeBytes: page)
        // Rank 0 holds the ingress and four layers, rank 1 the other 28 and the egress, each tensor rounded to a page.
        expectEqual(computed.ranks.map(\.weightsBytes), [gib / 2 + 4 * (gib / 4) + 41 * page, 28 * (gib / 4) + gib / 2 + 282 * page],
            "each rank's bytes are its layers' weights with the ingress or the egress")
        expectEqual(computed.line, "While the session is up: peer-0 (this Mac) holds layers 0 to 3: 1.50 GiB of weights of its 256.00 GiB; "
            + "peer-1 holds layers 4 to 31: 7.50 GiB of weights.", "the line names each Mac's layers and bytes, and this Mac's size")
        do {
            _ = try ClusterInstalledHoldings.compute(configuration: fixture.configuration, capability: fixture.capability,
                layout: layout(artifact: String(repeating: "0", count: 64)), localPhysicalMemoryBytes: nil, pageSizeBytes: page)
            expect(false, "a layout of another artifact was accepted")
        } catch { expect(String(describing: error).contains("describe different models"), "another artifact's layout is refused: \(error)") }

        // Without the plan tool beside the worker the view says so and shows no figure.
        let tool = probe.deletingLastPathComponent().appendingPathComponent(ClusterInstalledHoldings.toolName)
        try? FileManager.default.removeItem(at: tool)
        func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }
        let absent = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline())
        expect(absent.installed?.holdings?.holdings == nil
            && absent.installed?.holdings?.detail?.contains("is not installed beside this Mac's worker") == true,
            "a missing plan tool is said, not guessed around: \(String(describing: absent.installed?.holdings))")

        // The stand-in prints the layout for the saved model directory, as the installed tool does.
        let layoutFile = scratch.appendingPathComponent("holdings-layout.json")
        try real.encoded().write(to: layoutFile)
        let local = fixture.configuration.peers[fixture.configuration.localRank]
        let script = "#!/bin/sh\n[ \"$1\" = layout ] && [ \"$2\" = --model-dir ] && [ \"$3\" = \"\(local.modelDirectory)\" ] && [ \"$4\" = --json ] && exec /bin/cat \"\(layoutFile.path)\"\nexit 9\n"
        try Data(script.utf8).write(to: tool)
        defer { try? FileManager.default.removeItem(at: tool) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let read = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline())
        let held = read.installed?.holdings?.holdings
        expect(held?.ranks.map(\.weightsBytes) == computed.ranks.map(\.weightsBytes) && held?.ranks.map(\.local) == [true, false]
            && held?.ranks.first?.physicalMemoryBytes == Int(clamping: ProcessInfo.processInfo.physicalMemory),
            "the saved setup's holdings are read through the tool beside the worker: \(String(describing: read.installed?.holdings))")

        // A tool another user could have written is not run.
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: tool.path)
        let loose = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline())
        expect(loose.installed?.holdings?.holdings == nil && loose.installed?.holdings?.detail?.contains("not this user's own executable file") == true,
            "a plan tool others can write is not run")

        // On the screen and in the plain output, under the ranks, from its own wired row.
        var shown = ConsoleFixtures.savedSetup()
        shown = .init(state: .loaded, error: nil, configurationSHA256: shown.configurationSHA256, pairing: shown.pairing, model: shown.model,
            installed: .init(workerBinary: .verified, hasProgressGuard: true, acceptsStartupDeadline: true, manifest: .verified,
                artifactFiles: ConsoleFixtures.installed.artifactFiles, holdings: .init(holdings: computed, detail: nil)))
        let snapshot = ConsoleFixtures.snapshot(saved: shown)
        let lines = ClusterConsoleContent.model(snapshot, status: snapshot.diagnostics)
        let line = lines.first { $0.source == .wired("model.holdings") }
        expect(line?.text == computed.line, "the model section shows the holdings line from its own row")
        expect(lines.firstIndex { $0.source == .wired("model.holdings") }.map { $0 > (lines.lastIndex { $0.source == .wired("model.ranks") } ?? .max) } == true,
            "it follows the ranks' layers")
        expect(snapshot.plainLines.contains { $0.contains("peer-1 holds layers 4 to 31: 7.50 GiB of weights.") }, "the plain output carries it too")
        let unread = ClusterConsoleContent.model(ConsoleFixtures.snapshot(saved: .init(state: .loaded, error: nil,
            configurationSHA256: shown.configurationSHA256, pairing: shown.pairing, model: shown.model,
            installed: .init(workerBinary: .verified, hasProgressGuard: true, acceptsStartupDeadline: true, manifest: .verified,
                artifactFiles: nil, holdings: .init(holdings: nil, detail: "the tool is absent")))), status: snapshot.diagnostics)
        expect(unread.contains { $0.text == "What each Mac holds was not read: the tool is absent" && $0.style == .dim }, "an unread figure is said to be unread")
        expect(!ClusterConsoleContent.model(ConsoleFixtures.snapshot(saved: .init(state: .loaded, error: nil,
            configurationSHA256: shown.configurationSHA256, pairing: shown.pairing, model: shown.model,
            installed: .init(workerBinary: .verified, hasProgressGuard: true, acceptsStartupDeadline: true, manifest: .verified,
                artifactFiles: nil))), status: snapshot.diagnostics)
            .contains { $0.source == .wired("model.holdings") }, "nothing is shown where nothing was observed")
        let fixtureScreen = ClusterConsoleContent.model(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()), status: snapshot.diagnostics)
        expect(fixtureScreen.contains { $0.text.contains("peer-0 (this Mac) holds layers 0 to 3: 1.50 GiB of weights of its 256.00 GiB; peer-1 holds layers 4 to 31: 4.19 GiB of weights.") },
            "a small share is shown beside the size of the Mac that holds it")
        expect(ClusterConsoleWiring.wired.contains("model.holdings")
            && ClusterConsoleWiring.unavailable.contains { $0.id == "model.plan" && $0.exists && $0.reason.contains("darkbloom cluster plan") },
            "the holdings row is wired and the planning step is listed as a command the screen has no key for")
    }
}
