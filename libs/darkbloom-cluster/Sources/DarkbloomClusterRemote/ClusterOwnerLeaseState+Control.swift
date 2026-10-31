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
            try require(available && requests.count < lanes && requests[id] == nil && !seen.contains(id)
                        && ceiling > 0 && ceiling <= (readyCapacity ?? 0)
                        && remaining > 0 && remaining <= ClusterWorkerLimits.deadlineNanoseconds && !end.overflow,
                        "Reservation is unavailable or outside bounds")
            // The rank lease is renewed for as long as the request runs, so
            // the request's own deadline stands; there is no lifetime cap.
            let deadline = end.partialValue
            requests[id] = .init(id: id, ceiling: ceiling, deadline: deadline, charged: ceiling)
            seen.insert(id); seenOrder.append(id)
            if seenOrder.count > ClusterWorkerLimits.requestReplayWindow { seen.remove(seenOrder.removeFirst()) }
            action = .forwardReserve(id, localDeadlineUptimeNanoseconds: deadline)
        case .start(let id):
            try require(available && requests[id]?.phase == .admitted
                        && requests[id]?.cancelled == false, "Start requires current admitted request")
            requests[id]?.phase = .running; action = .forwardStart(id)
        case .cancel(let id, let reason):
            if lanes > 1, requests[id].map({ $0.phase == .retired }) ?? retiredRecently.contains(id) {
                // A lane's cancel crossed its retirement here (the owner
                // cancelled while the worker finished): the worker ignores it too.
                action = .forwardCancel(id, reason)
                break
            }
            try require(requests[id]?.releaseRequested == false
                        && requests[id]?.phase != .retired, "Cancel requires current unretired request")
            requests[id]?.cancelled = true; action = .forwardCancel(id, reason)
        case .release(let id):
            try require(requests[id]?.releaseRequested == false
                        && (requests[id]?.phase == .retired || nativeTerminal != nil),
                        "Release requires native retirement or actual native exit")
            requests[id]?.releaseRequested = true; action = .releaseRequestResources(id)
        case .shutdown:
            try require(!draining && requests.isEmpty && nativeTerminal == nil && childStarted,
                        "Shutdown requires no outstanding request resources")
            draining = true; readyCapacity = nil; action = .sendShutdown
        }
        nextControlSequence += 1
        return action
    }

    public mutating func observeAdmitted(requestID: UUID, reservedBytes: Int) throws {
        try require(!recoveryOnly && nativeTerminal == nil
                    && requests[requestID]?.phase == .reserving && reservedBytes > 0
                    && reservedBytes <= (requests[requestID]?.ceiling ?? 0), "Native admission differs")
        // A late admission after disconnect still records its real ownership;
        // quarantine remains and no start becomes possible.
        requests[requestID]?.charged = reservedBytes; requests[requestID]?.phase = .admitted
    }

    /// A refusal for memory, deadline or profile is the request's alone: the
    /// native worker gave its reservation back and stays available, so the
    /// charge is dropped and the lease keeps serving. A worker that refuses
    /// as unavailable is gone, and the lease is quarantined as before.
    public mutating func observeRefused(requestID: UUID, reason: ClusterWorkerRefusal = .unavailable) throws {
        try require(requests[requestID]?.phase == .reserving, "Unexpected refusal")
        guard reason != .unavailable else { quarantine(); return }
        requests[requestID] = nil
    }

    public mutating func observeRetired(requestID: UUID, retirement: ClusterWorkerRetirement) throws {
        try require(!recoveryOnly && childStarted && nativeTerminal == nil && requests[requestID] != nil
                    && requests[requestID]?.phase != .retired && requests[requestID]?.releaseRequested == false,
                    "Unexpected native retirement")
        // With lanes, a started lane retires on its own: cleanly even when a
        // cancel crossed its finish, or as cancelled when its worker dropped
        // it at a step boundary while the other lanes ran on.
        let laneRetired = lanes > 1 && requests[requestID]?.phase == .running
        if retirement == .clean {
            try require(requests[requestID]?.phase == .running
                        && (requests[requestID]?.cancelled == false || laneRetired),
                        "Clean retirement requires an uncancelled started request")
        }
        // A reservation the leader cancelled before it started (the pair's
        // other rank refused the request) is given back by the native worker,
        // which stays available. Any other abnormal retirement poisons the
        // native session's epoch; resource release cannot make it ready again.
        let givenBack = retirement == .cancelled && requests[requestID]?.cancelled == true
            && (requests[requestID]?.phase == .admitted || laneRetired)
        if retirement != .clean && !givenBack { quarantine() }
        requests[requestID]?.phase = .retired
        if lanes > 1 {
            retiredRecently.append(requestID)
            if retiredRecently.count > 64 { retiredRecently.removeFirst() }
        }
    }

    /// Called after the real request owner's exactly-once releaseResources returns.
    public mutating func observeRequestResourcesReleased(requestID: UUID) throws {
        try require(!recoveryOnly && requests[requestID]?.releaseRequested == true
                    && (requests[requestID]?.phase == .retired || nativeTerminal != nil), "Resource release was not requested")
        requests[requestID] = nil; releasedRequests += 1
    }

    /// No signal-sent, socket-EOF or elapsed-time variant exists here.
    public mutating func observeNativeTerminal(launchID id: UUID, termination: ClusterOwnerTermination) throws {
        try require(!recoveryOnly && !deviceLeaseReleased && nativeTerminal == nil && launchID == id,
                    "Terminal observation is for a different or already retired native child")
        switch termination {
        case .launchFailed:
            try require(launchAttempted && !childStarted && requests.isEmpty, "Launch failure follows a started child")
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
                    && requests.isEmpty, "Lease already attempted a native launch")
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
