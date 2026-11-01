import CoreFoundation
import Darwin
import Foundation
import DarkbloomClusterProtocol

/// One private experiment, never a serving worker. A report is provisional until
/// the direct child actually exits; neither this object nor a report refunds a pair.
public final class ClusterCalibrationProcess: @unchecked Sendable {
    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    public let experimentDeadline: UInt64
    public let retirement: ClusterWorkerSignalPolicy
    // Digest of the independently authenticated exact authorization payload;
    // it binds epoch/artifact/request as well as fields repeated by the report.
    // Never derive this expected digest from the incoming report itself.
    private let authorizationSHA256: String
    // Normalized text-configuration digest from the authoritative plan quotation,
    // distinct from the raw config.json digest in expectedIdentity.
    private let normalizedConfigurationSHA256: String
    private let environmentSHA256: String
    private let process = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private let exitObserver = ClusterProcessExit(), finished = WorkerCompletion()
    private let wakeup: WorkerPumpWakeup
    private let lock = NSLock()
    private var launched = false, pid: Int32?
    private var birthTime: Double?
    private var terminal: ClusterWorkerProcessTermination?
    private var failure: ClusterWorkerOwnerError?
    private var report: Data?
    private var stderrTail = Data()
    private var signals: [Int32] = []
    private var renewal: UInt64 = 0, nextRenewal: UInt64 = 0
    private var leaseDeadline: UInt64
    private var outgoing: [(data: Data, offset: Int, leaseGrant: UInt64?)] = []
    private let renewalInterval: UInt64

    public var launchedProcessIdentifier: Int32? { lock.withLock { pid } }
    public var termination: ClusterWorkerProcessTermination? { lock.withLock { terminal } }
    public var observedExit: Bool { lock.withLock { pid != nil && terminal != nil } }
    public var provisionalReport: Data? { lock.withLock { report } }
    public var fault: ClusterWorkerOwnerError? { lock.withLock { failure } }
    public var diagnosticTail: Data { lock.withLock { stderrTail } }
    public var sentSignals: [Int32] { lock.withLock { signals } }
    public var renewalsQueued: UInt64 { lock.withLock { renewal } }
    public var retirementDeadline: UInt64 { experimentDeadline + retirement.allowanceNanoseconds }

    public convenience init(launch: ClusterWorkerLaunch, expectedIdentity: ClusterWorkerIdentity,
                            rank: Int, profile: ClusterWorkerProfile, executionPlanSHA256: String,
                            authorizationSHA256: String, normalizedConfigurationSHA256: String, environmentSHA256: String, initialLeaseDeadline: UInt64,
                            experimentDeadline: UInt64, plannedBytes: UInt64) throws {
        try self.init(launch: launch, expectedIdentity: expectedIdentity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256, authorizationSHA256: authorizationSHA256, normalizedConfigurationSHA256: normalizedConfigurationSHA256, environmentSHA256: environmentSHA256,
            initialLeaseDeadline: initialLeaseDeadline, experimentDeadline: experimentDeadline,
            retirement: .sized(plannedBytes: plannedBytes, childEndsItselfAtStartupDeadline: true),
            renewalInterval: ClusterWorkerLease.renewNanoseconds)
    }

