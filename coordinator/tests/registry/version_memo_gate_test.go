package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/versionmemo"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Versions rejected by the public trust gates must never reach the routing
// scan's memo. Its bounds remain necessary for owner self-routing.
func TestVersionMemosOnlySeeGatePassingProviders(t *testing.T) {
	memo := new(versionmemo.Memo[[]int])
	var planner *production.ReservationPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		VersionMemo: memo,
		Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation {
			planner = p
			return p
		},
	})
	const model = "qwen3.8-flash-next"
	const trustedVersion = "77.66.56-memo-trusted"
	const untrustedVersion = "77.66.55-memo-untrusted"

	trusted := makeSchedulerProvider(t, reg, "memo-trusted", model, 100)
	trusted.SetVersion(trustedVersion)

	untrusted := makeSchedulerProvider(t, reg, "memo-untrusted", model, 100)
	untrusted.SetVersion(untrustedVersion)
	reg.SetTrustLevel(untrusted.ID, production.TrustSelfSigned)

	pr := &production.PendingRequest{RequestID: "memo-gate", Model: model, RequestedMaxTokens: 16}
	scan := planner.ScanCandidates(model, pr, false)

	if scan.Scanned != 2 || scan.CandidateCount != 1 || scan.GateRejections[production.GateTrustFloor] != 1 {
		t.Fatalf("scan: scanned=%d candidates=%d trust_floor=%d, want 2/1/1",
			scan.Scanned, scan.CandidateCount, scan.GateRejections[production.GateTrustFloor])
	}
	// Positive control: the accepted version reached the memo through the
	// catalog-policy floor, making the rejected-version check non-vacuous.
	if _, hit := memo.Get(trustedVersion); !hit {
		t.Fatalf("gate-passing provider's version %q was not memoized", trustedVersion)
	}
	if _, hit := memo.Get(untrustedVersion); hit {
		t.Fatalf("gate-failing provider's version %q reached the version memo", untrustedVersion)
	}
}
