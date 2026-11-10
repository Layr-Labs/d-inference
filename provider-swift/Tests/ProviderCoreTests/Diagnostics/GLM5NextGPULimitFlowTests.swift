import Foundation
import Testing

@testable import ProviderCore

/// `darkbloom cluster gpu-limit` against a fake Mac (`GLM5NextGPULimitRunner`):
/// it changes nothing only when the live limits and the boot job both match,
/// and installs a missing or different job behind the same confirmation and
/// prompt. The fake records the requests macOS would have been asked to run;
/// nothing here runs a command or reads the real job file.
@Suite("GLM pair-rank GPU limit command")
struct GLM5NextGPULimitFlowTests {
    static let value = GLM5NextWiredLimit.pairRankRecommendation(chipName: "Apple M5 Max", physicalMemoryBytes: 128 << 30)!
    static let metLimits = GLM5NextWiredLimit.Limits(gpuWiredLimitMB: 114_688, globalUserWireLimitBytes: 130_567_005_798,
        userWireLimitBytes: 130_567_005_798, metalWorkingSetBytes: 120_259_084_288)
    static let defaultLimits = GLM5NextWiredLimit.Limits(gpuWiredLimitMB: 0, globalUserWireLimitBytes: 0,
        userWireLimitBytes: 0, metalWorkingSetBytes: 115_448_725_504)

