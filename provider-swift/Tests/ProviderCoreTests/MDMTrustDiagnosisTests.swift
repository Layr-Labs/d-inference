import Testing
@testable import ProviderCore

// MARK: - MDMTrustDiagnosis (pure verdict logic)

/// The P1.5 case: a Mac enrolled in Darkbloom MDM whose coordinator-side live
/// MDM SecurityInfo check keeps timing out stays at trust=self_signed and earns
/// nothing — but `darkbloom doctor` used to print nothing for it. These tests
/// pin the inference: self_signed + online + enrolledDarkbloom ⇒ a clear WARN
/// that is DISTINCT from the "not enrolled at all" warning.
@Suite struct MDMTrustDiagnosisTests {

    @Test func selfSignedOnlineEnrolledInDarkbloomWarnsAboutPendingMDMCheck() throws {
        let d = MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed",
            status: "online",
            enrollment: .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect"))
        let diag = try #require(d)
        #expect(diag.section == .trust)
        #expect(diag.level == .warn)
        #expect(diag.name == "mdm verification")
        // The operator must understand: enrolled, but the coordinator's MDM
        // check hasn't completed, so no traffic yet.
        #expect(diag.message.lowercased().contains("enrolled"))
        #expect(diag.message.lowercased().contains("securityinfo"))
        #expect(diag.message.contains("self_signed"))
        #expect(diag.message.lowercased().contains("no traffic"))
        // Concrete, actionable fix: keep awake / APNs / wait, then check Profiles.
        let fix = try #require(diag.fix)
        #expect(fix.lowercased().contains("awake"))
        #expect(fix.lowercased().contains("apns"))
        #expect(fix.lowercased().contains("15 min"))
        #expect(fix.contains("Pending"))
        #expect(fix.lowercased().contains("profile"))
    }

    @Test func enrolledButTrustLevelUnknownStaysSilent() {
        // nil trustLevel means the daemon is stopped/stale (no fresh trust
        // status). Doctor's daemon/trust section already tells the operator to
        // start/fix the daemon, so emitting an "ONLINE but earning nothing"
        // MDM-pending warning here would be contradictory — stay silent.
        #expect(MDMTrustDiagnosis.diagnose(
            trustLevel: nil,
            status: nil,
            enrollment: .enrolledDarkbloom(serverURL: "https://api.dev.darkbloom.xyz/mdm/connect")) == nil)
    }

    @Test func selfSignedButUntrustedStaysSilent() {
        // self_signed + untrusted (e.g. after a hard challenge failure) is NOT a
        // "just waiting on MDM" situation — the provider is untrusted, which the
        // trust-status line already reports. The MDM-pending message claims the box
        // is ONLINE, so it must NOT fire here.
        #expect(MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed",
            status: "untrusted",
            enrollment: .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")) == nil)
    }

    @Test func enrolledAndHardwareTrustedEmitsNothing() {
        // Once hardware-trusted, the enrollment hint is pointless — and emitting
        // it would contradict the "earning" trust line. Defensive backstop even
        // if the caller forgets to gate on hardware trust.
        #expect(MDMTrustDiagnosis.diagnose(
            trustLevel: "hardware",
            status: "online",
            enrollment: .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")) == nil)
    }

    @Test func notEnrolledIsADistinctWarning() throws {
        // The "not enrolled at all" case must read differently from the
        // "enrolled but pending" case (different name + message), so the operator
        // doesn't conflate the two flows.
        let d = MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed", status: "online", enrollment: .notEnrolled)
        let diag = try #require(d)
        #expect(diag.level == .warn)
        #expect(diag.name == "mdm enrollment")
        #expect(diag.message.lowercased().contains("not enrolled"))
        #expect(diag.fix?.contains("darkbloom enroll") == true)

        // It is genuinely distinct from the enrolled-but-pending diagnosis.
        let enrolled = MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed",
            status: "online",
            enrollment: .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect"))
        #expect(diag.name != enrolled?.name)
        #expect(diag.message != enrolled?.message)
    }

    @Test func foreignMDMWarnsAboutSingleMDMConstraint() throws {
        let d = MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed",
            status: "online",
            enrollment: .enrolledOtherMDM(serverURL: "https://corp.kandji.io/mdm/commands"))
        let diag = try #require(d)
        #expect(diag.level == .warn)
        #expect(diag.name == "mdm enrollment")
        #expect(diag.message.contains("corp.kandji.io"))
        #expect(diag.message.lowercased().contains("another mdm"))
    }

    @Test func checkFailedStaysSilent() {
        // Unknown enrollment state must NOT assert non-enrollment; stay silent.
        #expect(MDMTrustDiagnosis.diagnose(
            trustLevel: "self_signed", status: "online", enrollment: .checkFailed) == nil)
        #expect(MDMTrustDiagnosis.diagnose(
            trustLevel: nil, status: nil, enrollment: .checkFailed) == nil)
    }
}
