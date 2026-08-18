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
            Button("Simulate Resolution") { resolveLaunchedFix() }
            Button("Cancel", role: .cancel) { dismissFixSimulation() }
        } message: {
            Text("Preview only: Darkbloom will mark this check resolved here. No macOS settings, provider files, or model weights will change.")
        }
        .onDisappear(perform: cancelScan)
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
        case .unavailable:
            Button("Try Again", systemImage: "arrow.clockwise") {
                runScan()
            }
        }
    }

    private func runScan() {
        scanTask?.cancel()
        store.startScan()
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
        guard let launchedFix else { return }
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
