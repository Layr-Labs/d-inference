package metrics

// TrustMetrics is the attestation and device-management lifecycle: Secure
// Enclave challenges, MDM/MDA verification, and the forced reconnects that
// follow a provider that stops answering. Trust decides whether a provider can
// receive traffic at all, so these series are read together with the fleet size
// — a failure rate is only interpretable next to how many providers there are.
//
// Several of these are also mirrored into the in-process registry that backs
// GET /v1/admin/metrics, under the `_total` names it has always used. The
// mirror names are not derivable from the Datadog names, which is why they are
// declared beside them.
type TrustMetrics struct {
	// ChallengesSent counts challenges the coordinator issued. The gap between
	// it and Challenges is challenges that never came back.
	ChallengesSent *Counter
	// Challenges is a challenge that resolved, by outcome: `passed`, `failed`, or
	// one of the two status-signature results. `status_sig_missing` is an old
	// provider whose status fields are advisory rather than signed;
	// `status_sig_failed` is a provider whose plain signature verified and whose
	// status signature did not, which is either tampering or a canonicalization
	// mismatch between the two implementations.
	Challenges *Counter
	// Failures counts a failed challenge by reason, and is the series the
	// untrust threshold is reasoned about with.
	Failures *Counter
	// ForceReconnect is a provider closed out for consecutive challenge
	// timeouts. It is a deliberate disconnect, so it also shows up in the
	// disconnect series — do not read the two as independent events.
	ForceReconnect *Counter

	// MDMVerification is the MicroMDM SecurityInfo cross-check that grants
	// hardware trust, by outcome. `granted-late` is the upgrade after a
	// SecurityInfo that arrived after the decision window.
	MDMVerification *Counter
	// MDAVerification is Apple device-attestation certificate verification, by
	// outcome. Most call sites name their outcome literally: `sent` from the
	// scheduler's executor, `invalid` from the queue and the callback, plus
	// `binding_mismatch` and `late` from the callback, and `reused` from the
	// cached-proof shortcut. The scheduler's per-attempt forwarder
	// (observeAttempt) is the exception: it relabels a success as `verified` and
	// otherwise passes the store's VerificationOutcome through, so every value of
	// that enum can also appear here — `timeout`, `cancelled`, `transient`,
	// `error`, `posture_mismatch`. Treat the set as open when writing a query.
	MDAVerification *Counter
}

func newTrustMetrics(m *Metrics) *TrustMetrics {
	return &TrustMetrics{
		ChallengesSent: m.counter("attestation.challenges_sent",
			"Secure Enclave challenges issued to providers"),
		Challenges: m.counter("attestation.challenges",
			"Challenges that resolved, by outcome (passed, failed, status_sig_missing, status_sig_failed)",
			"outcome"),
		Failures: m.mirroredCounter("attestation.failures", "attestation_failures_total",
			"Failed challenges by reason; the untrust threshold is counted off this",
			"reason"),
		ForceReconnect: m.mirroredCounter("attestation.force_reconnect", "attestation_force_reconnect_total",
			"Providers closed out for consecutive challenge timeouts",
			"reason"),

		MDMVerification: m.counter("mdm.verification",
			"MicroMDM SecurityInfo cross-checks by outcome",
			"outcome"),
		MDAVerification: m.mirroredCounter("mda.verification", "mda_verification_total",
			"Apple device-attestation verifications by outcome",
			"outcome"),
	}
}
