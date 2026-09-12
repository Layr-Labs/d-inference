import Foundation

/// Snapshot of non-Darkbloom inference that can steal unified memory / ports.
/// Injectable for pure unit tests (see `DoctorChecksTests`).
struct LocalContentionSnapshot: Equatable, Sendable {
    /// True if something is listening on Ollama's default port.
    var ollamaPortListening: Bool
    /// Short process name tokens observed (e.g. "ollama", "llama-server").
    var competingProcessHints: [String]

    static let empty = LocalContentionSnapshot(ollamaPortListening: false, competingProcessHints: [])

    /// Best-effort live probe. Failures degrade to empty (no false WARNs).
    static func live() -> LocalContentionSnapshot {
        var ollama = false
        var hints: [String] = []

        // Port 11434 — Ollama default
        if let out = runCapture("/usr/sbin/lsof", args: ["-nP", "-iTCP:11434", "-sTCP:LISTEN"]) {
            if out.contains("LISTEN") {
                ollama = true
                if out.lowercased().contains("ollama") {
                    hints.append("ollama")
                }
            }
        }

        // Process table hints (names only — no args, avoid leaking paths/keys)
        if let ps = runCapture("/bin/ps", args: ["-axo", "comm="]) {
            let lower = ps.lowercased()
            let watch = ["ollama", "llama-server", "mlx_lm.server", "vllm", "text-generation-launcher"]
            for name in watch where lower.contains(name) {
                if !hints.contains(name) { hints.append(name) }
            }
        }

        return LocalContentionSnapshot(
            ollamaPortListening: ollama,
            competingProcessHints: hints.sorted()
        )
    }

    /// Runs `path` and returns its stdout, or nil if it could not be launched.
    ///
    /// The pipe is drained to EOF **before** `waitUntilExit()`. A macOS pipe
    /// buffer holds at most 64 KiB, so waiting first deadlocks on any output
    /// larger than that: the child blocks in `write()` with a full pipe while
    /// the parent blocks waiting for the child to exit. `ps -axo comm=` clears
    /// 64 KiB on a busy Mac -- a booted iOS Simulator alone contributes ~50 KB
    /// of long runtime paths -- so `doctor` hung for real users.
    /// `readDataToEndOfFile()` returns when the child closes the stream, so it
    /// is also the join point; `waitUntilExit()` then just reaps.
    static func runCapture(_ path: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

func competingInferenceCheck(_ snap: LocalContentionSnapshot) -> DoctorCheck {
    if !snap.ollamaPortListening && snap.competingProcessHints.isEmpty {
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
    return DoctorCheck(
        name: "competing inference",
        status: .warn,
        detail: parts.joined(separator: "; ")
            + " — can reduce usable RAM / deroute paid work on unified memory"
    )
}
