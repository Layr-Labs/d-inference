import Foundation

/// Logical incremental terms, not a new admission authority. The original target
/// owner must round and ADD these to its existing verification/capture budget.
struct Gemma4MTPPullTransferPlan: Equatable {
    struct Term: Equatable { let name: String, bytes: Int }
    let frontier: Int, hiddenDType: Int
    let hiddenBytes: Int, snapshotBytes: Int
    let senderAdditional: [Term]
    let receiverRoots: [Term]
    let receiverSnapshotCopies = 3
    let maximumSingleTransferBytes = 16 * 1024 * 1024
    init(frontier: Int, hiddenDType: Int) throws {
        guard (1...8319).contains(frontier), (1...3).contains(hiddenDType) else {
            throw Gemma4MTPPullRecord.Failure(reason: "Remote capture geometry/type exceeds the depth-two auxiliary scope")
        }
        self.frontier = frontier; self.hiddenDType = hiddenDType
        hiddenBytes = 2816 * (hiddenDType == 3 ? 4 : 2)
        snapshotBytes = 2 * 2 * frontier * 512 * 2 + 2 * 8 * min(frontier,1024) * 256 * 2
        // Charge each potential pack separately before any send. Native handles
        // alias send storage; never count their completion as peer consumption.
        senderAdditional = [
            .init(name:"remoteMTP.sendPack.fullKeys.head0",bytes:frontier*512*2),
            .init(name:"remoteMTP.sendPack.fullKeys.head1",bytes:frontier*512*2),
            .init(name:"remoteMTP.sendPack.fullValues.head0",bytes:frontier*512*2),
            .init(name:"remoteMTP.sendPack.fullValues.head1",bytes:frontier*512*2),
            .init(name:"remoteMTP.sendPack.slidingKeys",bytes:8*min(frontier,1024)*256*2),
            .init(name:"remoteMTP.sendPack.slidingValues",bytes:8*min(frontier,1024)*256*2),
            .init(name:"remoteMTP.sendPack.hidden",bytes:hiddenBytes),
            .init(name:"remoteMTP.control",bytes:16*1024)]
        receiverRoots = [
            .init(name:"hidden",bytes:hiddenBytes),
            .init(name:"fullKeys.head0",bytes:frontier*512*2),
            .init(name:"fullKeys.head1",bytes:frontier*512*2),
            .init(name:"fullValues.head0",bytes:frontier*512*2),
            .init(name:"fullValues.head1",bytes:frontier*512*2),
            .init(name:"fullKeys.assembled",bytes:2*frontier*512*2),
            .init(name:"fullValues.assembled",bytes:2*frontier*512*2),
            .init(name:"slidingKeys",bytes:8*min(frontier,1024)*256*2),
            .init(name:"slidingValues",bytes:8*min(frontier,1024)*256*2)]
    }
}
