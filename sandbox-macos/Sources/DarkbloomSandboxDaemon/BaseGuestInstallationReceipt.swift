import Foundation
import SandboxCore

/// Schema1 evidence remains the explicit legacy bootstrap-retirement format.
struct BaseGuestInstallationReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let guestSHA256: String
    let bootstrapSHA256: String
    let launchdSHA256: String
    let installerSHA256: String
    let guestOperatingSystemVersion: String
    let guestArchitecture: String
    let bootstrapRetired: Bool

    func validate(release: BaseGuestRelease) throws {
        guard schemaVersion == 1, bootstrapRetired, guestArchitecture == "arm64",
              !guestOperatingSystemVersion.isEmpty, guestOperatingSystemVersion.utf8.count < 64,
              guestSHA256 == release.hashes["darkbloom-sandbox-guest"],
              bootstrapSHA256 == release.hashes["darkbloom-sandbox-bootstrap.sh"],
              launchdSHA256 == release.hashes["io.darkbloom.sandbox.guest.plist"],
              installerSHA256 == release.hashes["install-sandbox-guest.sh"] else {
            throw BaseGuestPreparationError.invalidReceipt
        }
    }
}


/// Decoding chooses an explicit historical format; it never converts schema1
/// retirement evidence into accountless installation or native qualification.
enum BaseGuestInstallationRecord: Decodable, Equatable {
    case legacy(BaseGuestInstallationReceipt)
    case accountless(SandboxAccountlessInstallationReceipt)

    private enum VersionKey: String, CodingKey { case schemaVersion }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: VersionKey.self)
        switch try value.decode(Int.self, forKey: .schemaVersion) {
        case 1: self = .legacy(try BaseGuestInstallationReceipt(from: decoder))
        case 2: self = .accountless(try SandboxAccountlessInstallationReceipt(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: value,
                debugDescription: "Unsupported installation receipt version")
        }
    }
}

extension SandboxAccountlessInstallationReceipt {
    func validate(release: BaseGuestRelease, source expected: SandboxGuestBaseSource) throws {
        let files = Dictionary(uniqueKeysWithValues: release.hashes.map { ("guest/" + $0.key, $0.value) })
        guard installationComplete, source == expected, payload.matchesGuestFiles(files),
              payload.releaseManifestSHA256 == release.manifestSHA256 else {
            throw BaseGuestPreparationError.invalidReceipt
        }
    }
}
