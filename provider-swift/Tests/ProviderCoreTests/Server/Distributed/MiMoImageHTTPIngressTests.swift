import Foundation
import CryptoKit
import Testing
import MLXLMCommon
import DarkbloomClusterProtocol
@testable import ProviderCore

private final class MiMoImageHTTPFixtureSession: DistributedLocalServerSession, @unchecked Sendable {
    let model:DistributedInstalledModel
    let profile:DistributedResidentExecutionProfile
    let expectedIdentity:DistributedResidentIdentity
    private let lock = NSLock()
    private var phase:DistributedInstalledSessionStatus = .prepared
    private var items:[(CBv2Request,DistributedTestLease)] = []
    init(directory:URL) throws {
        let config = try Data(contentsOf:directory.appendingPathComponent("config.json"))
        let digest = SHA256.hash(data:config).map { String(format:"%02x",$0) }.joined()
        guard digest == ClusterMiMoImageCandidate.configurationSHA256 else { throw DistributedEngineError.unavailable }
        let executable = try #require(Bundle.main.executableURL)
        let build = SHA256.hash(data:try Data(contentsOf:executable)).map { String(format:"%02x",$0) }.joined()
        expectedIdentity = .init(membershipEpoch:UUID(),modelID:ClusterMiMoImageCandidate.runtimeModelID,
            artifactSHA256:ClusterMiMoImageCandidate.artifactSHA256,configurationSHA256:digest,
            peers:[.init(id:"cpu-fixture-0",buildSHA256:build),.init(id:"cpu-fixture-1",buildSHA256:build)])
        profile = try .init(id:ClusterMiMoImageCandidate.profileID,vocabularySize:152576,
            maxPromptTokens:32767,maxOutputTokens:4096,maxContextTokens:32768,requestTimeout:.seconds(30))
        model = .init(publicModelID:"private-mimo-host-contract-fixture",directory:directory,modelType:"mimo_v2",
            eosTokenIDs:[151643,151645,151672],vocabularySize:152576)
    }
    var status:DistributedInstalledSessionStatus { lock.withLock { phase } }
    var httpAdmissionAvailable:Bool { status == .ready }
    var httpSessionInvalid:Bool { false }
    func validateModelInputs() throws {}
    func start() async throws { lock.withLock { phase = .ready } }
    func stop(until:UInt64) async -> DistributedInstalledSessionStatus { await shutdown();return status }
    func drain(until:UInt64) async -> DistributedInstalledSessionStatus { status }
    func shutdown() async { lock.withLock { phase = .released } }
    func readiness() -> DistributedResidentReadiness? {
        status == .ready ? .init(identity:expectedIdentity,profileID:profile.id,requestCapacityBytes:1<<20) : nil
    }
    func setReadinessInvalidationHandler(_ handler:@escaping @Sendable ()->Void) {}
    func projectFirstToken(_ request:CBv2Request,admission:CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason:nil)
    }
    func reserve(_ request:CBv2Request,identity:DistributedResidentIdentity,profileID:String,capacityLimit:Int)
        throws -> any DistributedResidentRequestLease {
        guard identity == expectedIdentity,profileID == profile.id else { throw DistributedEngineError.unavailable }
        let lease = DistributedTestLease(identity:identity,requestID:request.id)
        lock.withLock { items.append((request,lease)) };return lease
    }
    func reserve(_ request:CBv2Request,identity:DistributedResidentIdentity,profileID:String,capacityLimit:Int,
                 deadlineContext:DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try reserve(request,identity:identity,profileID:profileID,capacityLimit:capacityLimit)
    }
    var itemCount:Int { lock.withLock { items.count } }
    func item(_ index:Int) -> (CBv2Request,DistributedTestLease)? { lock.withLock { items.indices.contains(index) ? items[index] : nil } }
}