    // CPU fixtures may shorten signal/renewal timings; production always uses sized policy.
    init(launch: ClusterWorkerLaunch, expectedIdentity: ClusterWorkerIdentity, rank: Int,
         profile: ClusterWorkerProfile, executionPlanSHA256: String, authorizationSHA256: String, normalizedConfigurationSHA256: String, environmentSHA256: String,
         initialLeaseDeadline: UInt64, experimentDeadline: UInt64,
         retirement: ClusterWorkerSignalPolicy, renewalInterval: UInt64) throws {
        _ = try ClusterWorkerSession(identity: expectedIdentity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256)
        let now = DispatchTime.now().uptimeNanoseconds
        guard launch.executable.isFileURL, launch.executable.path.hasPrefix("/"),
              launch.arguments.count <= 64, launch.arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              launch.environment.count <= 128,
              launch.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
                  && !$0.value.contains("\0") && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 }),
              normalizedConfigurationSHA256.utf8.count == 64,
              normalizedConfigurationSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              environmentSHA256.utf8.count == 64,
              environmentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              authorizationSHA256.utf8.count == 64,
              authorizationSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              initialLeaseDeadline > now, initialLeaseDeadline - now <= ClusterWorkerLease.maximumNanoseconds,
              experimentDeadline > now, experimentDeadline - now <= ClusterWorkerLimits.deadlineNanoseconds,
              retirement.isBounded, retirement.childEndsItselfAtStartupDeadline,
              !experimentDeadline.addingReportingOverflow(retirement.allowanceNanoseconds).overflow,
              renewalInterval > 0, renewalInterval <= ClusterWorkerLease.renewNanoseconds,
              let credential = launch.initialInput, credential.last == 10,
              credential.count <= 4096, credential.filter({ $0 == 10 }).count == 1 else {
            throw ClusterWorkerOwnerError.invalid("Invalid calibration launch")
        }
        let trust = try ClusterWorkerCodec.decodeDataPlaneTrust(credential)
        guard trust.membershipEpoch == expectedIdentity.membershipEpoch, trust.rank == rank else {
            throw ClusterWorkerOwnerError.invalid("Calibration credential differs from child identity")
        }
        self.expectedIdentity = expectedIdentity; expectedProfile = profile; self.rank = rank
        self.executionPlanSHA256 = executionPlanSHA256; self.authorizationSHA256 = authorizationSHA256; self.environmentSHA256 = environmentSHA256
        self.normalizedConfigurationSHA256 = normalizedConfigurationSHA256
        self.experimentDeadline = experimentDeadline; self.retirement = retirement
        self.renewalInterval = renewalInterval; leaseDeadline = initialLeaseDeadline
        wakeup = try WorkerPumpWakeup()
        outgoing = [(credential, 0, nil)]
        process.executableURL = launch.executable; process.arguments = launch.arguments; process.environment = launch.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, diagnostics.fileHandleForReading] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ClusterWorkerOwnerError.invalid("Cannot bound calibration pipes") }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClusterWorkerOwnerError.invalid("Cannot suppress calibration SIGPIPE")
        }
    }

    public func launch() throws {
        try lock.withLock {
            guard !launched, failure == nil else { throw ClusterWorkerOwnerError.closed }
            launched = true; nextRenewal = DispatchTime.now().uptimeNanoseconds + renewalInterval
            do { try exitObserver.run(process); pid = process.processIdentifier; birthTime = ClusterProcessTable.startTime(of: process.processIdentifier) }
            catch {
                terminal = .launchFailed; failure = .closed
                for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                               output.fileHandleForWriting, diagnostics.fileHandleForReading, diagnostics.fileHandleForWriting] {
                    try? handle.close()
                }
                wakeup.closeAfterPolling(); finished.complete(); throw error
            }
        }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "darkbloom.calibration.io.\(rank)").async { self.pump() }
    }

    public func cancel() { fail(.cancelled) }
    public func waitUntilExited(deadline: UInt64) -> Bool { finished.wait(until: deadline) && observedExit }
    public func waitUntilExited() async -> Bool { await finished.value(); return observedExit }
    /// No result until the pipe has been drained and actual exit observed.
    public func successfulReport() throws -> Data {
        try lock.withLock {
            if let failure { throw failure }
            guard finished.isComplete, terminal == .exited(0), let report else { throw ClusterWorkerOwnerError.closed }
            return report
        }
    }
    private func fail(_ error: ClusterWorkerOwnerError) {
        lock.withLock { guard terminal == nil else { return }; if failure == nil { failure = error }; outgoing.removeAll() }
        wakeup.signal()
    }
    private func renew(now: UInt64) {
        lock.withLock {
            guard failure == nil, now < experimentDeadline, now < leaseDeadline,
                  now >= nextRenewal, outgoing.count < 2 else { return }
            // The ordinary rank lease remains renewable; the independent experiment
            // deadline is never changed and takes precedence over every renewal.
            guard let frame = try? ClusterWorkerLeaseRenewal(membershipEpoch: expectedIdentity.membershipEpoch,
                    renewal: renewal + 1), let bytes = try? ClusterWorkerCodec.encode(frame) else { return }
            // A queued/failed renewal is not a written grant. Preserve the last
            // fully written lease if the child closes input during finalization.
            outgoing.append((bytes, 0, now + ClusterWorkerLease.ttlNanoseconds)); renewal += 1
            nextRenewal = now + renewalInterval
        }
    }

    private func acceptReport(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["nativeHardCapBytes", "hostBudgetBytes", "osHeadroomBytes", "quote",
                  "observations", "committedTokens", "qualifiesMaximumEnvelope", "requiresProcessExit"],
              let qualifies = object["qualifiesMaximumEnvelope"] as? NSNumber,
              CFGetTypeID(qualifies) == CFBooleanGetTypeID(), !qualifies.boolValue,
              let exits = object["requiresProcessExit"] as? NSNumber,
              CFGetTypeID(exits) == CFBooleanGetTypeID(), exits.boolValue,
              let quote = object["quote"] as? [String: Any],
              Set(quote.keys) == ["authorizationSHA256", "descriptorSHA256", "cut", "rank", "nativeBytes", "hostBytes",
                  "loadCapacityBytes", "requestCapacityBytes", "inventorySHA256", "configurationSHA256",
                  "numericalPolicySHA256", "executionEnvironmentSHA256", "qualifiesMaximumEnvelope"],
              let quoteQualified = quote["qualifiesMaximumEnvelope"] as? NSNumber,
              CFGetTypeID(quoteQualified) == CFBooleanGetTypeID(), !quoteQualified.boolValue,
              quote["authorizationSHA256"] as? String == authorizationSHA256,
              quote["configurationSHA256"] as? String == normalizedConfigurationSHA256,
              quote["executionEnvironmentSHA256"] as? String == environmentSHA256,
              let reportRank = quote["rank"] as? NSNumber, CFGetTypeID(reportRank) != CFBooleanGetTypeID(),
              reportRank.intValue == rank, reportRank.doubleValue == Double(rank),
              let observations = object["observations"] as? [[String: Any]], observations.count <= 1024 else {
            throw ClusterWorkerOwnerError.invalid("Unknown or unbound calibration report")
        }
        func nonnegativeInteger(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return false }
            return number.doubleValue.rounded(.towardZero) == number.doubleValue
        }
        let maximumPositions = expectedProfile.maximumPromptTokens.addingReportingOverflow(
            expectedProfile.maximumOutputTokens)
        guard !maximumPositions.overflow, maximumPositions.partialValue > 0 else {
            throw ClusterWorkerOwnerError.invalid("Invalid calibration frontier bound")
        }
        let maximumFrontier = maximumPositions.partialValue - 1
        guard ["nativeHardCapBytes", "hostBudgetBytes", "osHeadroomBytes", "committedTokens"].allSatisfy({ nonnegativeInteger(object[$0]) }),
              // Native frontier includes prompt plus decode forwards, bounded by
              // this profile. The consumer requires the exact signed P + O - 1.
              let committed = object["committedTokens"] as? NSNumber,
              committed.intValue <= maximumFrontier,
              committed.intValue < expectedProfile.maximumContextTokens,
              ["cut", "nativeBytes", "hostBytes", "loadCapacityBytes", "requestCapacityBytes"].allSatisfy({ nonnegativeInteger(quote[$0]) }),
              observations.allSatisfy({ observation in
                  guard Set(observation.keys) == ["phase", "nativeActiveBytes", "nativePeakBytes", "host"],
                        let phase = observation["phase"] as? String, !phase.isEmpty, phase.utf8.count <= 128,
                        nonnegativeInteger(observation["nativeActiveBytes"]), nonnegativeInteger(observation["nativePeakBytes"]),
                        let host = observation["host"] as? [String: Any],
                        Set(host.keys) == ["mallocBytes", "processFootprintBytes"] else { return false }
                  return nonnegativeInteger(host["mallocBytes"]) && nonnegativeInteger(host["processFootprintBytes"])
              }) else { throw ClusterWorkerOwnerError.invalid("Malformed calibration observations") }
        // The consumer must still validate the detailed quotation/observations.
        // Transport acceptance is not maximum-envelope qualification or a refund.
        try lock.withLock {
            guard report == nil, failure == nil else { throw ClusterWorkerOwnerError.invalid("Multiple calibration reports") }
            report = data
        }
    }

    /// Never signal an integer PID recovered from a prior process lifetime.
    /// If birth identity cannot be observed, retain unresolved ownership instead.
    private func ownsRunningChild() -> Bool {
        guard !exitObserver.hasExited, process.isRunning,
              let identity = lock.withLock({ pid.flatMap { pid in birthTime.map { (pid, $0) } } }) else { return false }
        return ClusterProcessTable.startTime(of: identity.0) == identity.1
    }

    private func pump() {
        let inFD = input.fileHandleForWriting.fileDescriptor
        var inputOpen = true, stdoutOpen = true, stderrOpen = true
        var credentialWritten = false // Pump-local: only a complete first line counts.
        var stdout = Data(), stdoutBytes = 0, stderrBytes = 0, sawReport = false
        var termAt: UInt64?, killSent = false, exitAt: UInt64?
        defer {
            wakeup.closeAfterPolling()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostics.fileHandleForReading.close()
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= experimentDeadline || now >= lock.withLock({ leaseDeadline }) { fail(.deadline) }
            if inputOpen { renew(now: now) }
            if fault != nil {
                if inputOpen { try? input.fileHandleForWriting.close(); inputOpen = false }
                if ownsRunningChild(), now >= experimentDeadline,
                   now - experimentDeadline >= retirement.terminateMarginNanoseconds {
                    if termAt == nil { process.terminate(); termAt = now; lock.withLock { signals.append(SIGTERM) } }
                    if let sent = termAt, !killSent, ownsRunningChild(), now - sent >= retirement.killMarginNanoseconds {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL); killSent = true; lock.withLock { signals.append(SIGKILL) }
                    }
                }
            }
            var fds = [pollfd(fd: stdoutOpen ? output.fileHandleForReading.fileDescriptor : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrOpen ? diagnostics.fileHandleForReading.fileDescriptor : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputOpen && lock.withLock({ !outgoing.isEmpty }) ? inFD : -1, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: wakeup.readDescriptor, events: Int16(POLLIN), revents: 0)]
            let count = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 20) }
            if count < 0 && errno != EINTR { fail(.closed) }
            if fds[3].revents != 0 && !wakeup.drain() { fail(.closed) }
            for i in 0..<2 where fds[i].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(fds[i].fd, &buffer, buffer.count)
                if n > 0 {
                    let bytes = Data(buffer.prefix(n))
                    if i == 0 {
                        stdoutBytes += n
                        do {
                            guard !sawReport, stdoutBytes <= 65_537 else { throw ClusterWorkerOwnerError.invalid("Excess calibration stdout") }
                            stdout.append(bytes)
                            if let newline = stdout.firstIndex(of: 10) {
                                guard newline == stdout.index(before: stdout.endIndex), newline > stdout.startIndex else {
                                    throw ClusterWorkerOwnerError.invalid("Multiple calibration records")
                                }
                                try acceptReport(Data(stdout[..<newline])); sawReport = true; stdout.removeAll()
                            }
                        } catch { fail(.invalid("Invalid or excessive calibration stdout")); stdoutOpen = false }
                    } else {
                        stderrBytes += n
                        lock.withLock { stderrTail.append(bytes); if stderrTail.count > 65_536 { stderrTail.removeFirst(stderrTail.count - 65_536) } }
                        if stderrBytes > 1 << 20 { fail(.invalid("Calibration stderr exceeded bound")); stderrOpen = false }
                    }
                } else if n == 0 {
                    if i == 0 { stdoutOpen = false; if !sawReport || !stdout.isEmpty { fail(.invalid("Missing or partial calibration report")) } }
                    else { stderrOpen = false }
                } else if errno != EINTR && errno != EAGAIN {
                    fail(.closed); if i == 0 { stdoutOpen = false } else { stderrOpen = false }
                }
            }
            if fds[2].revents != 0 {
                var closedRenewalInput = false
                lock.withLock {
                    guard failure == nil, !outgoing.isEmpty else { return }
                    let item = outgoing[0]
                    let n = item.data.withUnsafeBytes { Darwin.write(inFD, $0.baseAddress!.advanced(by: item.offset), item.data.count - item.offset) }
                    if n > 0 {
                        outgoing[0].offset += n
                        if outgoing[0].offset == item.data.count {
                            if let grant = item.leaseGrant { leaseDeadline = grant }
                            else { credentialWritten = true }
                            outgoing.removeFirst()
                        }
                    } else if n < 0 {
                        let code = errno
                        if code == EPIPE && credentialWritten {
                            // A finite child can close stdin before its actual
                            // exit notification. This ends renewals only, never
                            // supplies a report/exit receipt or clears a fault.
                            outgoing.removeAll(); closedRenewalInput = true
                        } else if code != EAGAIN && code != EINTR {
                            failure = .closed; outgoing.removeAll()
                        }
                    }
                }
                if closedRenewalInput {
                    inputOpen = false
                    try? input.fileHandleForWriting.close()
                }
            }
            if exitObserver.hasExited {
                if exitAt == nil { exitAt = DispatchTime.now().uptimeNanoseconds }
                // Descendants retaining a pipe cannot hold the owner indefinitely.
                if (stdoutOpen || stderrOpen) && DispatchTime.now().uptimeNanoseconds - exitAt! < 1_000_000_000 { continue }
                lock.withLock {
                    terminal = process.terminationReason == .exit ? .exited(process.terminationStatus) : .signalled(process.terminationStatus)
                    if !sawReport && failure == nil { failure = .invalid("Child exited without a report") }
                    if (stdoutOpen || !stdout.isEmpty) && failure == nil { failure = .invalid("Report stream did not finish") }
                    outgoing.removeAll()
                }
                finished.complete(); return
            }
        }
    }
}
