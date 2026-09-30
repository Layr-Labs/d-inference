package registry

import "testing"

// TestVersionMemosOnlySeeGatePassingProviders pins that versions rejected by
// the public trust gates never reach the routing scan's version memo. The
// memo's bounds do not depend on this: owner self-route may relax those gates.
// The model is the qwen4 registry id because its catalog policy
// (providerMeetsQwen4CatalogPolicyLocked) is the scan's version-floor check.
func TestVersionMemosOnlySeeGatePassingProviders(t *testing.T) {
	versionSegmentsMemo.reset()
	reg := New(testLogger())
	const model = qwen4RegistryModelID
	const trustedVersion = "77.66.56-memo-trusted"
	const untrustedVersion = "77.66.55-memo-untrusted"

	trusted := makeSchedulerProvider(t, reg, "memo-trusted", model, 100)
	trusted.mu.Lock()
	trusted.Version = trustedVersion
	trusted.mu.Unlock()

	untrusted := makeSchedulerProvider(t, reg, "memo-untrusted", model, 100)
	untrusted.mu.Lock()
	untrusted.Version = untrustedVersion
	untrusted.TrustLevel = TrustSelfSigned // below the TrustHardware floor
	untrusted.mu.Unlock()

	pr := &PendingRequest{RequestID: "memo-gate", Model: model, RequestedMaxTokens: 16}
	reg.mu.RLock()
	scan := reg.scanCandidatesLocked(model, pr, false)
	reg.mu.RUnlock()

	if scan.scanned != 2 || scan.candidateCount != 1 || scan.gateRejections[GateTrustFloor] != 1 {
		t.Fatalf("scan: scanned=%d candidates=%d trust_floor=%d, want 2/1/1",
			scan.scanned, scan.candidateCount, scan.gateRejections[GateTrustFloor])
	}
	// Positive control: the gate-passing provider's version reached the memo
	// through the catalog-policy floor, so the negative assertion below is not
	// vacuous.
	if !versionSegmentsMemo.has(trustedVersion) {
		t.Fatalf("gate-passing provider's version %q was not memoized", trustedVersion)
	}
	// The gated-out provider's version never reached the parser.
	if versionSegmentsMemo.has(untrustedVersion) {
		t.Fatalf("gate-failing provider's version %q reached the version memo", untrustedVersion)
	}
}