    /// The job file the raise's commands write, replayed from their `plutil -insert` steps.
    static func written(by request: GLM5NextWiredLimitRequest) throws -> Data {
        var job: [String: Any] = [:], program: [String] = []
        for command in request.commands where command.hasPrefix("/usr/bin/plutil -insert ") {
            let words = command.dropFirst("/usr/bin/plutil -insert ".count).split(separator: " ").map(String.init)
            switch (words[0], words[1]) {
            case ("ProgramArguments", "-array"): continue
            case (let key, "-string") where key.hasPrefix("ProgramArguments."): program.append(words[2])
            case (let key, "-string"): job[key] = words[2]
            case (let key, "-bool"): job[key] = words[2] == "true"
            default: throw GLM5NextGPULimitFlowTestError.unexpected(command)
            }
        }
        job["ProgramArguments"] = program
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    static func plist(_ job: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// A Mac with these limits and this job file. An applied raise leaves the
    /// job it writes and the limits met, unless `appliedJob` says otherwise.
    final class FakeMac {
        var limits: GLM5NextWiredLimit.Limits
        var job: Data?
        var outcome: GLM5NextWiredLimitApproval.Outcome = .applied
        var appliedJob: Data??
        /// The limits an applied request leaves, when not the ones it asked for.
        var appliedLimits: GLM5NextWiredLimit.Limits?
        private(set) var requests: [GLM5NextWiredLimitRequest] = []
        private(set) var questions: [String] = []
        private(set) var lines: [String] = []

        init(limits: GLM5NextWiredLimit.Limits, job: Data?) { self.limits = limits; self.job = job }

        var runner: GLM5NextGPULimitRunner {
            .init(limits: { self.limits }, bootJobDefinition: { self.job }, approve: { request in
                self.requests.append(request)
                if self.outcome == .applied {
                    switch request.purpose {
                    case .raise: self.limits = self.appliedLimits ?? GLM5NextGPULimitFlowTests.metLimits
                        self.job = self.appliedJob ?? (try? GLM5NextGPULimitFlowTests.written(by: request))
                    case .remove: self.limits = self.appliedLimits ?? GLM5NextGPULimitFlowTests.defaultLimits
                        self.job = self.appliedJob ?? nil
                    }
                }
                return self.outcome
            })
        }

        func run(undo: Bool = false, terminal: Bool = true, answer: Bool = true) -> Int32 {
            GLM5NextGPULimitFlow.run(undo: undo, recommendation: GLM5NextGPULimitFlowTests.value, runner: runner,
                confirm: terminal ? { self.questions.append($0); return answer } : nil, say: { self.lines.append($0) })
        }
    }

    static var raise: GLM5NextWiredLimitRequest { GLM5NextWiredLimitRequest(.raise(value))! }

    @Test("the boot job is recognised as exactly what the raise writes, and the doctor's 256 GB job as the same job")
    func bootJobReading() throws {
        let written = try Self.written(by: Self.raise)
        #expect(GLM5NextWiredLimitBootJob.reading(nil, for: Self.value) == .missing)
        #expect(GLM5NextWiredLimitBootJob.reading(written, for: Self.value) == .matches)
        let ultra = try #require(GLM5NextWiredLimit.pairRankRecommendation(chipName: "Apple M5 Ultra", physicalMemoryBytes: 256 << 30))
        #expect(GLM5NextWiredLimitBootJob.reading(Data(ultra.launchDaemonPlist.utf8), for: ultra) == .matches)
        // Another Mac's values, each key changed, a key added or removed, a number for `true`, and no property list.
        let job = try #require(try PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any])
        var variants: [[String: Any]] = [
            job.merging(["ProgramArguments": ultra.bootJobProgramArguments]) { $1 },
            job.merging(["ProgramArguments": ["/usr/sbin/sysctl"] + Self.value.sysctlAssignments]) { $1 },
            job.merging(["Label": "com.example.other"]) { $1 },
            job.merging(["StandardOutPath": "/tmp/out.log"]) { $1 },
            job.merging(["RunAtLoad": 1]) { $1 },
            job.merging(["RunAtLoad": false]) { $1 },
            job.merging(["KeepAlive": true]) { $1 },
        ]
        variants.append(job.filter { $0.key != "StandardErrorPath" })
        for variant in variants {
            #expect(GLM5NextWiredLimitBootJob.reading(try Self.plist(variant), for: Self.value) == .differs)
        }
        #expect(GLM5NextWiredLimitBootJob.reading(Data(), for: Self.value) == .differs)
        #expect(GLM5NextWiredLimitBootJob.reading(Data("not a plist".utf8), for: Self.value) == .differs)
    }

    @Test("limits met and the job in place: nothing to change, nothing asked")
    func nothingToChange() throws {
        let mac = FakeMac(limits: Self.metLimits, job: try Self.written(by: Self.raise))
        #expect(mac.run() == 0)
        #expect(mac.requests.isEmpty && mac.questions.isEmpty)
        #expect(mac.lines.last == "It meets the recommendation for this 128 GB Mac (112.00 GiB) now, and the boot job keeps it after restarts. Nothing to change.")
    }

    @Test("limits met but no boot job: it installs the job with the same consent and prompt")
    func installsMissingJob() throws {
        let mac = FakeMac(limits: Self.metLimits, job: nil)
        #expect(GLM5NextGPULimitFlow.plan(undo: false, recommendation: Self.value, limits: Self.metLimits, bootJob: .missing)
            == .raise(.bootJobMissing))
        #expect(mac.run() == 0)
        #expect(mac.requests == [Self.raise])
        #expect(mac.questions == ["Install it now? macOS will ask an administrator to approve. [y/N] "])
        #expect(mac.lines.contains { $0.hasSuffix("but no boot job keeps it after a restart. This installs that job.") })
        #expect(mac.lines.last == "✓ This Mac's GPU now keeps 112.00 GiB resident (iogpu.wired_limit_mb=114688), and the boot job "
            + "keeps it after restarts. Run `darkbloom cluster` again so both Macs plan and load with it.")
        #expect(GLM5NextWiredLimitBootJob.reading(mac.job, for: Self.value) == .matches)
    }

    @Test("limits met but a different boot job: it replaces the job with the same consent and prompt")
    func replacesDifferentJob() throws {
        let other = try Self.plist(["Label": GLM5NextWiredLimit.launchDaemonLabel, "ProgramArguments": ["/bin/sh", "-c", "true"],
            "RunAtLoad": true, "StandardOutPath": GLM5NextWiredLimit.launchDaemonLogPath,
            "StandardErrorPath": GLM5NextWiredLimit.launchDaemonLogPath])
        let mac = FakeMac(limits: Self.metLimits, job: other)
        #expect(mac.run() == 0)
        #expect(mac.requests == [Self.raise])
        #expect(mac.lines.contains { $0.hasSuffix("is not the one this command writes. This replaces it.") })
        #expect(GLM5NextWiredLimitBootJob.reading(mac.job, for: Self.value) == .matches)
    }

