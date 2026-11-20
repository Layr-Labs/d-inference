/// ProviderLoop -- request resume v1 (coordinator failover, phase 5).
///
/// A request whose sealed body carries a resume id is resumable. When the
/// connection drops, it is held: its generation runs on and its output is
/// kept (`ResumableResponse`), for `requestResumeWindow` after the disconnect
/// or after the generation's end, whichever is later. A surviving
/// coordinator's dispatch of the same request takes the whole answer when
/// every check of `RequestResume.refusal` passes; anything else runs as new.
/// At the end of the window an unattached held request is cancelled with the
/// cause `connectionLost` and its output dropped, unpaid. The held request
/// keeps its generation's request id inside this loop, so its slot, capacity
/// and power accounting stay as they were; on the wire that id is forgotten.

import Foundation

/// One resumable request of this Mac, by its generation's request id.
struct ResumableRequestEntry {
    let identity: RequestResume.Identity
    let route: ResumableResponse
    /// Admission order: `register` lists the newest.
    let sequence: UInt64
    /// When its connection dropped; nil while connected.
    var heldSince: ContinuousClock.Instant?
    /// The request id of the dispatch that took its output.
    var attachedAs: String?
    /// Its generation's task has ended (`finishInflightRequest`).
    var taskFinished = false
}

extension ProviderLoop {
    /// The most requests held at once: 64, and never more than this Mac runs
    /// at once.
    var resumableRequestCap: Int {
        let concurrent = modelSlots.keys.reduce(0) { $0 + engineV2MaxConcurrent(forModel: $1) }
        return max(1, min(RequestResume.maxHeldRequests, concurrent))
    }

    /// The connection-control reader saw the connection end at `instant`.
    /// The work loop's `handleCoordinatorDisconnected` for it holds from
    /// this instant. Each `.disconnected` adds one stamp and its handler
    /// takes it, so the queue stays as long as the disconnects not yet
    /// handled; past 64 the newest stamps are not kept (their handlers hold
    /// from when they run).
    func noteCoordinatorDisconnect(at instant: ContinuousClock.Instant = .now) {
        guard coordinatorDisconnectStamps.count < RequestResume.maxHeldRequests else { return }
        coordinatorDisconnectStamps.append(instant)
    }

    /// Makes the generation of `requestId` resumable; nil when another
    /// request already carries its resume id (a second request with the same
    /// id runs as new, and is not resumable).
    func registerResumableRequest(
        requestId: String, identity: RequestResume.Identity, send: SendHandle
    ) -> ResumableResponse? {
        guard resumableRequestByResumeID[identity.resumeID] == nil, resumableRequests[requestId] == nil
        else { return nil }
        let route = ResumableResponse(
            requestId: requestId, send: send, maxBufferedBytes: requestResumeMaxBufferedBytes)
        resumableRequestSequence += 1
        resumableRequests[requestId] = ResumableRequestEntry(
            identity: identity, route: route, sequence: resumableRequestSequence)
        resumableRequestByResumeID[identity.resumeID] = requestId
        publishResumableRequests()
        return route
    }

    /// A frame that names a held or attached request's own id is a copy of a
    /// dead coordinator's dispatch, and one that names the dispatch that took
    /// a held answer is a copy of that dispatch. Neither gets an answer: the
    /// id is taken here.
    func namesHeldRequest(_ requestId: String) -> Bool {
        if attachedResumeRequests[requestId] != nil { return true }
        guard let entry = resumableRequests[requestId] else { return false }
        return entry.heldSince != nil || entry.attachedAs != nil
    }

    /// Gives a held request's output to the dispatch `requestId` when it
    /// carries the held resume id and passes every check. Returns whether it
    /// did; false runs the dispatch as new.
    func attachHeldRequest(
        requestId: String, candidate: RequestResume.Identity, cacheReceiptNonce: String?,
        signature: CoordinatorSignatureCheck, send: SendHandle
    ) -> Bool {
        guard let heldID = resumableRequestByResumeID[candidate.resumeID],
              var entry = resumableRequests[heldID], entry.heldSince != nil, entry.attachedAs == nil
        else { return false }
        if let refusal = RequestResume.refusal(
            held: entry.identity, request: candidate, cacheReceiptNonce: cacheReceiptNonce,
            signature: signature, clusterRequest: isClusterMember)
        {
            logger.info("[\(requestId)] Runs as new: it does not match the held request (\(refusal.rawValue))")
            return false
        }
        guard let sharedKey = try? keyPair.precomputeSharedKey(recipientPublicKey: candidate.sessionKey) else {
            return false
        }
        // Sealed to the new dispatch's session key, with this Mac's static
        // key as sender, from the first chunk; receipts and the response hash
        // bind the new request id.
        let binding = ResumableResponse.Binding(
            requestId: requestId,
            sealer: ResponseFrameSealer(keyPair: keyPair, sharedKey: sharedKey),
            send: send, resumed: true)
        let outcome = entry.route.attach(binding) {
            send.send(.inferenceAccepted(requestId: requestId))
        }
        guard outcome != .refused else { return false }
        logger.info("[\(requestId)] Took the output of the request held since the connection dropped (\(heldID))")
        resumableRequestByResumeID.removeValue(forKey: candidate.resumeID)
        if outcome == .finished && entry.taskFinished {
            resumableRequests.removeValue(forKey: heldID)
        } else {
            entry.heldSince = nil
            entry.attachedAs = requestId
            resumableRequests[heldID] = entry
            attachedResumeRequests[requestId] = heldID
        }
        publishResumableRequests()
        rescheduleHeldRequestExpiry()
        return true
    }

