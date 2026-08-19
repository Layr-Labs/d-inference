import Foundation
import ProviderCore

/// Everything a `darkbloom doctor` run gathered, before ANY rendering. The
/// human report (`DoctorHumanReportRenderer`) and the JSON document
/// (`DoctorJSONReportBuilder` + `DoctorJSONReportRenderer`) both derive from
/// this one value — the two output modes can never drift into two truth
/// sources because there is only one gather.
struct DoctorRunArtifacts {
    /// `ProviderCore.version`, for the `darkbloom doctor x.y.z` banner and
    /// the JSON `version` field alike.
    let version: String
    /// Human description of which config file is in effect.
    let configDescription: String
    /// Whether the daemon's state file names a live pid.
    let daemonRunning: Bool
    /// The operator-facing "why am I / aren't I earning?" diagnosis.
    let diagnosis: [Diagnostic]
    /// The detailed low-level checks, in print order: base hardware/security
    /// checks, coordinator checks, KV-posture checks, then the crash-loop
    /// guard check if present.
    let detailedChecks: [DoctorCheck]
    /// Boot-security action guide, when any issue exists.
    let bootSecurityGuide: String?
    /// `--support` facts; only gathered when the flag is passed.
    let support: DoctorSupportInfo?
}

/// The `--support` block facts (serial/coordinator/auth/enrollment/pid file).
/// Human output only — the JSON document deliberately stays the check list.
struct DoctorSupportInfo {
    let coordinator: String
    let serial: String
    let authTokenPresent: Bool
    let mdmEnrolled: String
    let pidFile: String
}
