import Foundation

/// Fail-closed identity preflight for benchmark evidence captured from a
/// packaged release candidate.
///
/// `Verified` cannot be constructed outside ProviderCore. The benchmark target
/// can therefore label evidence as signed only after this verifier has checked
/// the running app, its designated requirement, version, and exact registered
/// executable hash.
public enum SignedReleaseIdentity {
    public static let identifier = "io.darkbloom.provider"
    public static let teamID = "SLDQ2GJ6TL"

    public struct Verified: Sendable, Equatable {
        public let identifier: String
        public let teamID: String
        public let providerVersion: String
        public let executableName: String
        public let executableSHA256: String
        public let expectedExecutableSHA256: String
        public let expectedVersion: String

        fileprivate init(
            providerVersion: String,
            executableName: String,
            executableSHA256: String,
            expectedExecutableSHA256: String,
            expectedVersion: String
        ) {
            identifier = SignedReleaseIdentity.identifier
            teamID = SignedReleaseIdentity.teamID
            self.providerVersion = providerVersion
            self.executableName = executableName
            self.executableSHA256 = executableSHA256
            self.expectedExecutableSHA256 = expectedExecutableSHA256
            self.expectedVersion = expectedVersion
        }
    }

    public enum VerificationError: Error, CustomStringConvertible, Sendable {
        case invalidExpectedBinaryHash
        case invalidExpectedVersion
        case nonReleaseBuild
        case executableUnavailable
        case notPackagedMainExecutable
        case signatureInvalid(String)
        case binaryHashUnavailable
        case binaryHashMismatch(expected: String, actual: String)
        case versionMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case .invalidExpectedBinaryHash:
                "expected registered binary hash must be 64 lowercase hexadecimal characters"
            case .invalidExpectedVersion:
                "expected version must be a non-empty canonical version string"
            case .nonReleaseBuild:
                "signed evidence requires a release-configuration executable"
            case .executableUnavailable:
                "cannot resolve the running executable"
            case .notPackagedMainExecutable:
                "signed evidence requires Darkbloom.app/Contents/MacOS/darkbloom "
                    + "as the running bundle main executable"
            case .signatureInvalid(let detail):
                "signed release identity verification failed: \(detail)"
            case .binaryHashUnavailable:
                "cannot hash the running signed executable"
            case .binaryHashMismatch(let expected, let actual):
                "registered binary SHA-256 mismatch: expected \(expected), got \(actual)"
            case .versionMismatch(let expected, let actual):
                "provider version mismatch: expected \(expected), got \(actual)"
            }
        }
    }

    public static func verifyCurrent(
        expectedBinarySHA256: String,
        expectedVersion: String
    ) throws -> Verified {
        try verify(
            expectedBinarySHA256: expectedBinarySHA256,
            expectedVersion: expectedVersion,
            dependencies: .live)
    }

    struct Dependencies: @unchecked Sendable {
        let processExecutableURL: () -> URL?
        let bundleExecutableURL: () -> URL?
        let bundleURL: () -> URL?
        let isReleaseBuild: () -> Bool
        let providerVersion: () -> String
        let hashExecutable: (URL) -> String?
        let verifySignature: (URL, Bool) throws -> Void

        static let live = Dependencies(
            processExecutableURL: {
                executablePath().map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                }
            },
            bundleExecutableURL: {
                Bundle.main.executableURL?.resolvingSymlinksInPath()
            },
            bundleURL: {
                Bundle.main.bundleURL.resolvingSymlinksInPath()
            },
            isReleaseBuild: {
                #if DEBUG
                false
                #else
                true
                #endif
            },
            providerVersion: { ProviderCore.version },
            hashExecutable: { hashFile(atPath: $0.path) },
            verifySignature: { url, deep in
                try DarkbloomCodeSignature.verify(url, deep: deep)
            })
    }

    static func verify(
        expectedBinarySHA256: String,
        expectedVersion: String,
        dependencies: Dependencies
    ) throws -> Verified {
        guard isLowercaseSHA256(expectedBinarySHA256) else {
            throw VerificationError.invalidExpectedBinaryHash
        }
        guard !expectedVersion.isEmpty,
            expectedVersion == expectedVersion.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !expectedVersion.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw VerificationError.invalidExpectedVersion
        }
        guard dependencies.isReleaseBuild() else {
            throw VerificationError.nonReleaseBuild
        }
        guard let processExecutable = dependencies.processExecutableURL(),
            let bundleExecutable = dependencies.bundleExecutableURL(),
            let bundleURL = dependencies.bundleURL()
        else {
            throw VerificationError.executableUnavailable
        }

        let executable = processExecutable.resolvingSymlinksInPath()
        let canonicalBundleExecutable = bundleExecutable.resolvingSymlinksInPath()
        let app = bundleURL.resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent()
            .deletingLastPathComponent()
        guard executable == canonicalBundleExecutable,
            executable.lastPathComponent == "darkbloom",
            executable.deletingLastPathComponent().lastPathComponent == "MacOS",
            contents.lastPathComponent == "Contents",
            contents.deletingLastPathComponent() == app,
            app.lastPathComponent == "Darkbloom.app"
        else {
            throw VerificationError.notPackagedMainExecutable
        }

        do {
            try dependencies.verifySignature(app, true)
        } catch {
            throw VerificationError.signatureInvalid(String(describing: error))
        }

        guard let actualHash = dependencies.hashExecutable(executable)?.lowercased(),
            isLowercaseSHA256(actualHash)
        else {
            throw VerificationError.binaryHashUnavailable
        }
        guard actualHash == expectedBinarySHA256 else {
            throw VerificationError.binaryHashMismatch(
                expected: expectedBinarySHA256,
                actual: actualHash)
        }

        let actualVersion = dependencies.providerVersion()
        guard actualVersion == expectedVersion else {
            throw VerificationError.versionMismatch(
                expected: expectedVersion,
                actual: actualVersion)
        }
        return Verified(
            providerVersion: actualVersion,
            executableName: executable.lastPathComponent,
            executableSHA256: actualHash,
            expectedExecutableSHA256: expectedBinarySHA256,
            expectedVersion: expectedVersion)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}
