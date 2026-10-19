import Foundation
import CryptoKit
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
@testable import ProviderCore

@Suite("Private MiMo image installed policy (CPU)")
struct MiMoInstalledImagePolicyTests {
    func capability(image:Bool) throws -> ClusterRuntimeCapability {
        var root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        while root.lastPathComponent != "provider-swift",root.path != "/" { root.deleteLastPathComponent() }
        root.deleteLastPathComponent()
        let fixtures = root.appendingPathComponent("libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
        let executable = try #require(Bundle.main.executableURL)
        let digest = SHA256.hash(data:try Data(contentsOf:executable)).map { String(format:"%02x",$0) }.joined()
        return try MiMoResidentCapabilityMetadata.describe(
            configuration:Data(contentsOf:fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json")),
            manifest:Data(contentsOf:fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.manifest.json")),
            runtimeBinarySHA256:digest,imageCandidate:image)
    }
    @Test func exactProfileArgumentsAndFeatureGuardsAreRequiredOnlyForCandidate() throws {
        let image = try capability(image:true),text = try capability(image:false)
        #expect(ClusterMiMoPrivateImagePolicy.profileArguments(text).isEmpty)
        #expect(ClusterMiMoPrivateImagePolicy.profileArguments(image) == ["--runtime-profile",ClusterMiMoImageCandidate.profileID])
        #expect(try ClusterMiMoPrivateImagePolicy.launchArguments(text,keyed:false,startupGuard:false).isEmpty)
        #expect(try ClusterMiMoPrivateImagePolicy.launchArguments(image,keyed:true,startupGuard:true)
            == ["--runtime-profile",ClusterMiMoImageCandidate.profileID,"--qualification-switches","yes"])
        for pair in [(false,false),(true,false),(false,true)] {
            #expect(throws:(any Error).self) { try ClusterMiMoPrivateImagePolicy.launchArguments(image,keyed:pair.0,startupGuard:pair.1) }
        }
        let old = DistributedInstalledWorkerFeatures(hasProgressGuard:true,acceptsStartupDeadline:true,acceptsDataPlane:true)
        try old.requireMiMoImageCandidate(required:false)
        #expect(throws:(any Error).self) { try old.requireMiMoImageCandidate(required:true) }
        let current = DistributedInstalledWorkerFeatures(hasProgressGuard:true,acceptsStartupDeadline:true,
            acceptsDataPlane:true,acceptsMiMoImageCandidate:true)
        try current.requireMiMoImageCandidate(required:true)
    }
    @Test func candidateCannotRegisterPubliclyAndUnmeasuredActivationFloorMatchesProvider() throws {
        let image = try capability(image:true),text = try capability(image:false)
        try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(text)
        #expect(throws:(any Error).self) { try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(image) }
        #expect(UInt64(ClusterMiMoImageCandidate.activationFloorBytes) == UnifiedMemoryCap.defaultActivationReserveBytes)
        #expect(ClusterRuntimeAdapter.registering(runtimeModelID:ClusterMiMoImageCandidate.runtimeModelID) == .mimoV26LayerStage)
    }
}
