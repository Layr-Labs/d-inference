import Foundation
import ProviderCore

/// Snapshot of non-Darkbloom inference that can steal unified memory / ports.
/// Injectable for pure unit tests (see `DoctorChecksTests`).
struct LocalContentionSnapshot: Equatable, Sendable {
    /// True if something is listening on Ollama's default port.
    var ollamaPortListening: Bool
    /// Short process name tokens observed (e.g. "ollama", "llama-server").
    var competingProcessHints: [String]
    /// The other build environment's provider (dev or production) when it is
    /// running on this Mac: its models share the same unified memory.
    var otherProvidersRunning: [String] = []

    static let empty = LocalContentionSnapshot(ollamaPortListening: false, competingProcessHints: [])

    /// Best-effort live probe. Failures degrade to empty (no false WARNs).
    static func live(
        runner: SecurityCommandRunner? = nil,
        otherProviders: () -> [String] = LocalContentionSnapshot.runningOtherProviders
    ) -> LocalContentionSnapshot {
        var ollama = false
        var hints: [String] = []

        // Port 11434 — Ollama default
        if let out = capture("/usr/sbin/lsof", args: ["-nP", "-iTCP:11434", "-sTCP:LISTEN"], runner: runner) {
            if out.contains("LISTEN") {
                ollama = true
                if out.lowercased().contains("ollama") {
                    hints.append("ollama")
                }
            }
        }

        // Process table hints (names only — no args, avoid leaking paths/keys)
        if let ps = capture("/bin/ps", args: ["-axo", "comm="], runner: runner) {
            let lower = ps.lowercased()
            let watch = ["ollama", "llama-server", "mlx_lm.server", "vllm", "text-generation-launcher"]
            for name in watch where lower.contains(name) {
                if !hints.contains(name) { hints.append(name) }
            }
        }

        return LocalContentionSnapshot(
            ollamaPortListening: ollama,
            competingProcessHints: hints.sorted(),
            otherProvidersRunning: otherProviders()
        )
    }

    /// CLI names of the other build environments whose provider process is
    /// alive, from that install's daemon state file.
    static func runningOtherProviders() -> [String] {
        BuildEnvironment.allCases.filter { $0 != .current }.compactMap { other in
            guard let identity = DaemonStateFile.read(from: DaemonStateFile.path(for: other))?.processIdentity,
                identity.isCurrent()
            else { return nil }
            return other.cliName
        }
    }

    private static func capture(_ path: String, args: [String], runner: SecurityCommandRunner?) -> String? {
        if let runner { return try? runner.run(path, args).stdout }
        return runCapture(path, args: args)
    }

    static func runCapture(_ path: String, args: [String], timeout: TimeInterval = 5) -> String? {
        guard let data = try? BoundedProcess.runCapturingStandardOutput(
            URL(fileURLWithPath: path), arguments: args, timeout: timeout,
            requireSuccessfulExit: false
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

func competingInferenceCheck(_ snap: LocalContentionSnapshot) -> DoctorCheck {
    if !snap.ollamaPortListening && snap.competingProcessHints.isEmpty && snap.otherProvidersRunning.isEmpty {
        return DoctorCheck(
            name: "competing inference",
            status: .pass,
            detail: "no common local inference competitors detected"
        )
    }
    var parts: [String] = []
    if snap.ollamaPortListening {
        parts.append("port 11434 LISTEN (Ollama default)")
    }
    if !snap.competingProcessHints.isEmpty {
        parts.append("processes: " + snap.competingProcessHints.joined(separator: ", "))
    }
    for other in snap.otherProvidersRunning {
        parts.append("the `\(other)` provider is also running on this Mac; its models count against the same memory")
    }
    return DoctorCheck(
        name: "competing inference",
        status: .warn,
        detail: parts.joined(separator: "; ")
            + " — can reduce usable RAM / deroute paid work on unified memory"
    )
}
