import SwiftUI

struct PreviewPayoutSheet: View {
    let store: ContributionsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var amountText: String
    @State private var entryError: String?
    @State private var completionTask: Task<Void, Never>?
    @FocusState private var amountIsFocused: Bool

    init(store: ContributionsStore) {
        self.store = store
        _amountText = State(
            initialValue: store.snapshot.map {
                ContributionsPresentation.editableDollars($0.withdrawableBalance)
            } ?? ""
        )
        _entryError = State(initialValue: nil)
        _completionTask = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewNotice

            Group {
                if let snapshot = store.snapshot {
                    switch snapshot.payoutReadiness {
                    case .setupRequired:
                        setupRequired
                    case .ready:
                        payoutContent(snapshot)
                    }
                } else {
                    unavailable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
        .frame(width: 500, height: 440)
        .background(ProductPalette.pageBackground)
        .onAppear {
            if case .idle = store.previewPayoutState {
                amountIsFocused = true
            }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            store.cancelPreviewPayout()
            store.acknowledgeCompletedPreviewPayout()
            store.dismissPayoutError()
        }
        .alert(
            "Check the amount",
            isPresented: Binding(
                get: { entryError != nil || store.payoutError != nil },
                set: {
                    if !$0 {
                        entryError = nil
                        store.dismissPayoutError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                entryError = nil
                store.dismissPayoutError()
                amountIsFocused = true
            }
        } message: {
            if let entryError {
                Text(entryError)
            } else if let error = store.payoutError {
                Text(ContributionsPresentation.payoutError(error))
            }
        }
    }

    private var previewNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(DarkbloomTheme.accent)
            Text("UI PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
            Text("No funds will move.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(DarkbloomTheme.accent.opacity(0.055))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func payoutContent(_ snapshot: ContributionsSnapshot) -> some View {
        switch store.previewPayoutState {
        case .idle:
            payoutForm(snapshot)
                .transition(.opacity)
        case .submitting(let request):
            submitting(request)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .completed(let receipt):
            completed(receipt)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private func payoutForm(_ snapshot: ContributionsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview a withdrawal")
                .font(DarkbloomTheme.chivo(26))
                .tracking(-0.6)
            Text("Choose an amount from your withdrawable balance. This interaction is local and simulated until payout services are connected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("$")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(
                        "Withdrawal amount in US dollars",
                        text: $amountText,
                        prompt: Text("0.00")
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .focused($amountIsFocused)
                        .onSubmit { submit() }
                        .accessibilityLabel("Withdrawal amount in US dollars")

                    Button("Use full balance") {
                        amountText = ContributionsPresentation.editableDollars(snapshot.withdrawableBalance)
                        amountIsFocused = true
                    }
                    .buttonStyle(.link)
                }

                Divider()

                HStack {
                    Text("Withdrawable")
                    Spacer()
                    Text(ContributionsPresentation.amount(snapshot.withdrawableBalance))
                        .monospacedDigit()
                }
                HStack {
                    Text("Minimum")
                    Spacer()
                    Text(ContributionsPresentation.amount(snapshot.minimumPayout))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(17)
            .productSurface()
            .padding(.top, 22)

            Spacer()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Simulate withdrawal", systemImage: "arrow.up.right") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submitting(_ request: PreviewPayoutRequest) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Previewing withdrawal")
                .font(DarkbloomTheme.chivo(22))
            Text(ContributionsPresentation.amount(request.amount))
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("No external request is being sent.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func completed(_ receipt: PreviewPayoutReceipt) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 52))
                .foregroundStyle(ProductPalette.positive)

            Text("Gross-amount preview complete")
                .font(DarkbloomTheme.chivo(25))
                .padding(.top, 16)
            Text(ContributionsPresentation.amount(receipt.amount))
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
                .padding(.top, 7)
            Text("This prototype only covers choosing a gross amount. Payout method, fees, net deposit, and destination are not modeled. No payout was created and no money moved.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
                .padding(.top, 10)

            Spacer()

            Button("Done") {
                store.acknowledgeCompletedPreviewPayout()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var setupRequired: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.crop.circle.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 48))
                .foregroundStyle(DarkbloomTheme.accent)
            Text("Payouts aren’t ready")
                .font(DarkbloomTheme.chivo(24))
                .padding(.top, 16)
            Text("The account summary only tells this preview that payouts are not ready—it does not say why. A connected version will open the authoritative payout status and next step here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 350)
                .padding(.top, 9)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Contributions unavailable")
                .font(DarkbloomTheme.chivo(23))
            Text("Close this preview and try again when account data is available.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard let amount = ContributionsPresentation.microUSD(fromDollars: amountText) else {
            entryError = "Enter a valid dollar amount with no more than six decimal places."
            return
        }

        entryError = nil
        guard case .accepted = store.requestPreviewPayout(amount: amount) else { return }
        amountIsFocused = false

        completionTask?.cancel()
        completionTask = Task { @MainActor in
            do {
                if !reduceMotion {
                    try await Task.sleep(for: .milliseconds(780))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                _ = store.advancePreviewPayout()
            }
            completionTask = nil
        }
    }
}
