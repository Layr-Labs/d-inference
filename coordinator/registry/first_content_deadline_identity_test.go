package registry

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentDeadlineUsesSameServingIdentityAsCount(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	pr.FirstContentFallbackDeadline, pr.FirstContentQualifiedDeadline = now.Add(8*time.Second), now.Add(4*time.Second)
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	for _, tc := range []struct {
		name, source, artifact, contract string
		wantCount                        int
		wantBudget                       float64
	}{
		{"matching", protocol.PromptWorkExact, profile.ArtifactSHA256, profile.DeadlineCalibration.PromptContractID, 4000, 4000},
		{"missing", protocol.PromptWorkExact, "", "", 3000, 8000},
		{"different_contract", protocol.PromptWorkExact, profile.ArtifactSHA256, strings.Repeat("e", 64), 3000, 8000},
		{"different_artifact", protocol.PromptWorkExact, strings.Repeat("e", 64), profile.DeadlineCalibration.PromptContractID, 3000, 8000},
		{"calibrated", protocol.PromptWorkCalibrated, profile.ArtifactSHA256, profile.DeadlineCalibration.PromptContractID, 4000, 8000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 3000, 3500
			pr.PromptWork.Source = tc.source
			pr.PromptWork.CalibrationID = ""
			if tc.source == protocol.PromptWorkCalibrated {
				pr.PromptWork.CalibrationID = "reviewed-fixture"
			}
			p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: tc.artifact, PromptContractID: tc.contract}
			got := calibratedForecast(r, p, pr, now).firstContent
			if got.PromptTokens != tc.wantCount || got.BudgetMs != tc.wantBudget {
				t.Fatalf("forecast/count deadline qualifier diverged: %+v", got)
			}
			if pr.FirstContentDeadline != now.Add(8*time.Second) || pr.EstimatedPromptTokens != 3000 || pr.RequestedMaxTokens != 128 {
				t.Fatal("read-only candidate mutated envelope or physical budget")
			}
		})
	}
}

func TestFirstContentDeadlineFreshQuoteKeepsCandidateCutoff(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	pr.FirstContentFallbackDeadline, pr.FirstContentQualifiedDeadline = now.Add(8*time.Second), now.Add(4*time.Second)
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	quote := PlanEntry{Confirmed: true, QuoteConfidence: protocol.CapacityConfidenceHigh, QuoteObservedAt: now,
		QuoteTTFTP50: 5 * time.Second, QuoteTTFTP90: 6 * time.Second}
	for _, matching := range []bool{true, false} {
		if !matching {
			p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
		}
		candidate := calibratedForecast(r, p, pr, now)
		applyFirstContentQuote(candidate, pr, quote, now)
		if matching && (candidate.firstContent.BudgetMs != 4000 || candidate.firstContent.Status != FirstContentPredictedLate) {
			t.Fatal("fresh quote upgraded shorter matching cutoff", candidate.firstContent)
		}
		if !matching && (candidate.firstContent.BudgetMs != 8000 || candidate.firstContent.Status != FirstContentFeasible) {
			t.Fatal("fresh quote borrowed canonical cutoff", candidate.firstContent)
		}
	}
}

func deadlineHandoffFixture(t *testing.T, matching bool) (*Registry, *Provider, *PendingRequest) {
	t.Helper()
	r, p, lease := appAttestTestProvider(t)
	artifact, contract := strings.Repeat("a", 64), strings.Repeat("b", 64)
	p.mu.Lock()
	p.Models[0].WeightHash = artifact
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: appAttestTestModel, State: "idle", MaxConcurrency: 8, ActiveTokenBudgetMax: 100000}}}
	if matching {
		p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: artifact, PromptContractID: contract}
	}
	p.mu.Unlock()
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	now := time.Now()
	pr := &PendingRequest{RequestID: "deadline-handoff", Model: appAttestTestModel, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
		PromptWork:                   &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 1200, UpperBoundTokens: 1200, ModelArtifactHash: artifact, PromptContractID: contract},
		FirstContentFallbackDeadline: now.Add(20 * time.Second), FirstContentQualifiedDeadline: now.Add(10 * time.Second)}
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	return r, p, pr
}

