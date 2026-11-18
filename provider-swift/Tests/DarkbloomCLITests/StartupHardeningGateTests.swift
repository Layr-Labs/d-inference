import DarkbloomProcessHardening
import ProviderAppAttest
import Testing
@testable import darkbloom

/// A process that could not remove the debugging handles it was started with
/// runs only the diagnostics that say so.
@Suite struct StartupHardeningGateTests {
    static let clean = ProcessStartupHardening.Outcome(
        inherited: .init(task: 0x2800, thread: 0), remaining: .init(task: 0, thread: 0), removalAccepted: true)
    static let handlerLeft = ProcessStartupHardening.Outcome(
        inherited: .init(task: 0x3FFE, thread: 0), remaining: .init(task: 0x400, thread: 0), removalAccepted: true)
    static let removalRefused = ProcessStartupHardening.Outcome(
        inherited: .init(task: 0x3FFE, thread: 0), remaining: .init(task: 0, thread: 0), removalAccepted: false)
    static let unreadable = ProcessStartupHardening.Outcome(
        inherited: nil, remaining: nil, removalAccepted: true)

    @Test func cleanProcessRunsEveryCommand() {
        for arguments in [["start", "--foreground"], ["start", "--local", "--here"], ["login"], ["models", "download"],
                          [AppAttestWorkerHost.argument], [NativeServeQualificationCommand.argument], ["cluster", "member-identity"], []] {
            #expect(StartupHardeningGate.admits(arguments, outcome: Self.clean), "\(arguments)")
        }
    }

    @Test(arguments: [handlerLeft, removalRefused, unreadable])
    func otherwiseOnlyDiagnosticsRun(outcome: ProcessStartupHardening.Outcome) {
        #expect(!outcome.isClean)
        for arguments in [["start", "--foreground"], ["start", "--local", "--here"], ["start"], ["serve"],
                          [AppAttestWorkerHost.argument], [NativeServeQualificationCommand.argument],
                          [AppAttestQualificationCommand.argument], ["--opencode"], ["cluster", "member-identity"],
                          ["login"], ["benchmark"], ["unknown-command"]] {
            #expect(!StartupHardeningGate.admits(arguments, outcome: outcome), "\(arguments)")
        }
        for arguments in [["doctor"], ["verify"], ["status"], ["logs"], ["--version"], ["--help"], ["help"], []] {
            #expect(StartupHardeningGate.admits(arguments, outcome: outcome), "\(arguments)")
        }
        #expect(StartupHardeningGate.refusal.contains("will not serve"))
        #expect(StartupHardeningGate.refusal.contains("doctor"))
    }
}
