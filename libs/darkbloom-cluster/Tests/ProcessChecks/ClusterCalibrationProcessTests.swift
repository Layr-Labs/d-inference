import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
@testable import DarkbloomClusterProcess

@Suite(.serialized) struct ClusterCalibrationProcessTests {
    final class Fixture {
        let root: URL
        let identity: ClusterWorkerIdentity
        let profile = ClusterWorkerProfile(id: "calibration-fixture", vocabularySize: 512,
            maximumPromptTokens: 16, maximumOutputTokens: 16, maximumChunkTokens: 8, maximumContextTokens: 32)
        let plan = String(repeating: "e", count: 64), authority = String(repeating: "f", count: 64)
        let normalizedConfiguration = String(repeating: "2", count: 64)
        let descriptor = String(repeating: "3", count: 64), inventory = String(repeating: "4", count: 64)
        let policy = String(repeating: "5", count: 64)
        let environment = String(repeating: "1", count: 64)
        let executable: URL
        var children: [ClusterCalibrationProcess] = []
        init() throws {
            executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CALIBRATION_CPU_FIXTURE"]))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            identity = .init(membershipEpoch: UUID(), modelID: "qualification_glm5_next",
                artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
                peers: [.init(id: "one", buildSHA256: String(repeating: "c", count: 64)), .init(id: "two", buildSHA256: String(repeating: "d", count: 64))])
        }
        func cleanup() {
            var allJoined = true
            for child in children {
                child.cancel()
                let joined = child.waitUntilExited(deadline: child.retirementDeadline + 1_000_000_000)
                #expect(joined, "Unsuccessful direct-child join")
                allJoined = joined && allJoined
            }
            // A failed assertion is nonfatal: retain scratch for any child whose
            // actual exit remains unresolved, rather than erasing its evidence.
            if allJoined { try? FileManager.default.removeItem(at: root) }
        }
        var control: String { root.appendingPathComponent("control").path }
        func report() -> [String: Any] {
            ["nativeHardCapBytes": 1000, "hostBudgetBytes": 1000, "osHeadroomBytes": 1000,
             "committedTokens": 1, "qualifiesMaximumEnvelope": false, "requiresProcessExit": true,
             "observations": [["phase": "loaded", "nativeActiveBytes": 10, "nativePeakBytes": 20,
                 "host": ["mallocBytes": 10, "processFootprintBytes": 20]]],
             "quote": ["authorizationSHA256": authority, "descriptorSHA256": descriptor, "cut": 20, "rank": 0,
                 "nativeBytes": 10, "hostBytes": 10, "loadCapacityBytes": 20, "requestCapacityBytes": 10,
                 "inventorySHA256": inventory, "configurationSHA256": normalizedConfiguration,
                 "numericalPolicySHA256": policy, "executionEnvironmentSHA256": environment,
                 "qualifiesMaximumEnvelope": false]]
        }
        func child(_ mode: String, report: [String: Any]? = nil, deadline: UInt64? = nil,
                   attachment: ClusterOwnerBootstrapAttachment? = nil, executable: URL? = nil,
                   normalizedConfigurationSHA256: String? = nil,
                   profile: ClusterWorkerProfile? = nil,
                   initialLeaseNanoseconds: UInt64 = 1_000_000_000,
                   renewalInterval: UInt64 = 50_000_000) throws -> ClusterCalibrationProcess {
            let now = DispatchTime.now().uptimeNanoseconds, end = deadline ?? (now + 1_500_000_000)
            let file = root.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: report ?? self.report()).write(to: file)
            let credential = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch: identity.membershipEpoch)[0]
            return try ClusterCalibrationProcess(launch: .init(executable: executable ?? self.executable,
                arguments: [mode, file.path, control, identity.membershipEpoch.uuidString, String(end)] + (attachment?.workerArguments ?? []),
                environment: [:], initialInput: credential), expectedIdentity: identity, rank: 0, profile: profile ?? self.profile,
                executionPlanSHA256: plan, authorizationSHA256: authority,
                normalizedConfigurationSHA256: normalizedConfigurationSHA256 ?? normalizedConfiguration, environmentSHA256: environment,
                initialLeaseDeadline: now + initialLeaseNanoseconds, experimentDeadline: end,
                retirement: .init(childEndsItselfAtStartupDeadline: true, terminateMarginNanoseconds: 50_000_000,
                    killMarginNanoseconds: 50_000_000, reapMarginNanoseconds: 500_000_000), renewalInterval: renewalInterval)
        }
        func launch(_ mode: String, report: [String: Any]? = nil) throws -> ClusterCalibrationProcess {
            let child = try child(mode, report: report); try child.launch(); children.append(child); return child
        }
        func wait(_ condition: () -> Bool) throws {
            let end = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while !condition(), DispatchTime.now().uptimeNanoseconds < end { usleep(5000) }
            try #require(condition())
        }
        func release() throws { try Data().write(to: URL(fileURLWithPath: control + ".release")) }
    }

    @Test func reportBeforeExitIsNotSuccessAndCredentialPrecedesRenewals() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.launch("wait")
        try f.wait { child.provisionalReport != nil }
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.wait { (try? String(contentsOfFile: f.control + ".renewals", encoding: .utf8)).flatMap(UInt64.init) ?? 0 >= 2 }
        #expect(FileManager.default.fileExists(atPath: f.control + ".credential"))
        #expect(child.renewalsQueued >= 2)
        try f.release()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0)); #expect(child.sentSignals.isEmpty)
        #expect(try !child.successfulReport().isEmpty)
        child.cancel() // A post-exit cancel cannot rewrite a completed outcome.
        #expect(try !child.successfulReport().isEmpty)
    }
    @Test(arguments: [16, 17, 31])
    func promptAndDecodeFrontierIsBoundedByContextNotOutputLimit(frontier: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(f.profile.maximumOutputTokens == 16 && f.profile.maximumContextTokens == 32)
        var report = f.report(); report["committedTokens"] = frontier
        let child = try f.launch("exit", report: report)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0))
        #expect(try !child.successfulReport().isEmpty)
    }

    @Test(arguments: ["context", "above-context", "negative", "boolean", "fractional", "string", "null", "overflow"])
    func malformedOrOutOfContextFrontierCannotComplete(change: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        var report = f.report()
        switch change {
        case "context": report["committedTokens"] = f.profile.maximumContextTokens
        case "above-context": report["committedTokens"] = f.profile.maximumContextTokens + 1
        case "negative": report["committedTokens"] = -1
        case "boolean": report["committedTokens"] = true
        case "fractional": report["committedTokens"] = 3.5
        case "string": report["committedTokens"] = "17"
        case "null": report["committedTokens"] = NSNull()
        default: report["committedTokens"] = Int.max
        }
        let child = try f.launch("exit", report: report)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }

    @Test func frontierSeventeenIsProvisionalUntilActualExitWithinSelectedProfile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let profile = ClusterWorkerProfile(id: "smaller-calibration-fixture", vocabularySize: 512,
            maximumPromptTokens: 16, maximumOutputTokens: 2, maximumChunkTokens: 8, maximumContextTokens: 32)
        var report = f.report(); report["committedTokens"] = 17
        let child = try f.child("wait", report: report, profile: profile)
        try child.launch(); f.children.append(child)
        try f.wait { child.provisionalReport != nil || child.fault != nil }
        #expect(child.fault == nil)
        #expect(child.provisionalReport != nil)
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.release()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0))
        #expect(try !child.successfulReport().isEmpty)
    }

    @Test(arguments: [18, 31])
    func outOfProfileFrontierIsRefusedDespiteContextHeadroom(frontier: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let profile = ClusterWorkerProfile(id: "smaller-calibration-fixture", vocabularySize: 512,
            maximumPromptTokens: 16, maximumOutputTokens: 2, maximumChunkTokens: 8, maximumContextTokens: 32)
        #expect(frontier < profile.maximumContextTokens)
        var report = f.report(); report["committedTokens"] = frontier
        let child = try f.child("exit", report: report, profile: profile)
        try child.launch(); f.children.append(child)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.provisionalReport == nil)
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }

    @Test func normalizedConfigurationDiffersFromRawFileIdentity() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let normalized = f.normalizedConfiguration
        #expect(normalized != f.identity.configurationSHA256)
        var report = f.report(), quote = report["quote"] as! [String: Any]
        quote["configurationSHA256"] = normalized; report["quote"] = quote
        let child = try f.launch("wait", report: report)
        try f.wait { child.provisionalReport != nil || child.fault != nil }
        #expect(child.fault == nil)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.release()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(try !child.successfulReport().isEmpty)
    }

    @Test func rawConfigurationDigestCannotSubstituteForNormalizedDigest() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var report = f.report(), quote = report["quote"] as! [String: Any]
        quote["configurationSHA256"] = f.identity.configurationSHA256; report["quote"] = quote
        let child = try f.launch("exit", report: report)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }

    @Test func malformedExpectedNormalizedDigestRefusedBeforeLaunch() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for digest in ["", String(repeating: "2", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            #expect(throws: (any Error).self) {
                try f.child("exit", normalizedConfigurationSHA256: digest)
            }
        }
    }

    @Test func eofFromLiveChildIsNotExitProof() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.launch("eof-live")
        try f.wait { child.provisionalReport != nil }
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 100_000_000))
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.release(); #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0))
    }
    @Test func cooperativeCancelClosesInputAndCannotReturnSuccess() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.launch("wait"); try f.wait { child.provisionalReport != nil }
        child.cancel()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline)); #expect(child.sentSignals.isEmpty)
        #expect(child.termination == .exited(0))
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }
    @Test func fixedDeadlineWinsOverRenewalsAndSignalsRequireActualExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.launch("stubborn")
        try f.wait { child.renewalsQueued >= 2 }
        #expect(!child.observedExit)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline + 1_000_000_000))
        #expect(child.sentSignals == [SIGTERM, SIGKILL]); #expect(child.termination == .signalled(SIGKILL))
        #expect(throws: (any Error).self) { try child.successfulReport() }
        let signals = child.sentSignals; child.cancel(); #expect(child.sentSignals == signals)
    }
    @Test(arguments: ["multiple", "oversize", "stderr-flood", "no-report", "nonzero", "blocked-input"])
    func invalidOrBlockedPipesRetireBoundedly(mode: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.launch(mode)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline + 1_000_000_000))
        #expect(throws: (any Error).self) { try child.successfulReport() }
        #expect(child.diagnosticTail.count <= 65_536)
    }
    @Test(arguments: ["authorization", "environment", "configuration", "rank", "qualified", "exit", "unknown"])
    func reportBindingAndSafetyFlagsRefused(change: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        var report = f.report(), quote = report["quote"] as! [String: Any]
        switch change {
        case "authorization": quote["authorizationSHA256"] = String(repeating: "0", count: 64)
        case "environment": quote["executionEnvironmentSHA256"] = String(repeating: "0", count: 64)
        case "configuration": quote["configurationSHA256"] = String(repeating: "0", count: 64)
        case "rank": quote["rank"] = 1
        case "qualified": report["qualifiesMaximumEnvelope"] = true
        case "exit": report["requiresProcessExit"] = false
        default: report["ready"] = true
        }
        report["quote"] = quote
        let child = try f.launch("exit", report: report)
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }
    @Test func launchFailureIsNotObservedChildExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.child("exit", executable: f.root.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try child.launch() }
        #expect(child.termination == .launchFailed); #expect(!child.observedExit)
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000))
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }
    @Test func bootstrapUsesConcreteChildAndRefusesCrossedBinding() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2, deadline: end)
        defer { attachment.cancelCalibration() }
        let child = try f.child("bootstrap", deadline: end, attachment: attachment)
        try child.launch(); f.children.append(child)
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        let wrong = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 1, executionPlanSHA256: f.plan)
        #expect(throws: (any Error).self) { try attachment.runCalibration(child: child, binding: wrong, publish: { _, _ in }) }
        try attachment.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
            try attachment.acceptCalibrationReply(sequence: sequence, bytes: bytes + bytes)
        })
        try attachment.requireCalibrationCompleted()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(try !child.successfulReport().isEmpty)
    }
    @Test func refusedBootstrapReplyCancelsChildAndJoinsActualExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2, deadline: end)
        defer { attachment.cancelCalibration() }
        let child = try f.child("bootstrap", deadline: end, attachment: attachment)
        try child.launch(); f.children.append(child)
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        #expect(throws: (any Error).self) {
            try attachment.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
                try attachment.acceptCalibrationReply(sequence: sequence, bytes: Data(repeating: 0, count: bytes.count * 2))
            })
        }
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(throws: (any Error).self) { try child.successfulReport() }
        #expect(throws: (any Error).self) { try attachment.requireCalibrationCompleted() }
    }

    @Test func bootstrapOwnerSurvivesCallerDropUntilActualExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var attachment: ClusterOwnerBootstrapAttachment? = try .calibration(profile: .mesh2, deadline: end)
        weak var observed = attachment
        defer { observed = nil }
        let child = try f.child("bootstrap-wait", deadline: end, attachment: attachment)
        try child.launch(); f.children.append(child)
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        // Narrow scope ensures the callback's strong reference is also released.
        do {
            let owner = try #require(attachment)
            try owner.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
                try owner.acceptCalibrationReply(sequence: sequence, bytes: bytes + bytes)
            })
        }
        attachment = nil
        try f.wait { child.provisionalReport != nil }
        #expect(!child.observedExit); #expect(observed != nil)
        try f.release()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        try f.wait { observed == nil }
    }

    @Test func cancellingCompletedBootstrapStillCancelsLiveExperiment() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2, deadline: end)
        let child = try f.child("bootstrap-wait", deadline: end, attachment: attachment)
        try child.launch(); f.children.append(child)
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        try attachment.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
            try attachment.acceptCalibrationReply(sequence: sequence, bytes: bytes + bytes)
        })
        try f.wait { child.provisionalReport != nil }
        attachment.cancelCalibration()
        #expect(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.sentSignals.isEmpty)
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }


    /// Only used by the new long-value fixtures. Never block cleanup until the
    ///900s experiment end or delete scratch after an unobserved direct-child exit.
    private final class DeadlineCustody: @unchecked Sendable {
        let fixture: Fixture
        private var children: [ClusterCalibrationProcess] = []
        init() throws { fixture = try Fixture() }
        func track(_ child: ClusterCalibrationProcess) { children.append(child) }
        func cleanup() {
            let children = children // Frozen before the optional retention task.
            for child in children { child.cancel() }
            let observation = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            var joined = true
            for child in children {
                let actual = child.waitUntilExited(deadline: observation)
                #expect(actual, "Long-value fixture direct-child join unresolved; preserving scratch")
                joined = joined && actual
            }
            if joined { fixture.cleanup(); return }
            // self is the only post-test user of fixture; its original children
            // list stays empty. Actual supervisors retain themselves separately.
            Task { [self, children] in
                for child in children { _ = await child.waitUntilExited() }
                while !children.allSatisfy({ $0.observedExit }) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                fixture.cleanup()
                withExtendedLifetime(self) {}
            }
        }
    }

    @Test func shortCalibrationDefaultAndSocketCeilingStayUnchanged() throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2, deadline: deadline)
        defer { attachment.cancelCalibration() }
        #expect(attachment.deadlineUptimeNanoseconds == deadline)
        #expect(attachment.calibrationExperimentDeadline == deadline)
        #expect(ClusterOwnerBootstrapAttachment.maximumBootstrapNanoseconds == 300_000_000_000)
    }

    @Test func calibrationFactoryRejectsOverlongBootstrapReversedAndOverlongExperiment() throws {
        // Actual listener/factory construction, never clock advancement or a
        // sleep to the future value. Fresh now values avoid boundary arithmetic.
        var now = DispatchTime.now().uptimeNanoseconds
        #expect(throws: (any Error).self) {
            _ = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
                deadline: now + 900_000_000_000, experimentDeadline: now + 900_000_000_000)
        }
        now = DispatchTime.now().uptimeNanoseconds
        #expect(throws: (any Error).self) {
            _ = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
                deadline: now + 6_000_000_000, experimentDeadline: now + 5_000_000_000)
        }
        now = DispatchTime.now().uptimeNanoseconds
        #expect(throws: (any Error).self) {
            _ = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
                deadline: now + 5_000_000_000, experimentDeadline: now + 3_660_000_000_000)
        }
        now = DispatchTime.now().uptimeNanoseconds
        #expect(throws: (any Error).self) {
            _ = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
                deadline: now - 1, experimentDeadline: now + 900_000_000_000)
        }
    }

    @Test func boundedBootstrapFinishesBeforeActualLongExperimentChildExit() throws {
        let custody = try DeadlineCustody(); defer { custody.cleanup() }
        let f = custody.fixture
        let now = DispatchTime.now().uptimeNanoseconds
        let bootstrap = now + 5_000_000_000, experiment = now + 900_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
            deadline: bootstrap, experimentDeadline: experiment)
        defer { attachment.cancelCalibration() }
        #expect(attachment.deadlineUptimeNanoseconds == bootstrap)
        #expect(attachment.calibrationExperimentDeadline == experiment)
        let arguments = attachment.workerArguments
        let index = try #require(arguments.firstIndex(of: "--bootstrap-deadline-uptime-nanoseconds"))
        #expect(arguments[index + 1] == String(bootstrap))
        let child = try f.child("bootstrap-wait", deadline: experiment, attachment: attachment)
        try child.launch(); custody.track(child)
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        try attachment.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
            try attachment.acceptCalibrationReply(sequence: sequence, bytes: bytes + bytes)
        })
        try attachment.requireCalibrationCompleted()
        try f.wait { child.provisionalReport != nil }
        #expect(child.experimentDeadline == experiment && !child.observedExit)
        #expect(throws: (any Error).self) { _ = try child.successfulReport() }
        try f.release()
        try #require(child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        #expect(child.termination == .exited(0) && child.sentSignals.isEmpty)
        #expect(try !child.successfulReport().isEmpty)
        #expect(child.experimentDeadline == experiment) // Bootstrap did not shorten it.
    }

    @Test(arguments: ["experiment-earlier", "experiment-later", "identity", "profile", "rank", "plan"])
    func longExperimentStillRejectsCrossedActualChildBinding(change: String) throws {
        let custody = try DeadlineCustody(); defer { custody.cleanup() }
        let f = custody.fixture
        let now = DispatchTime.now().uptimeNanoseconds
        let bootstrap = now + 5_000_000_000, experiment = now + 900_000_000_000
        let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
            deadline: bootstrap, experimentDeadline: experiment)
        defer { attachment.cancelCalibration() }
        let child = try f.child("bootstrap-wait", deadline: experiment, attachment: attachment)
        try child.launch(); custody.track(child)
        let incarnation = UUID(), lease = UUID()
        let binding = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: incarnation, leaseID: lease,
            identity: f.identity, profile: f.profile, rank: 0, executionPlanSHA256: f.plan)
        if change.hasPrefix("experiment-") {
            let otherExperiment = change == "experiment-earlier" ? experiment - 1_000_000_000 : experiment + 1_000_000_000
            let crossed = try ClusterOwnerBootstrapAttachment.calibration(profile: .mesh2,
                deadline: bootstrap, experimentDeadline: otherExperiment)
            defer { crossed.cancelCalibration() }
            #expect(throws: (any Error).self) {
                try crossed.runCalibration(child: child, binding: binding, publish: { _, _ in })
            }
        } else {
            let identity = change == "identity" ? ClusterWorkerIdentity(membershipEpoch: f.identity.membershipEpoch,
                modelID: f.identity.modelID, artifactSHA256: String(repeating: "0", count: 64),
                configurationSHA256: f.identity.configurationSHA256, peers: f.identity.peers) : f.identity
            let profile = change == "profile" ? ClusterWorkerProfile(id: "crossed-calibration-fixture", vocabularySize: 512,
                maximumPromptTokens: 16, maximumOutputTokens: 16, maximumChunkTokens: 8, maximumContextTokens: 32) : f.profile
            let crossed = try ClusterOwnerBinding(clusterID: "fixture", ownerIncarnation: incarnation, leaseID: lease,
                identity: identity, profile: profile, rank: change == "rank" ? 1 : 0,
                executionPlanSHA256: change == "plan" ? String(repeating: "0", count: 64) : f.plan)
            #expect(throws: (any Error).self) {
                try attachment.runCalibration(child: child, binding: crossed, publish: { _, _ in })
            }
        }
        // Refusal must occur before attachment arming/child cancellation. The
        // SAME real child must still complete on the valid exact binding.
        try #require(child.fault == nil && !child.observedExit)
        try attachment.runCalibration(child: child, binding: binding, publish: { sequence, bytes in
            try attachment.acceptCalibrationReply(sequence: sequence, bytes: bytes + bytes)
        })
        try attachment.requireCalibrationCompleted()
        try f.wait { child.provisionalReport != nil }
        try f.release()
        try #require(child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        #expect(child.termination == .exited(0) && child.sentSignals.isEmpty)
        #expect(child.experimentDeadline == experiment)
        #expect(try !child.successfulReport().isEmpty)
    }

    @Test(arguments: ["complete", "split", "eof"])
    func closedRenewalInputIsProvisionalUntilDrainedReportAndActualZeroExit(order: String) throws {
        let f = try Fixture(); defer { try? f.release(); f.cleanup() }
        let mode = order == "split" ? "closed-input-delayed-report"
            : (order == "eof" ? "closed-input-eof" : "closed-input-wait")
        let child = try f.launch(mode)
        try f.wait { FileManager.default.fileExists(atPath: f.control + ".input-closed") }
        if order == "split" { #expect(child.provisionalReport == nil) }
        else { try f.wait { child.provisionalReport != nil } }
        // A queued renewal and a held real child force the closed-reader path.
        // No mocked write errno, exit observation or production test hook.
        try f.wait { child.renewalsQueued > 0 }
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 200_000_000))
        #expect(child.fault == nil)
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        let queued = child.renewalsQueued
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 150_000_000))
        #expect(child.renewalsQueued == queued) // EPIPE must stop requeue/lease extension.
        #expect(child.fault == nil)
        try f.release()
        try #require(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0))
        #expect(child.sentSignals.isEmpty)
        #expect(child.provisionalReport != nil)
        #expect(try !child.successfulReport().isEmpty)
    }

    @Test(arguments: ["no-report", "partial", "multiple", "malformed", "nonzero"])
    func closedRenewalInputCannotHideInvalidReportOrNonzeroExit(change: String) throws {
        let f = try Fixture(); defer { try? f.release(); f.cleanup() }
        var report = f.report()
        if change == "malformed" { report["requiresProcessExit"] = false }
        let mode = change == "malformed" ? "closed-input-wait" : "closed-input-" + change
        let child = try f.launch(mode, report: report)
        try f.wait { FileManager.default.fileExists(atPath: f.control + ".input-closed") }
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 150_000_000))
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.release()
        try #require(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(change == "nonzero" ? 9 : 0))
        #expect(throws: (any Error).self) { try child.successfulReport() }
        #expect(child.diagnosticTail.count <= 65_536)
    }

    @Test func cancellationAfterRenewalInputClosureStillRefusesActualZeroExit() throws {
        let f = try Fixture(); defer { try? f.release(); f.cleanup() }
        let child = try f.launch("closed-input-wait")
        try f.wait { FileManager.default.fileExists(atPath: f.control + ".input-closed")
            && child.provisionalReport != nil && child.renewalsQueued > 0 }
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 150_000_000))
        try #require(child.fault == nil)
        child.cancel()
        #expect(child.fault == .cancelled)
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.successfulReport() }
        try f.release()
        try #require(child.waitUntilExited(deadline: child.retirementDeadline))
        #expect(child.termination == .exited(0))
        #expect(child.sentSignals.isEmpty)
        #expect(child.fault == .cancelled)
        #expect(throws: (any Error).self) { try child.successfulReport() }
    }

    private struct ClosedInputLeaseReceipt: Decodable {
        let renewal: UInt64
        let ttlNanoseconds: UInt64
        let receivedAtUptimeNanoseconds: UInt64
        let closedAtUptimeNanoseconds: UInt64
    }

    @Test(arguments: ["lease", "experiment"])
    func closedRenewalInputKeepsLeaseAndFixedExperimentBounds(bound: String) throws {
        let f = try Fixture(); defer { try? f.release(); f.cleanup() }
        func wait(until end: UInt64, _ predicate: () -> Bool) throws {
            while !predicate(), DispatchTime.now().uptimeNanoseconds < end { usleep(5000) }
            try #require(predicate(), "Actual closed-input lease observation expired")
        }
        if bound == "lease" {
            // Genuine written-grant control: use real wire TTL and renewal cadence.
            // This case observes about one30s TTL; it never changes product clocks.
            let now = DispatchTime.now().uptimeNanoseconds
            let ttl = ClusterWorkerLease.ttlNanoseconds
            let cadence = ClusterWorkerLease.renewNanoseconds
            let child = try f.child("closed-input-after-renewal",
                deadline: now + ttl + 2 * cadence + 2_000_000_000,
                initialLeaseNanoseconds: ttl / 2, renewalInterval: cadence)
            try child.launch(); f.children.append(child)
            try wait(until: now + cadence + 2_000_000_000) {
                FileManager.default.fileExists(atPath: f.control + ".input-closed")
            }
            let receipt = try JSONDecoder().decode(ClosedInputLeaseReceipt.self,
                from: Data(contentsOf: URL(fileURLWithPath: f.control + ".input-closed")))
            try #require(receipt.renewal > 0 && receipt.ttlNanoseconds == ttl)
            try #require(receipt.receivedAtUptimeNanoseconds <= receipt.closedAtUptimeNanoseconds)
            try #require(child.renewalsQueued == receipt.renewal)
            // Witness a two-second no-new-grant interval AFTER actual input closure.
            // A subsequently failed grant would extend beyond our one-second margin.
            try #require(!child.waitUntilExited(
                deadline: receipt.closedAtUptimeNanoseconds + 2_000_000_000))
            try #require(child.renewalsQueued == receipt.renewal && child.fault == nil)
            try wait(until: receipt.closedAtUptimeNanoseconds + cadence + 2_000_000_000) {
                child.renewalsQueued > receipt.renewal || child.fault != nil
            }
            try #require(child.renewalsQueued == receipt.renewal + 1)
            #expect(child.fault == nil) // EPIPE is input closure, not a healthy-exit failure.
            // Every fully written grant preceded the child-closed receipt, so its
            // supervisor deadline is at most closedAt+actualTTL. No inferred grant.
            try wait(until: receipt.closedAtUptimeNanoseconds + ttl + 1_000_000_000) {
                child.fault != nil
            }
            #expect(child.fault == .deadline)
            #expect(!child.observedExit)
            #expect(throws: (any Error).self) { try child.successfulReport() }
            #expect(child.renewalsQueued == receipt.renewal + 1)
            try f.release()
            try #require(child.waitUntilExited(deadline: child.retirementDeadline))
            #expect(child.termination == .exited(0))
            #expect(child.sentSignals.isEmpty)
            #expect(child.fault == .deadline)
            #expect(throws: (any Error).self) { try child.successfulReport() }
        } else {
            let now = DispatchTime.now().uptimeNanoseconds
            let child = try f.child("closed-input-stubborn", deadline: now + 700_000_000,
                initialLeaseNanoseconds: 2_000_000_000)
            try child.launch(); f.children.append(child)
            try f.wait { FileManager.default.fileExists(atPath: f.control + ".input-closed") }
            try f.wait { child.fault != nil }
            #expect(child.fault == .deadline)
            #expect(throws: (any Error).self) { try child.successfulReport() }
            try #require(child.waitUntilExited(deadline: child.retirementDeadline + 1_000_000_000))
            #expect(child.termination == .signalled(SIGKILL))
            #expect(child.sentSignals == [SIGTERM, SIGKILL])
            #expect(throws: (any Error).self) { try child.successfulReport() }
        }
    }

}
