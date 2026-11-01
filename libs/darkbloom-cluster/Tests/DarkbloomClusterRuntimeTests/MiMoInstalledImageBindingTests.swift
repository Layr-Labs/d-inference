import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterPlacement
@testable import DarkbloomClusterRuntime

@Suite("MiMo private installed image bindings (CPU metadata)")
struct MiMoInstalledImageBindingTests {
    func fixture(_ name:String) throws -> Data {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf:root.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/"+name))
    }
    func descriptors() throws -> [ClusterPlacementStoredTensor] {
        try JSONDecoder().decode([MiMoCanonicalTensor].self,from:fixture("registered-mimo-v26-flash-mopd.tensor-inventory.json"))
            .map { .init(name:$0.name,byteCount:$0.byteCount,dtype:$0.sourceDType,shape:$0.shape) }
    }
    func capabilities() throws -> (text:ClusterRuntimeCapability,image:ClusterRuntimeCapability) {
        let config = try fixture("registered-mimo-v26-flash-mopd.configuration.json")
        let manifest = try fixture("registered-mimo-v26-flash-mopd.manifest.json")
        // Actual CPU test executable identity, only a metadata caller binding.
        // This never claims that this executable is a qualified/native worker.
        let executable = try #require(Bundle.main.executableURL)
        let binary = sha256(try Data(contentsOf:executable))
        return (try ClusterResidentModelCatalog.describe(configuration:config,manifest:manifest,runtimeBinarySHA256:binary),
            try ClusterResidentModelCatalog.describe(configuration:config,manifest:manifest,runtimeBinarySHA256:binary,
                runtimeProfile:ClusterMiMoImageCandidate.profileID))
    }
    @Test func exactCandidateHasDistinctClosedCanonicalFieldsAndTextBytesStayLegacy() throws {
        let values = try capabilities()
        #expect(values.text.media == nil && values.text.modality == "text")
        #expect(values.image.media != nil && values.image.modality == "text_image_candidate")
        #expect(values.image.adapterID == ClusterMiMoImageCandidate.adapterID)
        #expect(values.image.profile.id == ClusterMiMoImageCandidate.profileID)
        #expect(values.image.profileFingerprint != values.text.profileFingerprint)
        #expect(Set(values.image.partitions.map(\.planSHA256)).isDisjoint(with:values.text.partitions.map(\.planSHA256)))
        #expect(values.image.supportedGenerationModes == [.pipeline,.pipelineCompactDecode,.pipelineMTP])
        let bytes = try ClusterRuntimeCapabilityCodec.encode(values.image)
        #expect(try ClusterRuntimeCapabilityCodec.decode(bytes) == values.image)
        let object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        let golden = try JSONSerialization.jsonObject(with:fixture("mimo-image-candidate.media.json")) as! NSDictionary
        #expect((object["media"] as! NSDictionary) == golden)
        let legacy = try ClusterRuntimeCapabilityCodec.encode(values.text)
        #expect(!String(decoding:legacy,as:UTF8.self).contains("\"media\""))
        #expect(try ClusterRuntimeCapabilityCodec.encode(ClusterRuntimeCapabilityCodec.decode(legacy)) == legacy)
    }
    @Test func missingMediaChangedResourcesForeignArtifactAndApprovalClaimsAreRefused() throws {
        let value = try capabilities().image
        let object = try JSONSerialization.jsonObject(with:ClusterRuntimeCapabilityCodec.encode(value)) as! [String:Any]
        func refuse(_ edit:(inout [String:Any])->Void) throws {
            var changed = object;edit(&changed)
            var data = try JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys,.withoutEscapingSlashes]);data.append(10)
            #expect(throws:(any Error).self) { try ClusterRuntimeCapabilityCodec.decode(data) }
        }
        try refuse { $0.removeValue(forKey:"media") }
        try refuse { var m=$0["media"] as! [String:Any];m["qualification"]="approved";$0["media"]=m }
        try refuse { var m=$0["media"] as! [String:Any];m["visionTensorBytes"]=0;$0["media"]=m }
        try refuse { $0["artifactSHA256"]=String(repeating:"0",count:64) }
        try refuse { $0["supportedGenerationModes"]=["pipeline_v1","phase_split_v1"] }
        try refuse { $0["servingGrant"]=true }
    }
    @Test func rankZeroLayoutAddsOnlyActualVisionStorageAndConservativeWorkBesideKV() throws {
        let c = try fixture("registered-mimo-v26-flash-mopd.configuration.json"),t = try descriptors()
        let text = try ClusterPlacementLayouts.layout(configuration:c,tensors:t)
        let image = try ClusterPlacementLayouts.layout(configuration:c,tensors:t,runtimeProfile:ClusterMiMoImageCandidate.profileID)
        #expect(image.ingress.loadedBytes-text.ingress.loadedBytes == ClusterMiMoImageCandidate.visionTensorBytes)
        #expect(image.ingress.tensorCount-text.ingress.tensorCount == ClusterMiMoImageCandidate.visionTensorCount)
        #expect(image.ingress.requestWorkBytes-text.ingress.requestWorkBytes == ClusterMiMoImageCandidate.activationFloorBytes)
        #expect(image.egress.loadedBytes == text.egress.loadedBytes && image.egress.tensorCount == text.egress.tensorCount)
        #expect(image.egress.requestWorkBytes-text.egress.requestWorkBytes == ClusterMiMoImageCandidate.wireWorkingReserveBytes)
        #expect(image.layers == text.layers)
        #expect(image.speculativeHead == text.speculativeHead)
        #expect(image.generationModes == [.pipeline,.pipelineCompactDecode,.pipelineMTP])
        var bad = t;bad.removeAll { $0.name == "vision_tower.patch_embed.proj.weight" }
        #expect(throws:(any Error).self) {
            try ClusterPlacementLayouts.layout(configuration:c,tensors:bad,runtimeProfile:ClusterMiMoImageCandidate.profileID)
        }
    }
    @Test func nativeFloorIsAdditiveAndImageContractUsesPinnedSource() throws {
        let config = try fixture("registered-mimo-v26-flash-mopd.configuration.json")
        let spec = try MiMoRegisteredSpecification.specification(configuration:config)
        let plan = try MiMoLayerStagePlan(configuration:config,cut:24,visionEnabled:true)
        let base = try MiMoResidentRequestAllowance.derive(specification:spec,plan:plan,rank:0,maximumTokens:128,chunkSize:16)
        let image = try MiMoResidentRequestAllowance.derive(specification:spec,plan:plan,rank:0,maximumTokens:128,chunkSize:16,imageCandidate:true)
        let rank1 = try MiMoResidentRequestAllowance.derive(specification:spec,plan:plan,rank:1,maximumTokens:128,chunkSize:16,imageCandidate:true)
        #expect(image.reservedBytes-base.reservedBytes == ClusterMiMoImageCandidate.activationFloorBytes)
        #expect(rank1.imageBytes == ClusterMiMoImageCandidate.wireWorkingReserveBytes)
        #expect(ClusterRuntimeAdapter.registering(runtimeModelID:spec.model.rawValue) == .mimoV26LayerStage)
    }
}
