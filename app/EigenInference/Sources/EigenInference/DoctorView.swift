/// DoctorView — Displays results from `darkbloom doctor`.
///
/// Runs the 8-point diagnostic check and shows each result with
/// a status icon and detail text. Provides remediation hints.

import SwiftUI

struct DoctorView: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var checks: [DiagnosticCheck] = []
    @State private var isRunning = false
    @State private var rawOutput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Provider Diagnostics")
                        .font(.display(22))
                        .fontWeight(.bold)

                    Spacer()

                    Button {
                        Task { await runDoctor() }
                    } label: {
                        Label(isRunning ? "Running..." : "Run Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                    .buttonStyle(.bordered)
                }

                if isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Running diagnostics...")
                            .foregroundColor(.warmInkLight)
                    }
                }

                if !checks.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(checks) { check in
                            checkRow(check)
                        }
                    }
                }

                if !rawOutput.isEmpty {
                    Divider()

                    DisclosureGroup("Raw Output") {
                        Text(rawOutput)
                            .font(.monoWarm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.warmBgSecondary)
                            .cornerRadius(6)
                            .textSelection(.enabled)
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            await runDoctor()
        }
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(check.passed ? .adaptiveTealAccent : .adaptiveError)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.name)
                    .fontWeight(.medium)

                Text(check.detail)
                    .font(.captionWarm)
                    .foregroundColor(.warmInkLight)

                if !check.passed, let hint = check.remediation {
                    Text(hint)
                        .font(.captionWarm)
                        .foregroundColor(.adaptiveGold)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(check.passed ? Color.adaptiveTealAccent.opacity(0.05) : Color.adaptiveError.opacity(0.05))
        .cornerRadius(8)
    }

    private func runDoctor() async {
        isRunning = true
        checks = []
        rawOutput = ""

        do {
            let result = try await CLIRunner.run(["doctor"])
            rawOutput = result.output
            checks = parseDoctorOutput(result.output)
        } catch {
            rawOutput = "Failed to run doctor: \(error.localizedDescription)"
        }

        isRunning = false
    }

    /// Parse doctor output into structured checks.
    ///
    /// Expected format from the CLI:
    ///   1. Hardware ............... Apple M4 Max, 64 GB, 40 GPU cores
    ///   2. SIP ................... ✓ Enabled
    ///   3. Secure Enclave ........ ✓ Available
    ///   etc.
    private func parseDoctorOutput(_ output: String) -> [DiagnosticCheck] {
        var result: [DiagnosticCheck] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match lines like "1. Check name .... status"
            guard let dotIndex = trimmed.firstIndex(of: "."),
                  let stepNum = Int(String(trimmed[trimmed.startIndex..<dotIndex])) else {
                continue
            }

            let afterDot = String(trimmed[trimmed.index(after: dotIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Split on the dots/spaces separator
            let parts = afterDot.components(separatedBy: "...")
            guard parts.count >= 2 else {
                // Try splitting on multiple spaces
                let spaceParts = afterDot.components(separatedBy: "  ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if spaceParts.count >= 2 {
                    let name = spaceParts[0]
                    let detail = spaceParts[1...].joined(separator: " ")
                    let passed = detail.contains("✓") || detail.contains("✅") ||
                                 detail.lowercased().contains("enabled") ||
                                 detail.lowercased().contains("available") ||
                                 detail.lowercased().contains("found") ||
                                 detail.lowercased().contains("ok") ||
                                 detail.lowercased().contains("connected")
                    result.append(DiagnosticCheck(
                        id: stepNum,
                        name: name,
                        detail: detail.replacingOccurrences(of: "✓ ", with: "").replacingOccurrences(of: "✗ ", with: ""),
                        passed: passed,
                        remediation: passed ? nil : remediationHint(for: stepNum)
                    ))
                    continue
                }
                continue
            }

            let name = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let detail = parts.dropFirst().joined(separator: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ". "))

            let passed = detail.contains("✓") || detail.contains("✅") ||
                         !detail.contains("✗") && !detail.contains("❌") &&
                         !detail.lowercased().contains("not found") &&
                         !detail.lowercased().contains("disabled") &&
                         !detail.lowercased().contains("failed") &&
                         !detail.lowercased().contains("not enrolled") &&
                         !detail.lowercased().contains("error")

            result.append(DiagnosticCheck(
                id: stepNum,
                name: name,
                detail: detail.replacingOccurrences(of: "✓ ", with: "").replacingOccurrences(of: "✗ ", with: ""),
                passed: passed,
                remediation: passed ? nil : remediationHint(for: stepNum)
            ))
        }

        return result
    }

    private func remediationHint(for step: Int) -> String {
        switch step {
        case 1: return "Apple Silicon Mac required."
        case 2: return "Reboot into Recovery Mode and run 'csrutil enable'."
        case 3: return "Secure Enclave requires Apple Silicon hardware."
        case 4: return "Run the setup wizard to enroll in MDM."
        case 5: return "Run 'darkbloom install' to set up the inference runtime."
        case 6: return "Download a model from the Model tab in Settings."
        case 7: return "The node key is auto-generated on first run."
        case 8: return "Check your internet connection and coordinator URL."
        default: return ""
        }
    }
}

struct DiagnosticCheck: Identifiable {
    let id: Int
    let name: String
    let detail: String
    let passed: Bool
    let remediation: String?
}