    @Test("limits below the recommendation: it raises them, whatever the job")
    func raisesLimits() throws {
        let mac = FakeMac(limits: Self.defaultLimits, job: try Self.written(by: Self.raise))
        #expect(mac.run() == 0)
        #expect(mac.requests == [Self.raise])
        #expect(mac.questions == ["Raise it now? macOS will ask an administrator to approve. [y/N] "])
        #expect(mac.lines.first == "This Mac's GPU keeps 107.52 GiB resident now (the macOS default).")
        #expect(mac.lines.last?.hasPrefix("✓ This Mac's GPU now keeps 112.00 GiB resident") == true)
    }

    @Test("an applied raise says ✓ only when the live limits and the boot job read back as asked; otherwise ✗, what is off and what to do")
    func raiseIsReadBack() throws {
        // macOS reported success, but the GPU limit is still the default and the wire limits are unchanged.
        let unchanged = FakeMac(limits: Self.defaultLimits, job: nil)
        unchanged.appliedLimits = Self.defaultLimits
        #expect(unchanged.run() == 1)
        #expect(!unchanged.lines.contains { $0.hasPrefix("✓") })
        #expect(unchanged.lines.contains("✗ macOS reported the change as made, but this Mac does not read back as asked:"))
        #expect(unchanged.lines.contains("  - the GPU keeps 107.52 GiB resident (the macOS default); it should keep 112.00 GiB (iogpu.wired_limit_mb=114688)"))
        #expect(unchanged.lines.contains("  - vm.global_user_wire_limit is 0; it should be at least 130567005798"))
        #expect(unchanged.lines.contains("  - vm.user_wire_limit is 0; it should be at least 130567005798"))
        #expect(unchanged.lines.contains("Run `darkbloom cluster gpu-limit` again. If it still does not read back, an administrator can run these instead:"))
        #expect(unchanged.lines.filter { $0.hasPrefix("  sudo /") }.count == Self.raise.commands.count)
        // A limit that cannot be read is not proof either.
        let unreadable = FakeMac(limits: Self.defaultLimits, job: nil)
        unreadable.appliedLimits = .init(gpuWiredLimitMB: nil, globalUserWireLimitBytes: nil, userWireLimitBytes: nil,
            metalWorkingSetBytes: 115_448_725_504)
        #expect(unreadable.run() == 1 && !unreadable.lines.contains { $0.hasPrefix("✓") })
        #expect(unreadable.lines.contains("  - vm.user_wire_limit could not be read; it should be at least 130567005798"))
    }

    @Test("an applied --undo says ✓ only when the boot job is gone and the GPU limit reads 0; otherwise ✗, what is off and what to do")
    func undoIsReadBack() throws {
        let kept = FakeMac(limits: Self.metLimits, job: try Self.written(by: Self.raise))
        kept.appliedLimits = Self.metLimits
        kept.appliedJob = .some(try Self.written(by: Self.raise))
        #expect(kept.run(undo: true) == 1)
        #expect(!kept.lines.contains { $0.hasPrefix("✓") })
        #expect(kept.lines.contains("✗ macOS reported the change as made, but this Mac does not read back as asked:"))
        #expect(kept.lines.contains("  - iogpu.wired_limit_mb is 114688; it should be 0 (the macOS default)"))
        #expect(kept.lines.contains("  - the boot job is still at \(GLM5NextWiredLimit.launchDaemonPath)"))
        #expect(kept.lines.filter { $0.hasPrefix("  sudo /") }.count == GLM5NextWiredLimitRequest(.remove)!.commands.count)
        let unreadable = FakeMac(limits: Self.metLimits, job: try Self.written(by: Self.raise))
        unreadable.appliedLimits = .init(gpuWiredLimitMB: nil, globalUserWireLimitBytes: nil, userWireLimitBytes: nil,
            metalWorkingSetBytes: 115_448_725_504)
        #expect(unreadable.run(undo: true) == 1)
        #expect(unreadable.lines.contains("  - iogpu.wired_limit_mb could not be read; it should be 0 (the macOS default)"))
    }

