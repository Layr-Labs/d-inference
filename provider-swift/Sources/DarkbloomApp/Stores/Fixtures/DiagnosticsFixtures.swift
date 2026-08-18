import Foundation

enum DiagnosticsFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_784_330_000)

    static func make(_ fixture: DiagnosticsFixture) -> (
        report: DiagnosticReport,
        runState: DiagnosticRunState
    ) {
        var checks = healthyChecks
        var runState: DiagnosticRunState = .ready(lastChecked: timestamp)

        switch fixture {
        case .healthy:
            break

        case .trustPending:
            replaceCheck(
                id: "network-trust",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "network-trust",
                    section: .trust,
                    title: "Network trust",
                    severity: .warning,
                    message: "Secure Enclave verification passed, but MDM verification is still pending. This Mac is online but receives no network traffic yet.",
                    fix: DiagnosticFix(
                        id: "finish-enrollment",
                        title: "Finish MDM enrollment",
                        detail: "Install the Darkbloom management profile, then allow a few minutes for verification.",
                        priority: .recommended,
                        action: .openEnrollment
                    )
                )
            )

        case .blockedSecurity:
            replaceCheck(
                id: "sip",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "sip",
                    section: .security,
                    title: "System Integrity Protection",
                    severity: .failure,
                    message: "System Integrity Protection is disabled. Hardware trust requires SIP.",
                    fix: DiagnosticFix(
                        id: "enable-sip",
                        title: "Enable System Integrity Protection",
                        detail: "Restart in macOS Recovery, open Terminal, run csrutil enable, then restart your Mac.",
                        priority: .urgent,
                        action: .openRecoveryInstructions
                    )
                )
            )
            replaceCheck(
                id: "secure-boot",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "secure-boot",
                    section: .security,
                    title: "Secure Boot",
                    severity: .failure,
                    message: "Secure Boot is not set to Full Security.",
                    fix: DiagnosticFix(
                        id: "enable-secure-boot",
                        title: "Turn on Full Security",
                        detail: "Open Startup Security Utility from macOS Recovery and choose Full Security.",
                        priority: .urgent,
                        action: .openRecoveryInstructions
                    )
                )
            )
            replaceCheck(
                id: "network-trust",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "network-trust",
                    section: .trust,
                    title: "Network trust",
                    severity: .failure,
                    message: "This Mac is offline until its security posture can be verified.",
                    fix: nil
                )
            )
            replaceCheck(
                id: "version",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "version",
                    section: .version,
                    title: "Darkbloom version",
                    severity: .warning,
                    message: "A newer verified build is available.",
                    fix: DiagnosticFix(
                        id: "install-update",
                        title: "Install the latest update",
                        detail: "Download, verify, and stage the latest Darkbloom build.",
                        priority: .recommended,
                        action: .checkForUpdates
                    )
                )
            )

        case .runtimeAttention:
            replaceCheck(
                id: "model-fit",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "model-fit",
                    section: .traffic,
                    title: "Active model",
                    severity: .warning,
                    message: "The active model failed its weight verification and cannot receive requests.",
                    fix: DiagnosticFix(
                        id: "redownload-model",
                        title: "Download verified weights",
                        detail: "Replace the local copy with weights that match the catalog hash.",
                        priority: .recommended,
                        action: .redownloadModel(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit")
                    )
                )
            )
            replaceCheck(
                id: "runtime",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "runtime",
                    section: .runtime,
                    title: "Provider runtime",
                    severity: .failure,
                    message: "The daemon state is stale and the provider may be wedged.",
                    fix: DiagnosticFix(
                        id: "restart-provider",
                        title: "Restart Darkbloom",
                        detail: "Restart the provider while preserving your current model selection.",
                        priority: .urgent,
                        action: .restartProvider
                    )
                )
            )
            replaceCheck(
                id: "usage-reporting",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "usage-reporting",
                    section: .billing,
                    title: "Usage reporting",
                    severity: .warning,
                    message: "This session has usage-reporting gaps that may affect accounting.",
                    fix: DiagnosticFix(
                        id: "report-usage-gaps",
                        title: "Send a diagnostic report",
                        detail: "Share Darkbloom logs from this Mac with the support team.",
                        priority: .recommended,
                        action: .openSupport
                    )
                )
            )

        case .scanUnavailable:
            replaceCheck(
                id: "coordinator",
                in: &checks,
                with: DiagnosticCheckSummary(
                    id: "coordinator",
                    section: .connectivity,
                    title: "Coordinator connection",
                    severity: .failure,
                    message: "Darkbloom could not reach the coordinator to complete remote checks.",
                    fix: DiagnosticFix(
                        id: "check-network",
                        title: "Check your connection",
                        detail: "Confirm this Mac is online, then run the checks again.",
                        priority: .urgent,
                        action: .openNetworkSettings
                    )
                )
            )
            runState = .unavailable(message: "Remote checks could not finish while the coordinator was offline.")
        }

        return (
            DiagnosticReport(generatedAt: timestamp, checks: checks),
            runState
        )
    }

    private static func replaceCheck(
        id: DiagnosticCheckSummary.ID,
        in checks: inout [DiagnosticCheckSummary],
        with replacement: DiagnosticCheckSummary
    ) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index] = replacement
    }

    private static var healthyChecks: [DiagnosticCheckSummary] {
        [
            DiagnosticCheckSummary(
                id: "hardware",
                section: .hardware,
                title: "Apple GPU",
                severity: .passed,
                message: "Apple M4 Max with 40 GPU cores is available for inference.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "sip",
                section: .security,
                title: "System Integrity Protection",
                severity: .passed,
                message: "System Integrity Protection is enabled.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "secure-boot",
                section: .security,
                title: "Secure Boot",
                severity: .passed,
                message: "Secure Boot is set to Full Security.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "secure-enclave",
                section: .attestationKey,
                title: "Secure Enclave identity",
                severity: .passed,
                message: "This Mac can sign hardware-backed attestation challenges.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "network-trust",
                section: .trust,
                title: "Network trust",
                severity: .passed,
                message: "Hardware trust is verified and this Mac is eligible for traffic.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "model-fit",
                section: .traffic,
                title: "Model fit",
                severity: .passed,
                message: "At least one verified model fits in available unified memory.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "runtime",
                section: .runtime,
                title: "Provider runtime",
                severity: .passed,
                message: "The provider is responding and its state is current.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "coordinator",
                section: .connectivity,
                title: "Coordinator connection",
                severity: .passed,
                message: "The coordinator is reachable.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "version",
                section: .version,
                title: "Darkbloom version",
                severity: .passed,
                message: "This Mac is running the current verified build.",
                fix: nil
            ),
            DiagnosticCheckSummary(
                id: "usage-reporting",
                section: .billing,
                title: "Usage reporting",
                severity: .passed,
                message: "No usage-reporting gaps were detected in this session.",
                fix: nil
            ),
        ]
    }
}
