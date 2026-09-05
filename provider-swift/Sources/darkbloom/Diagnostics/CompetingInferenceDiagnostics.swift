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

    /// Runs `path` and returns its stdout, or nil if the probe could not
    /// produce any.
    ///
    /// This used to spawn the child itself and call `waitUntilExit()` before
    /// reading the pipe, which deadlocks the moment the child outgrows the
    /// ~64 KiB Darwin pipe buffer: the child blocks in `write(2)` with a full
    /// pipe while the parent waits for it to exit. `ps -axo comm=` clears
    /// 64 KiB on a busy Mac, so `doctor` and `verify` hung outright (#811).
    ///
    /// `FanProcessRunner` drains concurrently *and* enforces a deadline, which
    /// is the part draining alone does not give: a child that never closes
    /// stdout still holds `readDataToEndOfFile()` forever. Five seconds is the
    /// budget for a probe documented above as degrading to empty, so a slow
    /// `lsof` now costs a missing hint rather than a hung command.
    static func runCapture(_ path: String, args: [String]) -> String? {
        let result = FanProcessRunner.run(
            path,
            arguments: args,
            timeout: 5,
            discardStandardError: true,
            // The runner's 64 KiB default is sized for fan install logs. `ps`
            // was 78,689 bytes on the reporter's Mac, and a busy machine is
            // exactly where this probe has to work, so capping at 64 KiB would
            // drop the hints past the cap and report "no competitors" for a
            // running Ollama. 1 MiB is ~13x the reported table and still bounds
            // a runaway child.
            maximumOutputBytes: 1024 * 1024
        )
        // -1 is a spawn failure or the deadline. A non-zero *exit* still yields
        // usable text and the previous implementation never checked the status
        // either, so `lsof` exiting 1 with no listener keeps degrading to no
        // hint. Output is decoded lossily where `String(data:encoding:)` used
        // to return nil on invalid UTF-8.
        return result.status == -1 ? nil : result.output
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