    @Test("without a terminal, or declined at the question, nothing is asked of macOS")
    func asksFirst() {
        let unattended = FakeMac(limits: Self.metLimits, job: nil)
        #expect(unattended.run(terminal: false) == 2)
        #expect(unattended.requests.isEmpty)
        #expect(unattended.lines.contains("No terminal to confirm in. An administrator can run these instead:"))
        #expect(unattended.lines.filter { $0.hasPrefix("  sudo /") }.count == Self.raise.commands.count)
        let declined = FakeMac(limits: Self.metLimits, job: nil)
        #expect(declined.run(answer: false) == 0)
        #expect(declined.requests.isEmpty && declined.lines.last == "Nothing was changed.")
    }

    @Test("what macOS answers decides the exit status, and an applied raise must leave the job it writes")
    func outcomes() throws {
        for (outcome, line) in [(GLM5NextWiredLimitApproval.Outcome.declined, "Nothing was changed: the approval was cancelled."),
                                (.commandFailed, "macOS ran the change and a step failed; run `darkbloom cluster gpu-limit` again to see what is in place.")] {
            let mac = FakeMac(limits: Self.metLimits, job: nil)
            mac.outcome = outcome
            #expect(mac.run() == 1 && mac.lines.last == line && mac.requests == [Self.raise])
        }
        let unavailable = FakeMac(limits: Self.metLimits, job: nil)
        unavailable.outcome = .unavailable
        #expect(unavailable.run() == 1)
        #expect(unavailable.lines.contains("macOS could not show the approval here. An administrator can run these instead:"))
        let notWritten = FakeMac(limits: Self.metLimits, job: nil)
        notWritten.appliedJob = .some(nil)
        #expect(notWritten.run() == 1)
        #expect(notWritten.lines.contains("  - no boot job is at \(GLM5NextWiredLimit.launchDaemonPath), so the limit would not last a restart"))
        #expect(!notWritten.lines.contains { $0.hasPrefix("✓") })
    }

    @Test("a limit the Mac does not report is never changed: refused with the reason, before any question")
    func unreadableLimitIsRefused() {
        for undo in [false, true] {
            let mac = FakeMac(limits: .init(gpuWiredLimitMB: nil, globalUserWireLimitBytes: 0, userWireLimitBytes: 0,
                metalWorkingSetBytes: 115_448_725_504), job: nil)
            #expect(mac.run(undo: undo) == 2)
            #expect(mac.requests.isEmpty && mac.questions.isEmpty)
            #expect(mac.lines.last == "This Mac does not report iogpu.wired_limit_mb, so Darkbloom does not change it. Nothing was changed.")
        }
        let wire = FakeMac(limits: .init(gpuWiredLimitMB: 0, globalUserWireLimitBytes: nil, userWireLimitBytes: 0,
            metalWorkingSetBytes: 115_448_725_504), job: nil)
        #expect(wire.run() == 2 && wire.requests.isEmpty)
        #expect(wire.lines.last == "This Mac does not report vm.global_user_wire_limit, so Darkbloom does not change it. Nothing was changed.")
    }

    @Test("--undo removes the job and the raised limit, whatever is in place")
    func undo() throws {
        let mac = FakeMac(limits: Self.metLimits, job: try Self.written(by: Self.raise))
        #expect(mac.run(undo: true) == 0)
        #expect(mac.requests == [GLM5NextWiredLimitRequest(.remove)!])
        #expect(mac.questions == ["Undo it now? macOS will ask an administrator to approve. [y/N] "])
        #expect(mac.job == nil)
        #expect(mac.lines.last == "✓ The GPU limit is back to the macOS default (iogpu.wired_limit_mb=0) and the boot job is gone. "
            + "The wire limits return to their defaults at the next restart.")
    }
}

enum GLM5NextGPULimitFlowTestError: Error { case unexpected(String) }
