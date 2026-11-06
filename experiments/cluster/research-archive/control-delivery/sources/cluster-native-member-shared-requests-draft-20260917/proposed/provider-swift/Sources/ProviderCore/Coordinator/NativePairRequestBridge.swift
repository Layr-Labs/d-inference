import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Request views of the original retained endpoint; no process factory, SSH
/// connection or independent device/state owner exists here. Pair remains the
/// sole bilateral reservation/token/retirement/accounting implementation.
final class NativePairRequestBridge: @unchecked Sendable {
    let endpoint: ClusterRemoteWorkerEndpoint
    let lifetime, cleanupDeadline: UInt64
    private let installation: NativePairMemberInstallation
    private let start: ClusterNativeAuthorizationStart
    private let context: @Sendable () throws -> ClusterNativeKeyBinding
    private let cancel: @Sendable () -> Void
    private let condition=NSCondition(), pump=DispatchGroup(), released=DispatchGroup()
    private let writer: NativePairRequestWriter
    private var local: NativePairRetainedEndpoint?, remote: NativePairRetainedEndpoint?
    private var nextCommand: UInt64=0
    private var invalid=false, releaseObserved=false, ownerClaimed=false
    private var pair: ClusterWorkerPair?
    init(endpoint: ClusterRemoteWorkerEndpoint, installation: NativePairMemberInstallation,
         start: ClusterNativeAuthorizationStart, lifetime: UInt64, cleanupDeadline: UInt64,
         context: @escaping @Sendable () throws -> ClusterNativeKeyBinding,
         send: @escaping @Sendable (NativePairWorkerPacket,UInt64) throws -> Void,
         cancel: @escaping @Sendable () -> Void) throws {
        guard installation.protectedRuntime != nil else {throw NativePairMemberError.unconfigured}
        self.endpoint=endpoint;self.installation=installation;self.start=start
        self.lifetime=lifetime;self.cleanupDeadline=cleanupDeadline;self.context=context;self.cancel=cancel
        writer=NativePairRequestWriter(send:send,failed:cancel);pump.enter();released.enter()
    }
    func run() {DispatchQueue(label:"darkbloom.native-member.requests.read").async {self.readNative()}}
    private func readNative() {
        defer {pump.leave()}
        do {
            let first=try endpoint.receiveWorkerEvent(until:lifetime)
            guard case .ready(let ready)=first.event else {throw NativePairMemberError.binding}
            let binding=try context(), runtime=installation.protectedRuntime!
            let localPolicy=try runtime.readyPolicy(start:start,identity:endpoint.expectedIdentity,profile:endpoint.expectedProfile)
            try localPolicy.validate(ready)
            let l=NativePairRetainedEndpoint(identity:endpoint.expectedIdentity,profile:endpoint.expectedProfile,
                rank:start.rank,plan:endpoint.executionPlanSHA256,lifetime:lifetime,readyPolicy:localPolicy,
                send:{[endpoint] command,id,deadline in try endpoint.sendWorkerCommand(command,requestID:id,deadline:deadline)},cancel:cancel)
            try l.accept(first)
            var r: NativePairRetainedEndpoint?
            if start.rank == 0 {
                let peerPolicy=try runtime.readyPolicy(start:binding.hellos[1].start,identity:endpoint.expectedIdentity,profile:endpoint.expectedProfile)
                r=NativePairRetainedEndpoint(identity:endpoint.expectedIdentity,profile:endpoint.expectedProfile,rank:1,
                    plan:endpoint.executionPlanSHA256,lifetime:lifetime,readyPolicy:peerPolicy,
                    send:{[weak self] command,id,deadline in guard let self else {throw NativePairMemberError.inactive};try self.sendCommand(command,id:id,deadline:deadline)},cancel:cancel)
            }
            condition.lock();guard !invalid else {condition.unlock();throw NativePairMemberError.inactive}
            local=l;remote=r;condition.broadcast();condition.unlock()
            try writer.submit(.init(kind:.ready,transcript:binding.transcriptSHA256,payload:ClusterWorkerCodec.encode(first)),until:lifetime)
            while true {
                let event: ClusterWorkerEventFrame
                do {event=try endpoint.receiveWorkerEvent(until:cleanupDeadline)}
                catch ClusterWorkerOwnerError.closed {break}
                if start.rank == 0 {try l.accept(event)}
                else {try writer.submit(.init(kind:.event,transcript:binding.transcriptSHA256,payload:ClusterWorkerCodec.encode(event)),until:lifetime)}
            }
        } catch {cancel()}
        if endpoint.nativeCleanupObserved {condition.lock();let l=local;condition.unlock();l?.observeCleanup()}
    }
    private func sendCommand(_ command: ClusterWorkerCommand,id: UUID?,deadline: UInt64) throws {
        let binding=try context()
        condition.lock();defer{condition.unlock()}
        guard !invalid, start.rank==0, nextCommand<UInt64(Int64.max) else {throw NativePairMemberError.inactive}
        let frame=ClusterWorkerCommandFrame(membershipEpoch:start.common.epoch,sequence:nextCommand,requestID:id,command:command)
        let packet=try NativePairWorkerPacket.command(frame,transcript:binding.transcriptSHA256,lifetime:lifetime,deliveryDeadline:deadline)
        try writer.submit(packet,until:deadline);nextCommand += 1
    }
    func receive(_ message: NativePairMessage) throws {
        let binding=try context()
        let packet=try NativePairWorkerPacket(Data(base64Encoded:message.payload)!,type:message.type,transcript:binding.transcriptSHA256)
        condition.lock();let allowed = !invalid;let remote=remote;condition.unlock()
        guard allowed else {throw NativePairMemberError.inactive}
        if start.rank==1 {
            guard packet.kind == .command else {throw NativePairMemberError.binding}
            let (frame,delivery)=try packet.localCommand(lifetime:lifetime,now:DispatchTime.now().uptimeNanoseconds)
            condition.lock();defer{condition.unlock()}
            guard frame.membershipEpoch==start.common.epoch,frame.sequence==nextCommand else {throw NativePairMemberError.binding}
            try endpoint.sendWorkerCommand(frame.command,requestID:frame.requestID,deadline:delivery);nextCommand += 1
        } else {
            guard let remote, packet.kind == .ready || packet.kind == .event else {throw NativePairMemberError.binding}
            let frame=try ClusterWorkerCodec.decodeEvent(packet.payload)
            if packet.kind == .ready {guard case .ready=frame.event else {throw NativePairMemberError.binding}}
            else {if case .ready=frame.event {throw NativePairMemberError.binding}}
            try remote.accept(frame)
        }
    }
    func invalidate() {
        condition.lock();invalid=true;let endpoints=[local,remote].compactMap{$0};condition.broadcast();condition.unlock()
        writer.invalidate();for value in endpoints {value.invalidate()}
    }
    /// Local cleanup proof is observed directly. Queued publication can never
    /// delay native cleanup; failure to join only prevents release/reuse.
    func localOwnerReleased(until deadline: UInt64) -> Bool {
        condition.lock();let l=local;condition.unlock()
        if endpoint.nativeCleanupObserved {l?.observeCleanup()}
        let pumpJoined=pump.wait(timeout:.init(uptimeNanoseconds:deadline)) == .success
        return pumpJoined && writer.join(until:deadline)
    }
    /// Caller has authenticated the coordinator's exact original all-owner
    /// release receipt. This is the only proof that completes the remote view.
    func observeAllOwnersReleased() throws {
        condition.lock()
        guard !releaseObserved else {condition.unlock();throw NativePairMemberError.binding}
        releaseObserved=true;invalid=true
        let endpoints=[local,remote].compactMap{$0};condition.broadcast();condition.unlock()
        for value in endpoints {value.observeCleanup()}
        released.leave()
    }
    func waitAllOwnersReleased(until deadline: UInt64) -> Bool {released.wait(timeout:.init(uptimeNanoseconds:deadline)) == .success}
    func requestOwner(profile: DistributedResidentExecutionProfile, until deadline: UInt64) throws -> NativePairRequestExecutionOwner {
        condition.lock()
        while !invalid && local==nil && DispatchTime.now().uptimeNanoseconds<deadline {_ = condition.wait(until:Date(timeIntervalSinceNow:0.02))}
        guard !invalid, start.rank==0, !ownerClaimed, let local,let remote else {condition.unlock();throw NativePairMemberError.inactive}
        ownerClaimed=true;condition.unlock()
        do {
            let pair=try ClusterWorkerPair(workers:[local,remote],startupDeadline:min(deadline,lifetime),maximumRequests:1)
            guard profile.requestTimeout <= .seconds(300) else {throw NativePairMemberError.binding}
            let owner=NativePairRequestExecutionOwner(try DistributedPipeExecutionOwner(pair:pair,profile:profile,chunkSize:16))
            condition.lock();guard !invalid else {condition.unlock();throw NativePairMemberError.inactive};self.pair=pair;condition.unlock()
            return owner
        } catch {cancel();throw error}
    }
}
