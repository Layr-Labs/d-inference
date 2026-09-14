package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/providerversion"
	"testing"
)

// TestVersionMemosOnlySeeGatePassingProviders pins that versions rejected by
// the public trust gates never reach the routing scan's memos. The memo's
// bounds do not depend on this: owner self-route may relax those gates.
func TestVersionMemosOnlySeeGatePassingProviders(t *testing.T) {
	previous := providerVersions
	providerVersions = &providerversion.Policy{}
	t.Cleanup(func() { providerVersions = previous })
	reg := New(testLogger())
	const model = "memo-gate-model"
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
	// Positive control: the gate-passing provider's version reached both memos
	// through the budget-layout selection (keyed on the numeric core), so the
	// negative assertions below are not vacuous.
	core := providerversion.NumericCore(trustedVersion)
	segments, layout := providerVersions.Memoized(core)
	if !layout || !segments {
		t.Fatalf("gate-passing provider's version core %q was not memoized (layout=%v segments=%v)",
			core, layout, segments)
	}
	// The gated-out provider's version never reached a parser.
	for _, key := range []string{untrustedVersion, providerversion.NumericCore(untrustedVersion)} {
		if segments, layout := providerVersions.Memoized(key); segments || layout {
			t.Fatalf("gate-failing provider's version %q reached a version memo", key)
		}
	}
}
