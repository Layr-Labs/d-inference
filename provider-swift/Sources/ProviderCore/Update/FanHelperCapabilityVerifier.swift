import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum FanHelperCapabilityVerifier {
    static let binaryCapability = "darkbloom-fan-helper-v1"
    static let markerRelativePath =
        "Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    static let helperRelativePath = "Contents/Helpers/darkbloom-fan-helper"

    static func binaryContainsCapability(_ executable: URL) throws -> Bool {
        let data = try Data(contentsOf: executable, options: [.mappedIfSafe])
        return data.range(of: Data(binaryCapability.utf8)) != nil
    }

    static func verify(
        app: URL,
        executable: URL,
        signaturePolicy: DarkbloomCodeSignature.Policy?
    ) throws {
        let fileManager = FileManager.default
        let codePresent = try binaryContainsCapability(executable)
        let marker = app.appendingPathComponent(markerRelativePath)
        let helper = app.appendingPathComponent(helperRelativePath)
        let markerPresent = fileManager.fileExists(atPath: marker.path)
        let helperPresent = fileManager.fileExists(atPath: helper.path)

        guard codePresent || markerPresent || helperPresent else {
            return // pre-fan release compatibility
        }
        guard codePresent, markerPresent, helperPresent else {
            throw UpdateError.replaceFailed(
                "fan-capable artifact requires matching CLI code, signed marker, and nested helper"
            )
        }
        try requireRegularFile(marker, executable: false, label: "fan capability marker")
        try requireRegularFile(helper, executable: true, label: "fan helper")
        guard
            let markerValue = try? String(contentsOf: marker, encoding: .utf8),
            markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        else {
            throw UpdateError.replaceFailed("fan helper capability marker is invalid")
        }

        guard let signaturePolicy else { return }
        let helperPolicy: DarkbloomCodeSignature.Policy =
            signaturePolicy == .structuralForIsolatedTest
            ? .structuralForIsolatedTest
            : .darkbloomFanHelper
        do {
            try DarkbloomCodeSignature.verify(
                helper,
                deep: false,
                policy: helperPolicy
            )
        } catch {
            throw UpdateError.replaceFailed(
                "fan helper code signature verification failed: \(error.localizedDescription)"
            )
        }
    }

    static func rejectFanCapableFlatExecutable(_ executable: URL) throws {
        guard try binaryContainsCapability(executable) else { return }
        throw UpdateError.replaceFailed(
            "fan-capable releases require the signed Darkbloom.app layout"
        )
    }

    private static func requireRegularFile(
        _ url: URL,
        executable: Bool,
        label: String
    ) throws {
        #if canImport(Darwin)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw UpdateError.replaceFailed("\(label) must be a regular non-symlink file")
        }
        if executable,
           metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0
        {
            throw UpdateError.replaceFailed("\(label) is not executable")
        }
        #else
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UpdateError.replaceFailed("\(label) is missing")
        }
        #endif
    }
}
