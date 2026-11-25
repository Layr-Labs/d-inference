import Foundation

private func require(_ value: Bool, _ label: String) throws { if !value { throw ProbeError(label) } }
private func refuses(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw ProbeError("Assistant budget negative control accepted")
}

@main enum AssistantBudgetCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw ProbeError("Expected exact config, manifest and header paths") }
        let values = try CommandLine.arguments.dropFirst().map { try Data(contentsOf:URL(fileURLWithPath:$0)) }
        let artifact = try Gemma4AssistantArtifact(configuration:values[0],manifest:values[1],header:values[2])
        func aligned(_ n: Int) throws -> Int { guard n > 0 else { throw ProbeError("Nonpositive bound") }; return ((n+16383)/16384)*16384 }
        func budget(_ placement: Gemma4MTPAuxiliaryBudget.Placement, _ frontier: Int) throws -> Gemma4MTPAuxiliaryBudget {
            try .init(artifact:artifact,placement:placement,requestSHA256:String(repeating:"a",count:64),maximumFrontier:frontier,bound:aligned)
        }
        var groups = 0
        try require(artifact.tensors.count == 94 && artifact.quantizedPaths.count == 23
            && artifact.tensors.map(\.bytes).reduce(0,+) == 236_114_440,"Actual assistant packed inventory"); groups += 1
        let local = try budget(.localTarget,4096), remote = try budget(.remoteAssistant,4096)
        try require(local.items.count == 94 && remote.items.count == 97
            && remote.items.suffix(3).map(\.bytes).reduce(0,+) == 415_236_096,
            "Local borrows existing target embedding; remote selects exactly three tensors"); groups += 1
        try require(local.constructorTerms.filter { $0.name.hasPrefix("unquantized:") }.map(\.logicalBytes).reduce(0,+) == 1_678_844_944,
            "F32 constructor shape ceiling independent of packed payload"); groups += 1
        try require(local.constructorTerms.count == 142 && local.constructorBytes > 1_678_844_944
            && local.constructorBytes == remote.constructorBytes,"Pre/post constructor reserve retained"); groups += 1
        try require(local.snapshotLogicalBytes == 25_165_824 && remote.snapshotLogicalBytes == local.snapshotLogicalBytes,
            "Exact P4096 BF16 full/sliding snapshot"); groups += 1
        let short = try budget(.remoteAssistant,32), final = try budget(.remoteAssistant,4111)
        try require(short.snapshotLogicalBytes == 393_216 && final.snapshotLogicalBytes == 25_227_264,
            "Snapshot before window fill and final P4096/O16 frontier"); groups += 1
        try require(remote.liveNativeBytes > local.liveNativeBytes
            && remote.liveHostBytes-local.liveHostBytes == 2*25_165_824,
            "Remote native and host transfer copies charged separately"); groups += 1
        try require(local.maximumDraftTokens == 2 && local.maximumBufferedProposals == 5
            && local.liveTerms.filter { $0.name.hasSuffix(":fullVocabularyLogits") }.count == 5,
            "All retained five proposal graphs include full vocabulary head"); groups += 1
        let target = local.liveTerms.filter { $0.name.hasPrefix("targetVerification") }
        let targetLogits = target.filter { $0.name.hasSuffix(":logits") }
        try require(target.count == 18 && targetLogits.count == 2
            && targetLogits.allSatisfy({ $0.logicalBytes == 4*262144*4 })
            && !remote.liveTerms.contains(where: { $0.name.hasPrefix("targetVerification") }),
            "Local rectangular target rows charged separately from ordinary head and assistant"); groups += 1
        try require((local.constructorTerms+local.liveTerms).allSatisfy { $0.allocationBound >= $0.logicalBytes && $0.allocationBound % 16384 == 0 },
            "Every allocation individually rounded"); groups += 1
        try refuses { _ = try budget(.remoteAssistant,0) }
        try refuses { _ = try budget(.localTarget,8320) }; groups += 1
        try refuses { _ = try Gemma4MTPAuxiliaryBudget(artifact:artifact,placement:.localTarget,
            requestSHA256:String(repeating:"a",count:64),maximumFrontier:4096,bound:{ $0-1 }) }
        try refuses { _ = try Gemma4MTPAuxiliaryBudget(artifact:artifact,placement:.localTarget,
            requestSHA256:"unbound",maximumFrontier:4096,bound:aligned) }; groups += 1
        for changed in 0..<3 {
            var copy = values; copy[changed][0] ^= 1
            try refuses { _ = try Gemma4AssistantArtifact(configuration:copy[0],manifest:copy[1],header:copy[2]) }
        }
        groups += 1
        print("PASS \(groups) actual-header Foundation assistant budget groups; no actual allocator/model/resource qualification")
    }
}
