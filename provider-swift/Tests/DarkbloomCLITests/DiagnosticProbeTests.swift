import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("Diagnostic subprocess projections")
struct DiagnosticProbeTests {
    @Test("contention probes preserve scoped arguments, nonzero output and sorted unique hints")
    func contentionProbeContract() {
        var calls: [(String, [String])] = []
        let runner = SecurityCommandRunner { path, arguments in
            calls.append((path, arguments))
            return SecurityCommandResult(
                terminationStatus: 1,
                stdout: path == "/usr/sbin/lsof"
                    ? "ollama LISTEN" : "ollama\nllama-server\nvllm\nollama")
        }
        let snapshot = LocalContentionSnapshot.live(runner: runner)
        #expect(snapshot.ollamaPortListening)
        #expect(snapshot.competingProcessHints == ["llama-server", "ollama", "vllm"])
        #expect(calls.count == 2)
        #expect(calls[0].0 == "/usr/sbin/lsof")
        #expect(calls[0].1 == ["-nP", "-iTCP:11434", "-sTCP:LISTEN"])
        #expect(calls[1].0 == "/bin/ps")
        #expect(calls[1].1 == ["-axo", "comm="])
    }

    @Test("unavailable contention probes remain informational")
    func unavailableContentionProbes() {
        let runner = SecurityCommandRunner { _, _ in throw URLError(.unknown) }
        #expect(LocalContentionSnapshot.live(runner: runner) == .empty)
        #expect(DoctorRunner.systemSleepPrevented(runner: runner) == nil)
    }

    @Test("sleep assertions require a successful command and either prevention flag")
    func sleepAssertionContract() {
        for (status, stdout, expected) in [
            (Int32(0), "PreventUserIdleSystemSleep 1", Optional(true)),
            (Int32(0), "PreventSystemSleep 1", Optional(true)),
            (Int32(0), "PreventUserIdleSystemSleep 0\nPreventSystemSleep 0", Optional(false)),
            (Int32(1), "PreventSystemSleep 1", nil),
        ] {
            let runner = SecurityCommandRunner { path, arguments in
                #expect(path == "/usr/bin/pmset")
                #expect(arguments == ["-g", "assertions"])
                return SecurityCommandResult(terminationStatus: status, stdout: stdout)
            }
            #expect(DoctorRunner.systemSleepPrevented(runner: runner) == expected)
        }
    }
}
