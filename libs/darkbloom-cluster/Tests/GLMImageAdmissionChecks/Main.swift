import Foundation
import DarkbloomClusterProtocol
import MLXLMCommon
public struct DistributedRequestDeadlineContext: Sendable {}
enum ClusterConfigurationError: Error { case invalid(String) }
struct ClusterSetupLocalModel { let modelID, artifactSHA256: String }
@main @MainActor enum GLMImageAdmissionChecks {
 static var checks = 0
 static func expect(_ value: Bool, _ name: String) throws { checks += 1; if !value { throw ClusterConfigurationError.invalid(name) } }
 static func refuses(_ name: String, _ body: () throws -> Void) throws {
  do { try body() } catch { checks += 1; return }
  throw ClusterConfigurationError.invalid("accepted " + name)
 }
 static func capability(image: Bool) throws -> ClusterRuntimeCapability {
  let a = ClusterRuntimeAdapter.glm5NextLayerStage
  return try .init(runtimeBinarySHA256: String(repeating: "b", count: 64), adapterID: a.rawValue, adapterVersion: a.version,
   runtimeModelID: ClusterGLMImageCandidate.runtimeModelID, artifactSHA256: ClusterGLMImageCandidate.artifactSHA256,
   configurationSHA256: ClusterGLMImageCandidate.configurationSHA256, manifestSHA256: ClusterGLMImageCandidate.manifestSHA256,
   profile: .init(id: image ? ClusterGLMImageCandidate.profileID : ClusterGLMImageCandidate.textProfileID,
    vocabularySize: 100, maximumPromptTokens: 16, maximumOutputTokens: 4, maximumChunkTokens: 4, maximumContextTokens: 20),
   profileFingerprint: String(repeating: "c", count: 64), partitions: [.init(planSHA256: String(repeating: "d", count: 64), stages: [
    .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: String(repeating: "e", count: 64), constructionConfigurationSHA256: String(repeating: "f", count: 64)),
    .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: String(repeating: "a", count: 64), constructionConfigurationSHA256: String(repeating: "f", count: 64))])],
   arithmeticPolicyID: a.arithmeticPolicyID, arithmeticPolicySHA256: String(repeating: "a", count: 64), glmImages: image ? .init() : nil)
 }
 static func main() throws {
  let png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 32))
  let media = ClusterStillImages(configurationSHA256: ClusterGLMImageCandidate.configurationSHA256,
   images: [.init(png: png, width: 1, height: 1, tokenOffset: 1, tokenCount: 1)])
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  var request = CBv2Request(id: .init(1), promptTokens: [1,2,3], sampling: .init(temperature: 0), maxTokens: 1)
  for id in [ClusterGLMImageCandidate.textProfileID, ClusterGLMImageCandidate.profileID, "foreign", ClusterMiMoImageCandidate.profileID] {
   let profile = try DistributedResidentExecutionProfile(id: id, vocabularySize: 100, maxPromptTokens: 16,
    maxOutputTokens: 4, maxContextTokens: 20, requestTimeout: .seconds(10))
   request.clusterStillImages = nil
   try expect(profile.refusal(for: request) == nil, "text preserved " + id)
   request.clusterStillImages = try encoder.encode(media)
   try expect(profile.refusal(for: request) == (id == ClusterGLMImageCandidate.profileID ? nil : .mediaUnsupported), "media profile " + id)
  }
  func frame(_ profile: String, _ image: ClusterStillImages?) throws -> Data {
   try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: UUID(), sequence: 0, requestID: UUID(), command: .reserve(.init(
    profileID: profile, promptTokenIDs: [1,2,3], stopTokenIDs: [], outputCount: 1, chunkSize: 1,
    deadlineUptimeNanoseconds: 1, capacityLimitBytes: 1024, sampling: nil, stillImages: image))))
  }
  try refuses("ordinary wire media") { _ = try frame(ClusterGLMImageCandidate.textProfileID, media) }
  let wire = try frame(ClusterGLMImageCandidate.profileID, media)
  guard case .reserve(let decoded) = try ClusterWorkerCodec.decodeCommand(wire).command else { fatalError() }
  try expect(decoded.stillImages == media, "candidate wire survives")
  try expect(!String(decoding: try frame(ClusterGLMImageCandidate.textProfileID, nil), as: UTF8.self).contains("stillImages"), "nil wire unchanged")
  let text = try capability(image: false), image = try capability(image: true)
  let textWire = try ClusterRuntimeCapabilityCodec.encode(text), imageWire = try ClusterRuntimeCapabilityCodec.encode(image)
  try expect(!String(decoding: textWire, as: UTF8.self).contains("glmImages"), "nil capability omitted")
  try expect(try ClusterRuntimeCapabilityCodec.decode(textWire) == text, "text codec")
  try expect(try ClusterRuntimeCapabilityCodec.decode(imageWire) == image, "candidate codec")
  let root = try JSONSerialization.jsonObject(with: imageWire) as! [String: Any]
  for key in ["runtimeModelID", "artifactSHA256", "configurationSHA256", "manifestSHA256", "glmImages", "profile"] {
   var changed = root
   switch key {
   case "glmImages": changed.removeValue(forKey: key)
   case "profile": var p = changed[key] as! [String: Any]; p["id"] = ClusterGLMImageCandidate.textProfileID; changed[key] = p
   case "runtimeModelID": changed[key] = ClusterMiMoImageCandidate.runtimeModelID
   default: changed[key] = String(repeating: "0", count: 64)
   }
   var bytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
   try refuses("crossed capability " + key) { _ = try ClusterRuntimeCapabilityCodec.decode(bytes) }
  }
  try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(text); checks += 1
  try refuses("candidate coordinator grant") { try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(image) }
  try expect(ClusterMiMoPrivateImagePolicy.profileArguments(text).isEmpty, "ordinary launch unchanged")
  try expect(ClusterMiMoPrivateImagePolicy.profileArguments(image) == ["--runtime-profile", ClusterGLMImageCandidate.profileID], "candidate launch")
  for pair in [(false,false),(false,true),(true,false)] {
   try refuses("missing installed media guards") { _ = try ClusterMiMoPrivateImagePolicy.launchArguments(image, keyed: pair.0, startupGuard: pair.1) }
  }
  try expect(try ClusterMiMoPrivateImagePolicy.launchArguments(image, keyed: true, startupGuard: true).contains(ClusterGLMImageCandidate.profileID), "guarded launch")
  for profile in [nil, ClusterGLMImageCandidate.textProfileID, ClusterGLMImageCandidate.profileID] as [String?] {
   try expect(try ClusterGLMImageCandidate.includesVision(runtimeProfile: profile, modelID: ClusterGLMImageCandidate.runtimeModelID,
    artifact: ClusterGLMImageCandidate.artifactSHA256, configuration: ClusterGLMImageCandidate.configurationSHA256)
     == (profile == ClusterGLMImageCandidate.profileID), "LOAD does not globally enable vision")
  }
  try refuses("foreign LOAD source") { _ = try ClusterGLMImageCandidate.includesVision(runtimeProfile: ClusterGLMImageCandidate.profileID,
   modelID: "foreign", artifact: ClusterGLMImageCandidate.artifactSHA256, configuration: ClusterGLMImageCandidate.configurationSHA256) }
  try ClusterGLMOnboardingSelection.requireCandidate(image); checks += 1
  try refuses("text fallback on explicit selection") { try ClusterGLMOnboardingSelection.requireCandidate(text) }
  try expect(ClusterGLMOnboardingSelection.accepts(.init(modelID: "glm-5.3-flash", artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)), "local discovery")
  try expect(!ClusterGLMOnboardingSelection.accepts(.init(modelID: "foreign", artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)), "foreign discovery")
  var selection = ClusterOnboardingRequest(scope: .localOnly(bind: "127.0.0.1"), model: "glm-5.3-flash", privateGLMImageQualification: true)
  try expect(selection.privateQualificationRefusal(role: .leader) == nil, "explicit local leader")
  try expect(selection.privateQualificationRefusal(role: .member) != nil, "not forwarded")
  selection.scope = .publicServing
  try expect(selection.privateQualificationRefusal(role: .leader) != nil, "no public selection")
  selection.scope = .localOnly(bind: "127.0.0.1"); selection.privateMiMoImageQualification = true
  try expect(selection.privateQualificationInputRefusal != nil, "no mixed candidates")
  print("PASS GLM image admission: \(checks) CPU checks; ordinary text preserved, explicit local-only profile required")
 }
}
