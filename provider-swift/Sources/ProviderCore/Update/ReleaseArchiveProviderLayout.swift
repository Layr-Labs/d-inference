import Foundation

/// Additional graph constraints for the sole symlink accepted in a release.
/// Metadata is bounded and checked before extraction; no link is followed here.
struct ReleaseArchiveProviderLayout {
    private static let app = "Darkbloom.app"
    static let alias = app + "/" + ProviderAppLayout.aliasRelativePath
    private static let helper = app + "/" + ProviderAppLayout.helperRelativePath
    private static let metadataPaths = [
        app + "/Contents/Info.plist", helper + "/Contents/Info.plist",
        app + "/Contents/embedded.provisionprofile", helper + "/Contents/embedded.provisionprofile",
    ]
    private var nodes: [String: ReleaseArchiveNodeKind] = [:]
    private var metadata: [String: Data] = [:]
    private var containsHelper = false

    static func validateAlias(path: String, target: [UInt8], size: UInt64, trailingSlash: Bool) throws {
        guard path == alias, target == Array(ProviderAppLayout.aliasTarget.utf8),
              size == 0, !trailingSlash
        else {
            throw ReleaseArchivePreflightError("release archive uses unsupported node type symlink; only the exact provider alias is allowed")
        }
    }

    mutating func add(path: String, kind: ReleaseArchiveNodeKind) {
        nodes[path] = kind
        if path == Self.helper || path.hasPrefix(Self.helper + "/") { containsHelper = true }
    }

    func needsMetadata(_ path: String) -> Bool { Self.metadataPaths.contains(path) }

    mutating func recordMetadata(path: String, data: Data) { metadata[path] = data }

    func validate() throws {
        guard containsHelper || nodes[Self.alias] == .providerAlias else { return }
        guard nodes[Self.alias] == .providerAlias else {
            throw ReleaseArchivePreflightError("nested provider archive is missing its exact CLI alias")
        }
        let directories = [
            Self.app, Self.app + "/Contents", Self.app + "/Contents/MacOS",
            Self.app + "/Contents/Resources", Self.app + "/Contents/Helpers",
            Self.helper, Self.helper + "/Contents", Self.helper + "/Contents/MacOS",
            Self.helper + "/Contents/Resources",
        ]
        for path in directories where nodes[path] != .directory {
            throw ReleaseArchivePreflightError("nested provider archive requires directory \(path)")
        }
        let files = Self.metadataPaths + [
            Self.app + "/Contents/MacOS/DarkbloomApp",
            Self.app + "/Contents/MacOS/darkbloom-enclave",
            Self.app + "/Contents/MacOS/mlx.metallib",
            Self.helper + "/Contents/MacOS/darkbloom",
            Self.helper + "/Contents/MacOS/darkbloom-enclave",
            Self.helper + "/Contents/MacOS/mlx.metallib",
        ]
        for path in files where nodes[path] != .regular {
            throw ReleaseArchivePreflightError("nested provider archive requires regular file \(path)")
        }
        guard let outerInfo = metadata[Self.metadataPaths[0]],
              let helperInfo = metadata[Self.metadataPaths[1]],
              let outerProfile = metadata[Self.metadataPaths[2]],
              let helperProfile = metadata[Self.metadataPaths[3]],
              !outerProfile.isEmpty, outerProfile == helperProfile
        else {
            throw ReleaseArchivePreflightError("nested provider archive requires matching provisioning profiles")
        }
        do {
            try ProviderAppLayout.validateNestedMetadata(outer: outerInfo, helper: helperInfo)
        } catch {
            throw ReleaseArchivePreflightError("nested provider archive metadata is invalid: \(error)")
        }
    }
}
