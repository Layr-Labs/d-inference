import Foundation

/// Closed local-only image selection. This contract grants no public modality
/// qualification and cannot inherit the ordinary GLM text profile's grant.
public struct ClusterGLMImageCandidate: Equatable, Sendable {
    public static let schema = "glm53_rank0_png_candidate_v1"
    public static let textProfileID = "registered_glm53_flash_greedy_generation_v1"
    public static let profileID = textProfileID + "_image_candidate_v1"
    public static let runtimeModelID = "registered_glm53_flash"
    public static let artifactSHA256 = "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac"
    public static let configurationSHA256 = "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b"
    public static let manifestSHA256 = "daee0b1bef9258ae0d8ed98b7a489586f2eb8453453302be057b12008d249649"
    public init() {}
    public static var fields: [String: Any] { [
        "schema": schema, "qualification": "privateUnqualified", "input": ["image/png"], "output": "text",
        "profileID": profileID, "visionOwnerRank": 0,
        "maximumImages": ClusterStillImages.maximumImages, "maximumEncodedBytes": ClusterStillImages.maximumEncodedBytes,
        "maximumSourcePixels": ClusterStillImages.maximumPixels, "maximumFeatures": ClusterStillImages.maximumFeatures,
    ] }
    static func decode(_ object: [String: Any]) throws -> Self {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        try workerRequire(try JSONSerialization.data(withJSONObject: object, options: options)
            == JSONSerialization.data(withJSONObject: fields, options: options), "Unknown GLM image candidate contract")
        return .init()
    }
    public static func validateSource(profileID: String, modelID: String, artifact: String,
                                      configuration: String, manifest: String? = nil) throws {
        try workerRequire(profileID == Self.profileID && modelID == runtimeModelID
            && artifact == artifactSHA256 && configuration == configurationSHA256
            && (manifest == nil || manifest == manifestSHA256), "GLM image candidate source/profile mismatch")
    }
    /// Reused by metadata, installed launcher and native LOAD. Nil is text;
    /// neither an environment flag nor a build containing vision enables media.
    public static func includesVision(runtimeProfile: String?, modelID: String, artifact: String,
                                      configuration: String, manifest: String? = nil) throws -> Bool {
        guard let runtimeProfile, runtimeProfile != textProfileID else { return false }
        try validateSource(profileID: runtimeProfile, modelID: modelID, artifact: artifact,
            configuration: configuration, manifest: manifest)
        return true
    }
}
