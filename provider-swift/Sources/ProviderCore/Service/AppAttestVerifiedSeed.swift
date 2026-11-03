import Foundation
import ProviderAppAttest

extension DaemonState {
    /// The latest time this state shows App Attest working on this Mac, or nil
    /// without a time:
    /// - a stored key that Apple attested, at its last successful Apple
    ///   attestation or assertion (proof that `isSupported` was true then);
    /// - a coordinator App Attest grant. The provider clears it at every
    ///   disconnect, so it is present only after an unclean exit.
    /// A provider that was itself answering `is_supported_false` publishes no
    /// key, so its state gives nil.
    var appAttestVerifiedAt: Date? {
        var times: [Double] = []
        if let trust, let grant = trust.authorization, grant.hasCurrentAppAttestAuthorization(now: trust.receivedAt) {
            times.append(trust.receivedAt)
        }
        if let status = appAttest, status.key?.attested == true,
           let age = status.keyHistory?.lastSuccessAgeSeconds, age >= 0 {
            times.append((status.keyHistoryObservedAt ?? status.observedAt) - Double(age))
        }
        return times.filter(\.isFinite).max().map(Date.init(timeIntervalSince1970:))
    }
}

extension AppAttestVerifiedMarker {
    /// A version before this marker never wrote it, so the first
    /// `is_supported_false` after an update from it could not restart. While
    /// the marker is missing, seed it from the previous `daemon-state.json`.
    /// Call before this process writes its own daemon state (the serve start
    /// does, before the schedule wait). An existing marker, even a damaged
    /// one, is never replaced; evidence older than
    /// `AppAttestStallRestartPolicy.verifiedWithin` is not written. Returns the
    /// seeded time.
    @discardableResult
    public static func seedFromPreviousRun(stateFile: URL = DaemonStateFile.path(), now: Date = Date()) -> Date? {
        let marker = AppAttestVerifiedMarker(directory: stateFile.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: marker.url.path),
              let verifiedAt = DaemonStateFile.read(from: stateFile)?.appAttestVerifiedAt,
              abs(now.timeIntervalSince(verifiedAt)) < AppAttestStallRestartPolicy.verifiedWithin,
              (try? marker.record(verifiedAt)) != nil else { return nil }
        return verifiedAt
    }
}
