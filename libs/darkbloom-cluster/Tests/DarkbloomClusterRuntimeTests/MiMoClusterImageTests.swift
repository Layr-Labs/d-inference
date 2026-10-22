import Foundation
import Testing
import DarkbloomClusterProtocol
import MLXLLM
import MLXVLM
@testable import DarkbloomClusterRuntime

/// CPU-only contracts. No arrays/model/Metal invocation, fixture weight reads,
/// device lane or endpoint. These tests must be compiled/run by the parent.
@Suite("MiMo cluster encoded image contracts (CPU)")
struct MiMoClusterImageTests {
    static let red = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC")!
    static let blue = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdNvJ8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ2oPcf88OIhvJ6vAAAAAElFTkSuQmCC")!
    func configuration() throws -> (Data,MiMoV26Configuration) {
        let tests = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        let package = tests.deletingLastPathComponent().deletingLastPathComponent()
        let root = package.deletingLastPathComponent() // libs; worker fixtures are in its sibling package
        let bytes = try Data(contentsOf:root.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-mimo-v26-flash-mopd.configuration.json"))
        return (bytes,try JSONDecoder().decode(MiMoV26Configuration.self,from:bytes))
    }
    func fixture(_ data: Data? = nil) throws -> (tokens:[Int],media:ClusterMiMoImages) {
        let c = try configuration().1, png = data ?? Self.red
        let i = try MiMoV26ClusterImagePlan.inspectPNG(png,configuration:c,
            maximumEncodedBytes:ClusterMiMoImages.maximumEncodedBytes,maximumPixels:ClusterMiMoImages.maximumPixels)
        let count = i.geometry.mediaTokens
        return ([7,151652]+Array(repeating:151655,count:count)+[151653,8],.init(images:[
            .init(png:png,width:i.width,height:i.height,tokenOffset:2,tokenCount:count)]))
    }
    @Test func realPNGGeometryUsesSDKAndRejectsMalformedOversize() throws {
        let c = try configuration().1
        let i = try MiMoV26ClusterImagePlan.inspectPNG(Self.red,configuration:c,maximumEncodedBytes:1024,maximumPixels:4096)
        #expect(i.width == 64 && i.height == 64)
        #expect(i.geometry == (try MiMoV26MediaGeometry.image(height:64,width:64,
            settings:MiMoV26ClusterImagePlan.settings(configuration:c))))
        #expect(throws:(any Error).self) {
            try MiMoV26ClusterImagePlan.inspectPNG(Self.red,configuration:c,maximumEncodedBytes:Self.red.count-1,maximumPixels:4096)
        }
        #expect(throws:(any Error).self) {
            try MiMoV26ClusterImagePlan.inspectPNG(Data(Self.red.prefix(30)),configuration:c,maximumEncodedBytes:1024,maximumPixels:4096)
        }
        #expect(throws:(any Error).self) {
            try MiMoV26ClusterImagePlan.inspectPNG(Self.red,configuration:c,maximumEncodedBytes:1024,maximumPixels:4095)
        }
    }
    @Test func strictEnvelopeCannotSmuggleUnknownBooleanOrDuplicateFields() throws {
        let f = try fixture(), bytes = try JSONEncoder().encode(f.media)
        #expect(try ClusterMiMoImages.decodeBounded(bytes) == f.media)
        let object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        var extra = object;extra["external_embeddings"] = [1,2,3]
        #expect(throws:(any Error).self) { try ClusterMiMoImages.decodeBounded(JSONSerialization.data(withJSONObject:extra)) }
        var image = (object["images"] as! [[String:Any]])[0];image["width"] = true
        #expect(throws:(any Error).self) { try ClusterMiMoImages.decodeBounded(JSONSerialization.data(withJSONObject:["images":[image]])) }
        #expect(throws:(any Error).self) { try ClusterMiMoImages.decodeBounded(Data(#"{"images":[],"images":[]}"#.utf8)) }
        #expect(throws:(any Error).self) { try ClusterMiMoImages.decodeBounded(Data(repeating:32,count:135001)) }
    }
    @Test func positionsAndPixelIdentityBindRequestAndPrefix() throws {
        let a = try fixture(), b = try fixture(Self.blue)
        #expect(a.tokens == b.tokens)
        try a.media.validate(prompt:a.tokens);try b.media.validate(prompt:b.tokens)
        #expect(a.media.fingerprint != b.media.fingerprint)
        let profile = try MiMoRegisteredSpecification.specification(.v26FlashMOPD).profile(imageCandidate:true)
        let id = UUID()
        let r0 = try QwenLayerStageGenerationRequest(profile:profile,requestID:id,promptTokenIDs:a.tokens,
            chunkSize:8,outputCount:4,stopTokenIDs:[],mimoImages:a.media)
        let r1 = try QwenLayerStageGenerationRequest(profile:profile,requestID:id,promptTokenIDs:b.tokens,
            chunkSize:8,outputCount:4,stopTokenIDs:[],mimoImages:b.media)
        #expect(r0.fingerprint != r1.fingerprint)
        #expect(try r0.planned(reusedPrefix:1,splitFinalToken:true).mimoImages == a.media)
        let hash = String(repeating:"a",count:64)
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256:hash,artifactAggregateSHA256:hash,
            storageCommitmentSHA256:hash,planFingerprint:hash,producerStageFingerprint:hash)
        #expect(qwenStagePrefixScope(source:source,numericalPolicySHA256:hash,request:r0)
            != qwenStagePrefixScope(source:source,numericalPolicySHA256:hash,request:r1))
        let image = a.media.images[0]
        let moved = ClusterMiMoImages(images:[.init(png:image.png,width:64,height:64,
            tokenOffset:image.tokenOffset+1,tokenCount:image.tokenCount)])
        #expect(moved.fingerprint != a.media.fingerprint)
        #expect(throws:(any Error).self) { try moved.validate(prompt:a.tokens) }
        #expect(throws:(any Error).self) { try a.media.validate(prompt:a.tokens+[151655]) }
    }
    @Test func boundedWorkerRoundTripPreservesEnvelopeAndForeignProfileRefuses() throws {
        let f = try fixture()
        let profile = "registered_mimo_v26_flash_mopd_greedy_generation_v1"+ClusterMiMoImages.profileSuffix
        func frame(profile: String,media:ClusterMiMoImages?) -> ClusterWorkerCommandFrame {
            .init(membershipEpoch:UUID(),sequence:0,requestID:UUID(),command:.reserve(.init(profileID:profile,
                promptTokenIDs:f.tokens,stopTokenIDs:[],outputCount:4,chunkSize:8,deadlineUptimeNanoseconds:1000,
                capacityLimitBytes:1<<30,sampling:nil,mimoImages:media)))
        }
        let record = try ClusterWorkerCodec.encode(frame(profile:profile,media:f.media))
        #expect(record.count <= 512*1024)
        let decoded = try ClusterWorkerCodec.decodeCommand(record)
        guard case .reserve(let reservation) = decoded.command else { Issue.record("reservation missing");return }
        #expect(reservation.mimoImages == f.media)
        #expect(throws:(any Error).self) { try ClusterWorkerCodec.encode(frame(profile:"foreign-text",media:f.media)) }
        let text = try ClusterWorkerCodec.encode(frame(profile:"foreign-text",media:nil))
        #expect(!String(decoding:text,as:UTF8.self).contains("mimoImages"))
    }
    @Test func resourceQuoteAccountsRankOwnershipAndRefusesForgedGeometryUnderquoteOverflow() throws {
        let c = try configuration().1,f = try fixture()
        let producer = try MiMoStageImageBudget.derive(f.media,prompt:f.tokens,configuration:c,chunkSize:8,rank:0,bound:{$0})
        let consumer = try MiMoStageImageBudget.derive(f.media,prompt:f.tokens,configuration:c,chunkSize:8,rank:1,bound:{$0})
        #expect(producer.reservedBytes > consumer.reservedBytes)
        #expect(consumer.reservedBytes == f.media.encodedBytes*12+2*ClusterWorkerLimits.commandBytes)
        #expect(producer.reservedBytes > producer.inspections[0].decodeBytes)
        #expect(throws:(any Error).self) {
            try MiMoStageImageBudget.derive(f.media,prompt:f.tokens,configuration:c,chunkSize:8,rank:0,bound:{ _ in 0 })
        }
        #expect(throws:(any Error).self) {
            try MiMoStageImageBudget.derive(f.media,prompt:f.tokens,configuration:c,chunkSize:Int.max,rank:0,bound:{$0})
        }
        let bad = ClusterMiMoImages(images:[.init(png:Self.red,width:63,height:64,tokenOffset:2,tokenCount:f.media.images[0].tokenCount)])
        #expect(throws:(any Error).self) {
            try MiMoStageImageBudget.derive(bad,prompt:f.tokens,configuration:c,chunkSize:8,rank:0,bound:{$0})
        }
    }
    @Test func textPlanFingerprintIsStableAndVisionPlanIsDistinct() throws {
        let bytes = try configuration().0
        let text = try MiMoLayerStagePlan(configuration:bytes,cut:24)
        let again = try MiMoLayerStagePlan(configuration:bytes,cut:24,visionEnabled:false)
        let vision = try MiMoLayerStagePlan(configuration:bytes,cut:24,visionEnabled:true)
        #expect(text.fingerprint == again.fingerprint)
        #expect(text.fingerprint != vision.fingerprint)
        #expect(text.stages.map(\.fingerprint) == vision.stages.map(\.fingerprint))
        // Decoder stages keep their exact text construction; the extra owned
        // tower is represented in the containing plan/storage commitment.
    }
    @Test func samePromptImagePositionOwnershipChangesActualRequestAgreement() throws {
        let first = try fixture(), second = try fixture(Self.blue)
        #expect(first.tokens == second.tokens)
        let prompt = first.tokens + first.tokens
        let a = first.media.images[0], b = second.media.images[0]
        func owned(_ image: ClusterMiMoImages.Image, at offset: Int) -> ClusterMiMoImages.Image {
            .init(png:image.png,width:image.width,height:image.height,tokenOffset:offset,tokenCount:image.tokenCount)
        }
        let left = ClusterMiMoImages(images:[owned(a,at:a.tokenOffset),owned(b,at:first.tokens.count+b.tokenOffset)])
        let swapped = ClusterMiMoImages(images:[owned(b,at:b.tokenOffset),owned(a,at:first.tokens.count+a.tokenOffset)])
        try left.validate(prompt:prompt);try swapped.validate(prompt:prompt)
        #expect(Set(left.images.map(\.png)) == Set(swapped.images.map(\.png)))
        let profile = try MiMoRegisteredSpecification.specification(.v26FlashMOPD).profile(imageCandidate:true)
        let requestID = UUID(uuidString:"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        func request(_ media:ClusterMiMoImages) throws -> QwenLayerStageGenerationRequest {
            try .init(profile:profile,requestID:requestID,promptTokenIDs:prompt,chunkSize:8,outputCount:4,
                stopTokenIDs:[],mimoImages:media)
        }
        let l = try request(left), r = try request(swapped)
        #expect(l.promptTokenIDs == r.promptTokenIDs && l.requestID == r.requestID)
        #expect(l.fingerprint != r.fingerprint)
        #expect(try request(left).fingerprint == l.fingerprint)
        #expect(try l.planned(reusedPrefix:1,splitFinalToken:true).fingerprint == l.fingerprint)
    }

}