func TestFirstContentDeadlineFinalWriterRejectsQualifiedIdentityDrift(t *testing.T) {
	for _, change := range []string{"missing", "contract", "artifact"} {
		t.Run(change, func(t *testing.T) {
			_, p, pr := deadlineHandoffFixture(t, true)
			_, frames := appAttestTestWriter(t, p)
			if !pr.FirstContentDeadline.Equal(pr.FirstContentQualifiedDeadline) {
				t.Fatal("reservation did not bind exact cutoff")
			}
			_, err := p.WriteInferenceTextDeferred(context.Background(), pr, func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, func(TextFrameWriteMetadata) {
				p.mu.Lock()
				defer p.mu.Unlock()
				switch change {
				case "missing":
					p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
				case "contract":
					p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("c", 64)
				case "artifact":
					p.BackendCapacity.Slots[0].PromptWorkIdentity.ModelArtifactHash = strings.Repeat("c", 64)
				}
			})
			if !errors.Is(err, ErrProviderServingUnauthorized) || frames.Load() != 0 {
				t.Fatalf("unqualified exact frame reached wire: err%v frames%d", err, frames.Load())
			}
			if !pr.FirstContentDeadline.Equal(pr.FirstContentQualifiedDeadline) || !pr.serviceHandoffAborted {
				t.Fatal("handoff changed cutoff or failed unsent retirement")
			}
			p.RemovePending(pr.RequestID)
		})
	}
}

func TestFirstContentDeadlineBoundFallbackNeverUpgradesAtHandoff(t *testing.T) {
	_, p, pr := deadlineHandoffFixture(t, false)
	_, frames := appAttestTestWriter(t, p)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: pr.PromptWork.ModelArtifactHash, PromptContractID: pr.PromptWork.PromptContractID}
	p.mu.Unlock()
	if !pr.FirstContentDeadlineForIdentity(pr.PromptWork.ModelArtifactHash, pr.PromptWork.PromptContractID).Equal(pr.FirstContentFallbackDeadline) {
		t.Fatal("already-reserved fallback re-resolved later identity")
	}
	_, err := p.WriteInferenceTextDeferred(context.Background(), pr, func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, nil)
	if err != nil || frames.Load() != 1 || !pr.FirstContentDeadline.Equal(pr.FirstContentFallbackDeadline) {
		t.Fatalf("safe fallback handoff changed: err%v frames%d", err, frames.Load())
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentDeadlineQualifiedQueueCannotUseScalarDominance(t *testing.T) {
	pr := &PendingRequest{EstimatedPromptTokens: 500, RequestedMaxTokens: 32, MaxTTFTMs: 2000,
		FirstContentFallbackDeadline: time.Now().Add(2 * time.Second), FirstContentQualifiedDeadline: time.Now().Add(4 * time.Second)}
	if drainDominanceComparable(pr) {
		t.Fatal("candidate-dependent cutoff reused scalar queue rejection")
	}
}

func freshServingDeadlineRequest(pr *PendingRequest, id string) *PendingRequest {
	return &PendingRequest{RequestID: id, Model: pr.Model, EstimatedPromptTokens: pr.EstimatedPromptTokens,
		RequestedMaxTokens: pr.RequestedMaxTokens, PromptWork: pr.PromptWork,
		FirstContentFallbackDeadline: pr.FirstContentFallbackDeadline, FirstContentQualifiedDeadline: pr.FirstContentQualifiedDeadline,
		FirstContentDeadline: pr.FirstContentDeadlineEnvelope()}
}

func TestFirstContentDeadlineReservationRevalidatesRendererHeartbeat(t *testing.T) {
	for _, initiallyMatching := range []bool{true, false} {
		t.Run(map[bool]string{true: "matching_to_missing", false: "missing_to_matching"}[initiallyMatching], func(t *testing.T) {
			r, p, before := deadlineHandoffFixture(t, initiallyMatching)
			p.RemovePending(before.RequestID)
			pr := freshServingDeadlineRequest(before, "deadline-revalidation")
			pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
			scans := 0
			r.reservationAfterScan = func(string) {
				scans++
				if scans != 1 {
					return
				}
				capacity := p.BackendCapacitySnapshot()
				capacity.CapacitySeq++
				capacity.Slots[0].PromptWorkIdentity = nil
				if !initiallyMatching {
					capacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: pr.PromptWork.ModelArtifactHash, PromptContractID: pr.PromptWork.PromptContractID}
				}
				if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("heartbeat drift rejected")
				}
			}
			selected, _ := r.ReserveProviderEx(pr.Model, pr)
			want := pr.FirstContentFallbackDeadline
			if !initiallyMatching {
				want = pr.FirstContentQualifiedDeadline
			}
			if selected != p || scans < 2 || !pr.FirstContentDeadline.Equal(want) {
				t.Fatalf("stale scan cutoff committed: selected%v scans%d got%v want%v", selected != nil, scans, pr.FirstContentDeadline, want)
			}
			p.RemovePending(pr.RequestID)
		})
	}
}

