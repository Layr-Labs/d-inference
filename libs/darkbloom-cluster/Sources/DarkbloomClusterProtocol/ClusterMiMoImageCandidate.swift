import Foundation

/// Closed executable candidate contract. It conveys no readiness, capacity,
/// serving grant or successful modality qualification. Nil media keeps v1 text.
public struct ClusterMiMoImageCandidate: Equatable, Sendable {
    public static let schema = "mimo_v26_rank0_png_candidate_v1"
    public static let profileID = "registered_mimo_v26_flash_mopd_greedy_generation_v1_image_draft_v1"
    public static let adapterID = "mimo-v26-rank0-image-candidate"
    public static let runtimeProfileArgument = "--runtime-profile"
    public static let runtimeModelID = "registered_mimo_v26_flash_mopd"
    public static let artifactSHA256 = "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034"
    public static let configurationSHA256 = "35b6e3d4543b65e6fa9d6174e2260d9ac1d3ea1e5acb9955d9fe9f2b815d13d4"
    public static let manifestSHA256 = "de1bd701115a9ee7e4a99ac85307b31285c63a0b0b1c22ef0c69e9b4ac10f346"
    /// Read from the pinned converted tensor metadata; LOAD recomputes this
    /// inventory from verified descriptors before reading any vision payload.
    public static let visionTensorCount = 364
    public static let visionTensorBytes = 1_457_188_864
    public static let largestVisionTensorBytes = 52_428_800
    public static let visionStorageCommitmentSHA256 = "550bfb0eef9fb6f353bf6989bd0f31e27a9c0d509e9015398b2b81461c60a9c0"
    /// Existing provider default for unmeasured/vision members. This is a
    /// retained reserve, not a shape-derived or measured activation estimate.
    public static let activationFloorBytes = 11 * 1_073_741_824 / 2
    public static let maximumSourcePixels = 262_144
    public static let maximumPreparedPatches = 1_024
    public static let maximumImages = 4
    public static let maximumEncodedBytes = 96 * 1024
    public static let wireWorkingReserveBytes = 12 * maximumEncodedBytes + 2 * ClusterWorkerLimits.commandBytes
    public init() {}

    /// One canonical, closed object shared by metadata producer and consumers.
    public static var fields: [String:Any] { [
        "schema":schema,"qualification":"privateUnqualified","input":["image/png"],"output":"text",
        "visionOwnerRank":0,"positions":"causalCacheOffset1D","profileID":profileID,
        "maximumImages":maximumImages,"maximumEncodedBytes":maximumEncodedBytes,
        "maximumSourcePixels":maximumSourcePixels,"maximumPreparedPatches":maximumPreparedPatches,
        "visionTensorCount":visionTensorCount,"visionTensorBytes":visionTensorBytes,
        "largestVisionTensorBytes":largestVisionTensorBytes,"wireWorkingReserveBytes":wireWorkingReserveBytes,
        "visionStorageCommitmentSHA256":visionStorageCommitmentSHA256,"activationFloorBytes":activationFloorBytes,
    ] }
    static func decode(_ object: [String:Any]) throws -> Self {
        let bytes = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        let canonical = try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
        try workerRequire(bytes == canonical,"Unknown or changed MiMo candidate media contract")
        return .init()
    }
    public static func validateSource(profileID:String, modelID:String, artifact:String, configuration:String, manifest:String) throws {
        try workerRequire(profileID == Self.profileID && modelID == runtimeModelID && artifact == artifactSHA256
            && configuration == configurationSHA256 && manifest == manifestSHA256,"MiMo candidate source/profile mismatch")
    }
}
