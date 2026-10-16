import Foundation
import DarkbloomClusterProtocol

extension ClusterOwnerLeaseState {
    /// The transport must authenticate and bound a frame before invoking this.
    /// On any thrown error, retain ownership and service requiresNativeFence.
    public mutating func accept(_ frame: ClusterOwnerControlFrame, now: UInt64) throws -> ClusterOwnerAction {
        try clock(now)
        try require(!recoveryOnly && !deviceLeaseReleased && frame.route == binding.route
                    && frame.sequence == nextControlSequence && nextControlSequence < UInt64.max,
                    "Wrong owner route, replay or closed lease")
        let action: ClusterOwnerAction
        switch frame.control {
        case .reserve(let id, let ceiling, let remaining):
            let end = now.addingReportingOverflow(remaining)
            try require(available && request == nil && !seen.contains(id)
                        && ceiling > 0 && ceiling <= (readyCapacity ?? 0)
                        && remaining > 0 && remaining <= ClusterWorkerLimits.deadlineNanoseconds && !end.overflow,
                        "Reservation is unavailable or outside bounds")
            // The rank lease is renewed for as long as the request runs, so
            // the request's own deadline stands; there is no lifetime cap.
            let deadline = end.partialValue
            request = .init(id: id, ceiling: ceiling, deadline: deadline, charged: ceiling)
            seen.insert(id); seenOrder.append(id)
            if seenOrder.count > ClusterWorkerLimits.requestReplayWindow { seen.remove(seenOrder.removeFirst()) }
            action = .forwardReserve(id, localDeadlineUptimeNanoseconds: deadline)
        case .start(let id):
            try require(available && request?.id == id && request?.phase == .admitted
                        && request?.cancelled == false, "Start requires current admitted request")
            request?.phase = .running; action = .forwardStart(id)
        case .cancel(let id, let reason):
            try require(request?.id == id && request?.releaseRequested == false
                        && request?.phase != .retired, "Cancel requires current unretired request")
            request?.cancelled = true; action = .forwardCancel(id, reason)
        case .release(let id):
            try require(request?.id == id && request?.releaseRequested == false
                        && (request?.phase == .retired || nativeTerminal != nil),
                        "Release requires native retirement or actual native exit")
            request?.releaseRequested = true; action = .releaseRequestResources(id)
        case .shutdown:
            try require(!draining && request == nil && nativeTerminal == nil && childStarted,
                        "Shutdown requires no outstanding request resources")
            draining = true; readyCapacity = nil; action = .sendShutdown
        }
        nextControlSequence += 1
        return action
    }

    public mutating func observeAdmitted(requestID: UUID, reservedBytes: Int) throws {
        try require(!recoveryOnly && nativeTerminal == nil && request?.id == requestID
                    && request?.phase == .reserving && reservedBytes > 0
                    && reservedBytes <= (request?.ceiling ?? 0), "Native admission differs")
        // A late admission after disconnect still records its real ownership;
        // quarantine remains and no start becomes possible.
        request?.charged = reservedBytes; request?.phase = .admitted
    }

    /// A refusal for memory, deadline or profile is the request's alone: the
    /// native worker gave its reservation back and stays available, so the
    /// charge is dropped and the lease keeps serving. A worker that refuses
    /// as unavailable is gone, and the lease is quarantined as before.
    public mutating func observeRefused(requestID: UUID, reason: ClusterWorkerRefusal = .unavailable) throws {
        try require(request?.id == requestID && request?.phase == .reserving, "Unexpected refusal")
        guard reason != .unavailable else { quarantine(); return }
        request = nil
    }

    public mutating func observeRetired(requestID: UUID, retirement: ClusterWorkerRetirement) throws {
        try require(!recoveryOnly && childStarted && nativeTerminal == nil && request?.id == requestID
                    && request?.phase != .retired && request?.releaseRequested == false,
                    "Unexpected native retirement")
        if retirement == .clean {
            try require(request?.phase == .running && request?.cancelled == false,
                        "Clean retirement requires an uncancelled started request")
        }
        // A reservation the leader cancelled before it started (the pair's
        // other rank refused the request) is given back by the native worker,
        // which stays available. Any other abnormal retirement poisons the
        // native session's epoch; resource release cannot make it ready again.
        let givenBack = retirement == .cancelled && request?.phase == .admitted && request?.cancelled == true
        if retirement != .clean && !givenBack { quarantine() }
        request?.phase = .retired
    }

    /// Called after the real request owner's exactly-once releaseResources returns.
    public mutating func observeRequestResourcesReleased(requestID: UUID) throws {
        try require(!recoveryOnly && request?.id == requestID && request?.releaseRequested == true
                    && (request?.phase == .retired || nativeTerminal != nil), "Resource release was not requested")
        request = nil; releasedRequests += 1
    }

    /// No signal-sent, socket-EOF or elapsed-time variant exists here.
    public mutating func observeNativeTerminal(launchID id: UUID, termination: ClusterOwnerTermination) throws {
        try require(!recoveryOnly && !deviceLeaseReleased && nativeTerminal == nil && launchID == id,
                    "Terminal observation is for a different or already retired native child")
        switch termination {
        case .launchFailed:
            try require(launchAttempted && !childStarted && request == nil, "Launch failure follows a started child")
        case .exited:
            try require(childStarted, "Exit precedes native process start")
        case .signalled(let signal):
            try require(childStarted && signal > 0, "Invalid native signal termination")
        case .neverLaunched:
            try require(false, "Never-launched terminal cannot describe an attempted child")
        }
        nativeTerminal = .init(launchID: id, termination: termination)
        draining = true; readyCapacity = nil
    }

    public mutating func closeBeforeLaunch() throws {
        try require(!recoveryOnly && !deviceLeaseReleased && !launchAttempted && nativeTerminal == nil
                    && request == nil, "Lease already attempted a native launch")
        nativeTerminal = .init(launchID: nil, termination: .neverLaunched)
        draining = true
    }

    /// Called only after the adapter clears its durable ownership record and
    /// releases the actual device lease. Recovered unresolved ownership is barred.
    public mutating func observeDeviceLeaseReleased() throws {
        try require(canReleaseDeviceLease, "Device lease still owns a native child or request")
        deviceLeaseReleased = true
    }
}
