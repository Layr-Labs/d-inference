import SwiftUI

struct DiagnosticsView: View {
    let store: DiagnosticsStore

    @Environment(\.dismiss) private var dismiss
    @State private var launchedFix: DiagnosticFix?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DiagnosticsVerdictHeader(
                    report: store.report,
                    runState: store.runState
                )
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !store.isScanning, !store.report.prioritizedFixes.isEmpty {
                            DiagnosticFixesSection(
                                fixes: store.report.prioritizedFixes,
                                onOpen: open
                            )
                        }

                        DiagnosticChecksSection(report: store.report)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(26)
                    .frame(maxWidth: .infinity)
                }
                .background(ProductPalette.pageBackground)
            }
            .navigationTitle("System Check")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    runButton
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .alert(
            launchedFix?.title ?? "Next step",
            isPresented: Binding(
                get: { launchedFix != nil },
                set: { if !$0 { dismissFixSimulation() } }
            )
        ) {
            if store.isLive {
                Button("OK") { dismissFixSimulation() }
            } else {
                Button("Simulate Resolution") { resolveLaunchedFix() }
                Button("Cancel", role: .cancel) { dismissFixSimulation() }
            }
        } message: {
            if store.isLive {
                Text("\(launchedFix?.detail ?? "")\n\nFollow this guidance, then use Run Again to verify the real state.")
            } else {
                Text("Preview only: Darkbloom will mark this check resolved here. No macOS settings, provider files, or model weights will change.")
            }
        }
        .onDisappear(perform: cancelScan)
        .onAppear(perform: startOnFirstOpen)
    }

    @ViewBuilder
    private var runButton: some View {
        switch store.runState {
        case .running:
            Button("Checking…") {}
                .disabled(true)
        case .ready:
            Button("Run Again", systemImage: "arrow.clockwise") {
                runScan()
            }
        case .notStarted:
            Button("Run System Check", systemImage: "stethoscope") {
                runScan()
            }
        case .unavailable:
            Button("Try Again", systemImage: "arrow.clockwise") {
                runScan()
            }
        }
    }

    /// Live stores auto-run the first real scan when the sheet opens;
    /// fixture stores boot `.ready`, so this no-ops for previews.
    private func startOnFirstOpen() {
        store.beginScanIfIdle()
    }

    private func runScan() {
        scanTask?.cancel()
        store.startScan()
        // Live stores own their scan task end-to-end; only fixture stores
        // need the simulated progress timer below.
        guard !store.isLive else { return }
        scanTask = Task { @MainActor in
            while !Task.isCancelled, store.isScanning {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
                store.advanceScan()
            }
        }
    }

    private func open(_ fix: DiagnosticFix) {
        guard store.triggerFix(id: fix.id) != nil else { return }
        launchedFix = fix
    }

    private func resolveLaunchedFix() {
        // Against a LIVE report nothing is "simulated" — only the next real
        // scan can verify a fix.
        guard !store.isLive, let launchedFix else { return }
        _ = store.simulateResolution(fixID: launchedFix.id)
        dismissFixSimulation()
    }

    private func dismissFixSimulation() {
        launchedFix = nil
        store.clearSelectedFix()
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        store.cancelScan()
    }
}