/// Host transport regression only. It uses the actual HTTP decoder, history
/// normalizer, pinned tokenizer, SDK geometry, bridge and distributed admission.
/// A scripted lease completes output; there is NO model/GPU/quality assertion.
@Suite("MiMo image actual HTTP host ingress (CPU)",.serialized,.timeLimit(.minutes(3)))
struct MiMoImageHTTPIngressTests {
    @Test func chatResponsesAndHistoryCarryActualPixelsIntoBoundedWire() async throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath:try #require(env["MIMO_CLUSTER_IMAGE_METADATA_DIR"],"Set existing pinned metadata directory; no download"))
        let assetDirectory = URL(fileURLWithPath:try #require(env["MIMO_CLUSTER_IMAGE_ASSET_DIR"]))
        let red = try Data(contentsOf:assetDirectory.appendingPathComponent("red-square.png"))
        let blue = try Data(contentsOf:assetDirectory.appendingPathComponent("blue-square.png"))
        let tokenizer = try await LocalTokenizerLoader().load(from:directory)
        let handle = TokenizerHandle(tokenizer)
        let session = try MiMoImageHTTPFixtureSession(directory:directory)
        let host = DistributedLocalServer(session:session,config:.init(host:"127.0.0.1",port:0,authToken:nil),
            tokenizerLoader:{ _ in handle })
        try await host.start()
        let port = try #require(await host.status.boundPort)
        do {
            var bindings:[String] = []
            for (index,png) in [red,red,blue,red].enumerated() {
                let uri = "data:image/png;base64,"+png.base64EncodedString()
                let parts:[[String:Any]] = [["type":"text","text":"State the dominant color."],
                    ["type":"image_url","image_url":["url":uri]]]
                var body:[String:Any] = ["model":session.model.publicModelID,"max_tokens":16,"temperature":0,
                    "enable_thinking":false,"messages":[["role":"user","content":parts],
                    ["role":"assistant","content":"Prior turn."],["role":"user","content":"Now answer briefly."]]]
                var route = "/v1/chat/completions"
                if index == 3 {
                    route = "/v1/responses"
                    body = ["model":session.model.publicModelID,"max_output_tokens":16,"enable_thinking":false,
                        "input":[["role":"user","content":[["type":"input_text","text":"Color?"],
                            ["type":"input_image","image_url":uri]]]]]
                }
                let requestBody = try JSONSerialization.data(withJSONObject:body)
                let endpoint = URL(string:"http://127.0.0.1:\(port)"+route)!
                let result = Task { () throws -> (Data,URLResponse) in
                    var request = URLRequest(url:endpoint)
                    request.httpMethod="POST";request.timeoutInterval=15
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                    request.httpBody=requestBody
                    return try await URLSession.shared.data(for:request)
                }
                let end = ContinuousClock.now.advanced(by:.seconds(10))
                while (session.item(index)?.1.startCount ?? 0) == 0,ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(5)) }
                let item = try #require(session.item(index)),wire = try #require(item.0.mimoClusterImages)
                let media = try ClusterMiMoImages.decodeBounded(wire)
                try media.validate(prompt:item.0.promptTokens)
                #expect(media.images.count == 1 && media.images[0].png == png)
                bindings.append(media.fingerprint)
                // Scripted transport output only: never treated as model perception.
                for token in tokenizer.encode(text:"host fixture complete",addSpecialTokens:false) { _ = item.1.send(.token(token)) }
                _ = item.1.send(.finished(.stop));item.1.acknowledge()
                let response = try await result.value
                #expect((response.1 as? HTTPURLResponse)?.statusCode == 200)
            }
            #expect(bindings[0] == bindings[1] && bindings[1] != bindings[2])
            // Malformed media fails through actual HTTP before any reservation.
            let count = session.itemCount
            var bad = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/chat/completions")!)
            bad.httpMethod="POST";bad.timeoutInterval=10
            bad.setValue("application/json",forHTTPHeaderField:"Content-Type")
            bad.httpBody=try JSONSerialization.data(withJSONObject:["model":session.model.publicModelID,
                "max_tokens":8,"messages":[["role":"user","content":[["type":"image_url",
                    "image_url":["url":"data:image/png;base64,AA=="]]]]]])
            let rejected = try await URLSession.shared.data(for:bad)
            #expect((rejected.1 as? HTTPURLResponse)?.statusCode == 400)
            #expect(session.itemCount == count)
        } catch {
            _ = await host.stop(until:DispatchTime.now().uptimeNanoseconds+2_000_000_000);throw error
        }
        _ = await host.stop(until:DispatchTime.now().uptimeNanoseconds+2_000_000_000)
    }
}
