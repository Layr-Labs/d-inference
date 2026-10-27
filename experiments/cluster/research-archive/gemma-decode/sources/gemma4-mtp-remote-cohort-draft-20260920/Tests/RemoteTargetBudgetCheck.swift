import Foundation

@main enum RemoteTargetBudgetCheck {
    static func require(_ condition: Bool, _ label: String) throws { if !condition { throw ProbeError(label) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw ProbeError("Remote target negative accepted")
    }
    static func main() throws {
        var groups = 0
        let hash = String(repeating:"a",count:64)
        func aligned(_ bytes: Int) -> Int { ((bytes+16_383)/16_384)*16_384 }
        func budget(_ frontier: Int) throws -> Gemma4MTPRemoteTargetBudget {
            try .init(requestSHA256:hash,maximumFrontier:frontier,bound:aligned)
        }
        let b = try budget(4111)
        let heads = b.terms.filter { $0.name.hasPrefix("targetVerification") }
        let expectedPerSet = 4*4*262_144*4 + 4*262_144 + 4*4 + 1 + 2*4*2816*4
        try require(heads.count == 18 && heads.map(\.logicalBytes).reduce(0,+) == 2*expectedPerSet,
            "Exact two independent width-four head/hidden worksets"); groups += 1
        for frontier in [1,129,1024,4096,4111,8319] {
            let value = try budget(frontier)
            let snapshots = value.terms.filter { $0.name.hasPrefix("snapshot:") }
            let packs = value.terms.filter { $0.name.hasPrefix("remoteMTP.sendPack.") }
            let expected = 4096*frontier+8192*min(frontier,1024)
            try require(snapshots.count == 4 && snapshots.map(\.logicalBytes).reduce(0,+) == expected,
                "Target immutable snapshot is independent of state capture")
            try require(packs.count == 7 && packs.map(\.logicalBytes).reduce(0,+) == expected+11_264,
                "All seven sender packs remain separately charged")
        }
        groups += 1
        let narrow = try budget(129)
        let fullPacks = narrow.terms.filter { $0.name.contains(".head") }
        try require(fullPacks.count == 4 && fullPacks.allSatisfy({ $0.logicalBytes == 129*512*2 && $0.allocationBound == aligned(129*512*2) }),
            "Each full K/V head has its own allocation rounding"); groups += 1
        for frontier in [1,129,1024,4096,4111,8319] {
            let plan = try Gemma4MTPPullTransferPlan(frontier:frontier,hiddenDType:3)
            let actual = plan.receiverRoots.map { aligned($0.bytes) }.reduce(0,+)
            let threeSets = 3*(2*aligned(frontier*2*512*2)+2*aligned(min(frontier,1024)*8*256*2))
            try require(plan.receiverRoots.count == 9 && actual <= threeSets,
                "Nine independently rounded receive roots fit unchanged three-set example bound")
        }
        groups += 1
        try require(b.terms.count == 30 && b.hostBytes == 16*1_048_576+32_768
            && b.nativeBytes == b.terms.map(\.allocationBound).reduce(0,+)
            && !b.terms.contains(where: { $0.name.contains("proposal") || $0.name.contains("parameter") || $0.name.contains("constructor") }),
            "Target owns no local assistant constructor, parameters or proposal graphs"); groups += 1
        try refuses { _ = try budget(0) }; try refuses { _ = try budget(8320) }
        try refuses { _ = try Gemma4MTPRemoteTargetBudget(requestSHA256:"unbound",maximumFrontier:4096,bound:aligned) }
        try refuses { _ = try Gemma4MTPRemoteTargetBudget(requestSHA256:hash,maximumFrontier:4096,bound:{$0-1}) }
        groups += 1
        print("PASS \(groups) synthetic remote target budget groups; no allocator, model or physical qualification")
    }
}