func TestFirstContentDeadlineRetainedPlanUsesCurrentRenderer(t *testing.T) {
	r, p, before := deadlineHandoffFixture(t, true)
	p.RemovePending(before.RequestID)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	p.mu.Unlock()
	pr := freshServingDeadlineRequest(before, "deadline-plan")
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	plan := &DispatchPlan{model: pr.Model, attempted: map[string]struct{}{}, entries: []planEntry{{provider: p, view: PlanEntry{ProviderID: p.ID}}}}
	selected, _, _ := r.ReserveNextFromPlan(pr, plan)
	if selected != p || !pr.FirstContentDeadline.Equal(pr.FirstContentFallbackDeadline) {
		t.Fatal("retained matching snapshot lent expired renderer cutoff")
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentDeadlineEnvelopeCanReachQualifiedAfterFallbackExpiry(t *testing.T) {
	r, p, before := deadlineHandoffFixture(t, true)
	p.RemovePending(before.RequestID)
	pr := freshServingDeadlineRequest(before, "deadline-extension")
	pr.FirstContentFallbackDeadline = time.Now().Add(-time.Second)
	pr.FirstContentQualifiedDeadline = time.Now().Add(2 * time.Second)
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	selected, _ := r.ReserveProviderEx(pr.Model, pr)
	if selected != p || !pr.FirstContentDeadline.Equal(pr.FirstContentQualifiedDeadline) {
		t.Fatal("expired heuristic envelope hid qualifying renderer")
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentDeadlineExpiredUnknownPeersCannotExhaustScan(t *testing.T) {
	r := New(testLogger())
	const model = "deadline-expired-peers"
	artifact, contract := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for i := 0; i < maxReservationRescans+1; i++ {
		p := makeSchedulerProvider(t, r, fmt.Sprintf("expired-%d", i), model, 100)
		p.mu.Lock()
		p.PrefillTPS = 10000
		p.BackendCapacity.Slots[0].ObservedPrefillTPS = 10000
		p.mu.Unlock()
	}
	live := makeSchedulerProvider(t, r, "qualified-live", model, 100)
	live.mu.Lock()
	live.Models[0].WeightHash = artifact
	live.PrefillTPS = 100
	live.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	live.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: artifact, PromptContractID: contract}
	live.mu.Unlock()
	now := time.Now()
	pr := &PendingRequest{RequestID: "deadline-live", Model: model, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
		PromptWork:                   &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 1200, UpperBoundTokens: 1200, ModelArtifactHash: artifact, PromptContractID: contract},
		FirstContentFallbackDeadline: now.Add(-time.Second), FirstContentQualifiedDeadline: now.Add(30 * time.Second)}
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	selected, decision := r.ReserveProviderEx(model, pr)
	if selected != live {
		t.Fatalf("expired unknown peers hid live qualified candidate: selected%v decision%+v", selected != nil, decision)
	}
	if decision.ScanCount != 1 {
		t.Fatal("spent rescans discarding already-expired peers", decision.ScanCount)
	}
	live.RemovePending(pr.RequestID)
}