    /// The connection dropped: holds each resumable request whose generation
    /// runs or whose answer is kept, the newest up to the cap, and returns
    /// their request ids. Every other one is dropped, to be cancelled as
    /// every request was before.
    func holdResumableRequests(at now: ContinuousClock.Instant) -> Set<String> {
        var candidates: [(id: String, sequence: UInt64)] = []
        for (id, entry) in resumableRequests where entry.attachedAs == nil {
            guard entry.heldSince != nil || inflightTasks[id] != nil, entry.route.hold() else { continue }
            candidates.append((id, entry.sequence))
        }
        let kept = Set(candidates.sorted { $0.sequence > $1.sequence }.prefix(resumableRequestCap).map { $0.id })
        for (id, entry) in resumableRequests {
            if kept.contains(id) {
                if entry.heldSince == nil { resumableRequests[id]?.heldSince = now }
            } else {
                entry.route.close()
                dropResumableRequest(id)
            }
        }
        publishResumableRequests()
        rescheduleHeldRequestExpiry()
        return kept
    }

    /// The generation of `requestId` ended. A held request keeps its answer
    /// for a dispatch; any other entry ends with it.
    func resumableRequestFinished(_ requestId: String) {
        guard let entry = resumableRequests[requestId] else { return }
        if entry.heldSince != nil, entry.route.isHeld {
            resumableRequests[requestId]?.taskFinished = true
            return
        }
        dropResumableRequest(requestId)
        publishResumableRequests()
    }

    /// The request a coordinator cancel for `requestId` stops: for an
    /// attached dispatch, the generation it took. Nil for a held or attached
    /// request's own id, which no coordinator holds any more.
    func coordinatorCancelTarget(_ requestId: String) -> String? {
        if let generation = attachedResumeRequests[requestId] { return generation }
        return namesHeldRequest(requestId) ? nil : requestId
    }

    /// Cancels each held request whose window ended at `now` and drops its
    /// output: nothing took it, and nothing pays for it.
    func expireHeldRequests(now: ContinuousClock.Instant = .now) async {
        for id in Array(resumableRequests.keys) {
            guard let entry = resumableRequests[id], let since = entry.heldSince else { continue }
            let ended = entry.route.endedAt ?? since
            guard !entry.route.isHeld || now >= max(since, ended) + requestResumeWindow else { continue }
            entry.route.close()
            dropResumableRequest(id)
            if inflightTasks[id] != nil || requestToModel[id] != nil {
                logger.info("[\(id)] No dispatch took the held request within the resume window; it is cancelled")
                await handleCancellation(requestId: id, receivedFromCoordinator: false, localCause: .connectionLost)
            }
        }
        publishResumableRequests()
        if !resumableRequests.values.contains(where: { $0.heldSince != nil }) {
            heldRequestExpiryTask?.cancel()
            heldRequestExpiryTask = nil
        }
    }

    /// Drops every resumable request but `kept` (a stop of this Mac keeps
    /// none).
    func closeResumableRequests(except kept: Set<String>) {
        for (id, entry) in resumableRequests where !kept.contains(id) {
            entry.route.close()
            dropResumableRequest(id)
        }
        publishResumableRequests()
        if kept.isEmpty {
            heldRequestExpiryTask?.cancel()
            heldRequestExpiryTask = nil
        }
    }

    /// The resume ids the next `register` lists, newest first.
    func publishResumableRequests() {
        state.resumableRequests = resumableRequests.values
            .filter { $0.attachedAs == nil }
            .sorted { $0.sequence > $1.sequence }
            .prefix(resumableRequestCap)
            .map(\.identity.resumeID)
    }

    // MARK: - Private

    private func dropResumableRequest(_ requestId: String) {
        guard let entry = resumableRequests.removeValue(forKey: requestId) else { return }
        if resumableRequestByResumeID[entry.identity.resumeID] == requestId {
            resumableRequestByResumeID.removeValue(forKey: entry.identity.resumeID)
        }
        if let attached = entry.attachedAs { attachedResumeRequests.removeValue(forKey: attached) }
    }

    private func rescheduleHeldRequestExpiry() {
        heldRequestExpiryTask?.cancel()
        guard resumableRequests.values.contains(where: { $0.heldSince != nil }) else {
            heldRequestExpiryTask = nil
            return
        }
        heldRequestExpiryTask = Task { [weak self] in await self?.runHeldRequestExpiry() }
    }

    /// Wakes at the earliest end of a window, on the monotonic clock. A held
    /// generation that ends meanwhile moves its own end later.
    private func runHeldRequestExpiry() async {
        while !Task.isCancelled {
            let ends = resumableRequests.values.compactMap { entry in
                entry.heldSince.map { max($0, entry.route.endedAt ?? $0) + requestResumeWindow }
            }
            guard let next = ends.min() else { return }
            do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
            await expireHeldRequests(now: .now)
        }
    }
}
