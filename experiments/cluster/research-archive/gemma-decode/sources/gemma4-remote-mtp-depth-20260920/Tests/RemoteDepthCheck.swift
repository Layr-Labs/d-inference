import Foundation

/// Synthetic protocol decisions only; no tensor, model, socket or physical proof.
@main enum RemoteDepthCheck {
    typealias Record = Gemma4MTPPullRecord
    struct Failure: Error { let text: String }
    static let scope = AsyncMTPProposalLedger.Scope(requestID:UUID(uuidString:"00000000-0000-0000-0000-000000000011")!,
        membershipEpoch:UUID(uuidString:"00000000-0000-0000-0000-000000000022")!,
        targetBuildSHA256:String(repeating:"a",count:64),assistantBuildSHA256:String(repeating:"b",count:64),
        targetArtifactSHA256:String(repeating:"c",count:64),assistantArtifactSHA256:String(repeating:"d",count:64),
        embeddingIdentitySHA256:String(repeating:"e",count:64))
    static let requestSHA = String(repeating:"f",count:64)
    static func require(_ value: Bool, _ text: String) throws { if !value { throw Failure(text:text) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(text:"Expected refusal")
    }
    final class Peer {
        let mirror: Gemma4MTPPullMirror
        var sequence: UInt64 = 0
        var branch: AsyncMTPProposalLedger.BranchID!
        var generated = 0
        var windows: UInt64 = 0
        var grant: AsyncMTPProposalLedger.Grant?
        init() throws {
            mirror = try .init(scope:scope,requestSHA256:requestSHA,inputFrontier:10,seed:7,maximumInputFrontier:100)
            try seed()
        }
        func record(_ kind: Record.Kind) -> Record {
            .init(kind:kind,sequence:sequence,scopeSHA256:mirror.scopeSHA256,branch:branch)
        }
        func seed() throws {
            let ordinal = branch == nil ? 0 : branch.ordinal+1
            let digest = Record.captureFingerprint(scope:mirror.scopeSHA256,ordinal:ordinal,
                frontier:mirror.ledger.inputFrontier,seed:mirror.ledger.seedToken,hiddenDType:1)
            branch = .init(scope:scope,ordinal:ordinal,snapshotFrontier:mirror.ledger.inputFrontier,
                initialSeedToken:mirror.ledger.seedToken,snapshotSHA256:digest)
            var command = record(.seed)
            command.frontier = mirror.ledger.inputFrontier; command.seed = mirror.ledger.seedToken; command.hiddenDType = 1
            guard case .install(let id) = try mirror.accept(command) else { throw Failure(text:"Seed action differs") }
            try require(id == branch,"Seed identity differs")
            _ = try mirror.response(.seeded); try mirror.responseSent(); sequence += 1; generated = 0
        }
        func credit(_ tokens: [Int], complete: Bool = true) throws {
            var command = record(.credit)
            command.frontier = mirror.ledger.inputFrontier; command.seed = mirror.ledger.seedToken
            command.firstPosition = branch.snapshotFrontier+generated+1; command.count = tokens.count
            guard case .generate(let grant) = try mirror.accept(command) else { throw Failure(text:"Credit action differs") }
            self.grant = grant
            let queued = try mirror.response(.queued)
            try require(queued.tokens.isEmpty,"Queued ACK cannot contain completed proposals")
            try mirror.responseSent(); sequence += 1
            if complete { try mirror.generationCompleted(grant,tokens:tokens) }
            generated += tokens.count
        }
        func pull() throws -> [Int] {
            guard let grant else { throw Failure(text:"Missing synthetic credit") }
            var command = record(.pull); command.firstPosition = grant.firstPosition; command.count = grant.count
            guard case .deliver(let tokens) = try mirror.accept(command) else { throw Failure(text:"Pull action differs") }
            let response = try mirror.response(.proposals)
            try require(response.tokens == tokens,"Pull bytes differ")
            try mirror.responseSent(); sequence += 1; self.grant = nil
            return tokens
        }
        func resolve(_ target: [Int], accepted: Int) throws {
            var command = record(.resolve)
            command.count = target.count-1; command.accepted = accepted; command.windowOrdinal = windows
            command.frontier = mirror.ledger.inputFrontier+accepted+1
            command.seed = target[accepted]; command.tokens = target
            guard case .resolved = try mirror.accept(command) else { throw Failure(text:"Resolve action differs") }
            _ = try mirror.response(.resolved); try mirror.responseSent(); sequence += 1; windows += 1
        }
        func stop(_ kind: Record.Kind, response: Record.Kind) throws {
            _ = try mirror.accept(record(kind)); _ = try mirror.response(response)
            try mirror.responseSent(); sequence += 1
        }
    }
    static func main() throws {
        var groups: [String] = []
        func group(_ name: String, _ body: () throws -> Void) throws { try body(); groups.append(name) }
        try group("fixed-frame-roundtrip") {
            let p = try Peer(), frame = p.record(.retire)
            let encoded = try frame.encode(), decoded = try Record.decode(encoded)
            try require(encoded.count == 16*1024 && decoded == frame,"Fixed frame differs")
        }
        try group("frame-truncation-extension") {
            let bytes = try Peer().record(.retire).encode()
            try refuses { _ = try Record.decode(bytes.dropLast()) }
            try refuses { _ = try Record.decode(bytes+Data([0])) }
        }
        try group("frame-magic-version-opcode-padding") {
            let bytes = try Peer().record(.retire).encode()
            for index in [0,11,15,148,16383] {
                var changed = bytes; changed[index] = 255
                try refuses { _ = try Record.decode(changed) }
            }
        }
        try group("unused-token-slots-refused") {
            var bytes = try Peer().record(.retire).encode(); bytes[75] = 1
            try refuses { _ = try Record.decode(bytes) }
        }
        try group("scope-request-and-context-binding") {
            let a = Record.scopeFingerprint(scope,requestSHA256:requestSHA,initialFrontier:10,maximumInputFrontier:100)
            let b = Record.scopeFingerprint(scope,requestSHA256:String(repeating:"0",count:64),initialFrontier:10,maximumInputFrontier:100)
            let c = Record.scopeFingerprint(scope,requestSHA256:requestSHA,initialFrontier:11,maximumInputFrontier:100)
            try require(a != b && a != c,"Request/context are not bound")
        }
        try group("queued-is-not-completed") {
            let p = try Peer(); try p.credit([11,12],complete:false)
            try refuses { _ = try p.pull() }
        }
        try group("one-outstanding-credit") {
            let p = try Peer(); try p.credit([11,12])
            try refuses { try p.credit([13,14]) }
        }
        try group("five-slot-bound") {
            let p = try Peer()
            for tokens in [[11,12],[13,14],[15]] { try p.credit(tokens); _ = try p.pull() }
            try require(p.mirror.ledger.proposalCredit == 0,"Queue exceeds five")
            try refuses { try p.credit([16]) }
        }
        try group("full-accept-bonus-bridge-reuse") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull()
            try p.credit([13,14]); _ = try p.pull()
            try p.resolve([11,12,13],accepted:2)
            try require(!p.mirror.ledger.requiresBranchRetirement && p.mirror.ledger.inputFrontier == 13,"Matching bonus not bridged")
            try p.credit([15,16]); _ = try p.pull()
            try p.resolve([14,15,16],accepted:2)
            try require(p.mirror.ledger.counters.reusedProposalsOffered == 2,"Frozen branch was not reused")
        }
        try group("bonus-mismatch-retires-before-reseed") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull(); try p.credit([99,14]); _ = try p.pull()
            try p.resolve([11,12,13],accepted:2)
            try require(p.mirror.ledger.requiresBranchRetirement,"Different bonus allowed reuse")
            try p.stop(.retire,response:.retired); try p.seed()
            try require(p.branch.ordinal == 1 && p.branch.initialSeedToken == 13 && p.branch.snapshotFrontier == 13,"Reseed did not use target seed/frontier")
        }
        try group("rejection-correction-is-target-owned") {
            let p = try Peer(); try p.credit([11,12]); _ = try p.pull()
            try p.resolve([22,33,44],accepted:0)
            try require(p.mirror.ledger.seedToken == 22 && p.mirror.ledger.inputFrontier == 11 && p.mirror.ledger.requiresBranchRetirement,"Correction differs")
        }
        try group("false-accepted-prefix-refused") {
            let p = try Peer(); try p.credit([11,12]); _ = try p.pull()
            try refuses { try p.resolve([99,12,13],accepted:2) }
        }
        try group("early-reseed-refused") {
            let p = try Peer(); try refuses { try p.seed() }
        }
        try group("replay-and-unrelated-fields-refused") {
            for changed in 0..<2 {
                let p = try Peer(); var command = p.record(.credit)
                command.frontier = 10; command.seed = 7; command.firstPosition = 11; command.count = 2
                if changed == 0 { command = command.changingKind(.queued) } else { command.tokens = [1] }
                try refuses { _ = try p.mirror.accept(command) }
            }
        }
        try group("cancel-drains-unpulled-result") {
            let p = try Peer(); try p.credit([11,12]); try p.stop(.cancel,response:.cancelled)
            try require(p.mirror.ledger.controlStateRetired,"Cancelled control did not retire")
            try refuses { try p.seed() }
        }
        try group("finish-drains-unused-lookahead") {
            let p = try Peer(); try p.credit([11,12]); try p.stop(.finish,response:.finished)
            try require(p.mirror.ledger.controlStateRetired,"Finish kept scalar branch active")
        }
        try group("grant-result-count-and-token-bounds") {
            let p = try Peer(); try p.credit([11,12],complete:false)
            try refuses { try p.mirror.generationCompleted(p.grant!,tokens:[11]) }
            try refuses { try p.mirror.generationCompleted(p.grant!,tokens:[11,262_144]) }
        }
        try group("snapshot-transfer-bounds") {
            for frontier in [1,1024,4096,8319] {
                let plan = try Gemma4MTPPullTransferPlan(frontier:frontier,hiddenDType:3)
                try require(plan.snapshotBytes == 4096*frontier+8192*min(frontier,1024),"Snapshot bytes differ")
                try require(frontier*512*2 <= plan.maximumSingleTransferBytes && plan.receiverSnapshotCopies == 3,"Head split/copy bound differs")
                try require(plan.senderAdditional.map(\.bytes).reduce(0,+) == plan.snapshotBytes+11264+16384,"Sender charge omitted live term")
            }
            try refuses { _ = try Gemma4MTPPullTransferPlan(frontier:8320,hiddenDType:1) }
            try refuses { _ = try Gemma4MTPPullTransferPlan(frontier:4096,hiddenDType:4) }
        }
        try group("verification-depth-input-and-scope") {
            let one = try Gemma4RemoteMTPDepth(maximumDraftTokens:1)
            let two = try Gemma4RemoteMTPDepth(maximumDraftTokens:2)
            try require(one.scopeComponent == "depth=1" && two.scopeComponent == "depth=2","Chosen depth domain differs")
            for invalid in [-1,0,3,Int.max] { try refuses { _ = try Gemma4RemoteMTPDepth(maximumDraftTokens:invalid) } }
        }
        try group("verification-depth-output-tail") {
            let one = try Gemma4RemoteMTPDepth(maximumDraftTokens:1)
            let two = try Gemma4RemoteMTPDepth(maximumDraftTokens:2)
            for remaining in 2...16 {
                let a = try one.draftCount(remainingOutputTokens:remaining)
                let b = try two.draftCount(remainingOutputTokens:remaining)
                try require(a == 1 && b == min(2,remaining-1),"Depth2 changed or depth1 widened")
            }
            for invalid in [-1,0,1] { try refuses { _ = try one.draftCount(remainingOutputTokens:invalid) } }
        }
        try group("depth-one-accept-bonus-bridge-reuse") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull(); try p.credit([13,14]); _ = try p.pull()
            try p.resolve([11,12],accepted:1)
            try require(!p.mirror.ledger.requiresBranchRetirement && p.mirror.ledger.inputFrontier == 12,"Depth1 bonus bridge differs")
            try p.credit([15,16]); _ = try p.pull(); try p.resolve([13,14],accepted:1)
            try require(p.mirror.ledger.inputFrontier == 14 && p.mirror.ledger.counters.reusedProposalsOffered == 1,"Depth1 reused proposal order differs")
            try require(p.mirror.ledger.maximumDraftTokens == 2 && p.mirror.ledger.maximumBufferedProposals == 5,"Producer envelope was reduced or widened")
        }
        try group("depth-one-bonus-mismatch-reseed") {
            let p = try Peer()
            try p.credit([11,99]); _ = try p.pull(); try p.credit([13,14]); _ = try p.pull()
            try p.resolve([11,12],accepted:1)
            try require(p.mirror.ledger.requiresBranchRetirement,"Depth1 mismatching bridge reused")
            try p.stop(.retire,response:.retired); try p.seed()
            try require(p.branch.ordinal == 1 && p.branch.snapshotFrontier == 12 && p.branch.initialSeedToken == 12,"Depth1 reseed lost authoritative target state")
        }
        try group("depth-one-rejection-reseed") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull(); try p.credit([13,14]); _ = try p.pull()
            try p.resolve([22,33],accepted:0)
            try require(p.mirror.ledger.requiresBranchRetirement && p.mirror.ledger.seedToken == 22 && p.mirror.ledger.inputFrontier == 11,"Depth1 correction differs")
            try p.stop(.retire,response:.retired); try p.seed()
            try require(p.branch.snapshotFrontier == 11 && p.branch.initialSeedToken == 22,"Rejected proposal became seed")
        }
        try group("depth-one-false-prefix-refused") {
            let p = try Peer(); try p.credit([11,12]); _ = try p.pull()
            try refuses { try p.resolve([99,12],accepted:1) }
        }
        try group("depth-one-cancel-with-lookahead") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull(); try p.resolve([11,12],accepted:1)
            try p.credit([13,14]); try p.stop(.cancel,response:.cancelled)
            try require(p.mirror.ledger.controlStateRetired,"Depth1 cancellation kept a branch")
            try refuses { try p.seed() }
        }
        try group("depth-one-finish-unused-lookahead") {
            let p = try Peer()
            try p.credit([11,12]); _ = try p.pull(); try p.resolve([11,12],accepted:1)
            try p.credit([13,14]); try p.stop(.finish,response:.finished)
            try require(p.mirror.ledger.controlStateRetired,"Depth1 finish kept scalar work")
        }
        let output: [String:Any] = ["schema":"gemma4_mtp_remote_depth_cpu_v1","passed":true,"groups":groups,
            "groupCount":groups.count,"modelExecuted":false,"nativeExecuted":false,"physicalRetirementEstablished":false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
