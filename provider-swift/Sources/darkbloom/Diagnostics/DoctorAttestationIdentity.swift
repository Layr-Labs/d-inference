import Foundation
import ProviderCore

enum DoctorAttestationIdentityUnavailable: Equatable {
    case daemonStateMissing
    case daemonProcessIdentityNotReported
    case daemonProcessMismatch
    case daemonStateStale(ageSeconds: Int)
    case signerIdentityNotReported

    var detail: String {
        switch self {
        case .daemonStateMissing:
            return "cannot match coordinator trust: no readable daemon state; "
                + "start or restart the provider and retry"
        case .daemonProcessIdentityNotReported:
            return "cannot match coordinator trust: daemon state does not identify the "
                + "exact provider process; restart with the current provider version"
        case .daemonProcessMismatch:
            return "cannot match coordinator trust: daemon state does not belong to the "
                + "currently running provider process"
        case .daemonStateStale(let ageSeconds):
            return "cannot match coordinator trust: running daemon state is stale "
                + "(last update \(ageSeconds)s ago); wait for a fresh update or restart the provider"
        case .signerIdentityNotReported:
            return "cannot match coordinator trust: fresh running daemon state does not "
                + "report its attestation signer key; restart with the current provider version"
        }
    }
}

enum DoctorAttestationIdentityResolution: Equatable {
    case available(publicKey: String)
    case unavailable(DoctorAttestationIdentityUnavailable)
}

func doctorDaemonProcessMatches(
    daemonState: DaemonState?,
    readProcessIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
) -> Bool {
    guard
        let daemonState,
        let recordedProcess = daemonState.processIdentity,
        recordedProcess.pid == daemonState.pid
    else {
        return false
    }
    return readProcessIdentity(recordedProcess.pid) == recordedProcess
}

/// Resolves the exact attestation identity owned by the live provider process.
/// `doctor` must not load or create a Secure Enclave key: the daemon may be
/// using an injected or ephemeral signer that differs from any persistent key.
func resolveDoctorAttestationIdentity(
    daemonState: DaemonState?,
    now: Double = Date().timeIntervalSince1970,
    readProcessIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
) -> DoctorAttestationIdentityResolution {
    guard let daemonState else {
        return .unavailable(.daemonStateMissing)
    }
    guard daemonState.processIdentity != nil else {
        return .unavailable(.daemonProcessIdentityNotReported)
    }
    guard doctorDaemonProcessMatches(
        daemonState: daemonState,
        readProcessIdentity: readProcessIdentity
    ) else {
        return .unavailable(.daemonProcessMismatch)
    }
    guard !daemonState.isStale(now: now) else {
        return .unavailable(
            .daemonStateStale(ageSeconds: Int(daemonState.ageSeconds(now: now).rounded())))
    }
    guard
        let publicKey = daemonState.attestationPublicKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !publicKey.isEmpty
    else {
        return .unavailable(.signerIdentityNotReported)
    }
    return .available(publicKey: publicKey)
}

struct ProviderAttestationList: Decodable {
    let providers: [ProviderAttestation]
}

struct ProviderAttestation: Decodable {
    let providerID: String
    let chipName: String
    let hardwareModel: String
    let sePublicKey: String
    let trustLevel: String
    let status: String
    let mdmVerified: Bool
    let mdaVerified: Bool
    let secureEnclave: Bool
    let sipEnabled: Bool
    let secureBootEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case chipName = "chip_name"
        case hardwareModel = "hardware_model"
        case sePublicKey = "se_public_key"
        case trustLevel = "trust_level"
        case status
        case mdmVerified = "mdm_verified"
        case mdaVerified = "mda_verified"
        case secureEnclave = "secure_enclave"
        case sipEnabled = "sip_enabled"
        case secureBootEnabled = "secure_boot_enabled"
    }
}

func selectProviderAttestation(
    from data: Data,
    matchingSEPublicKey sePublicKey: String
) throws -> ProviderAttestation? {
    let decoded = try JSONDecoder().decode(ProviderAttestationList.self, from: data)
    return decoded.providers
        .filter { $0.sePublicKey == sePublicKey }
        .sorted(by: providerTrustSort)
        .first
}

private func providerTrustSort(_ lhs: ProviderAttestation, _ rhs: ProviderAttestation) -> Bool {
    func score(_ provider: ProviderAttestation) -> Int {
        var total = 0
        if provider.status == "online" { total += 100 }
        if provider.trustLevel == "hardware" { total += 50 }
        if provider.mdaVerified { total += 10 }
        if provider.mdmVerified { total += 5 }
        return total
    }
    return score(lhs) > score(rhs)
}
