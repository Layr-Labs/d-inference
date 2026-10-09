package registry_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityquote"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentDeadlineUsesSameServingIdentityAsCount(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, profile, pr := f.provider, f.profile, f.request
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
			started := time.Now()
			scan := f.planner.ScanCandidates(pr.Model, pr, false)
			if len(scan.Candidates) != 1 {
				t.Fatal("fixture lost candidate")
			}
			got := scan.Candidates[0].Quote().FirstContent
			ended := time.Now()
			if got.PromptTokens != tc.wantCount || got.BudgetMs > tc.wantBudget-float64(started.Sub(now))/float64(time.Millisecond) || got.BudgetMs < tc.wantBudget-float64(ended.Sub(now))/float64(time.Millisecond) {
				t.Fatalf("forecast/count deadline qualifier diverged: %+v", got)
			}
			if pr.FirstContentDeadline != now.Add(8*time.Second) || pr.EstimatedPromptTokens != 3000 || pr.RequestedMaxTokens != 128 {
				t.Fatal("read-only candidate mutated envelope or physical budget")
			}
		})
	}
}

func TestFirstContentDeadlineFreshQuoteKeepsCandidateCutoff(t *testing.T) {
	for _, matching := range []bool{true, false} {
		t.Run(map[bool]string{true: "matching", false: "missing"}[matching], func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			r, p, pr := f.registry, f.provider, f.request
			pr.RequestID = "fresh-quote-clock"
			pr.FirstContentFallbackDeadline, pr.FirstContentQualifiedDeadline = now.Add(8*time.Second), now.Add(4*time.Second)
			pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
			if !matching {
				p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
			}
			plan := f.planner.ScanCandidates(pr.Model, pr, false).Plan(pr.Model, nil)
			observed := time.Now()
			plan.ApplyQuoteDelivery(capacityquote.Delivery{ProviderID: p.ID, ObservedAt: observed, Quote: &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP50MS: 5000, TTFTP90MS: 6000, Confidence: protocol.CapacityConfidenceHigh}})
			selected, decision, _ := r.ReserveNextFromPlan(pr, plan)
			if selected != p || decision.FirstContent.Reason != "fresh_quote" {
				t.Fatalf("fresh quote did not reach real commit: %+v", decision)
			}
			wantDeadline, wantStatus := pr.FirstContentFallbackDeadline, production.FirstContentFeasible
			if matching {
				wantDeadline, wantStatus = pr.FirstContentQualifiedDeadline, production.FirstContentPredictedLate
			}
			if !pr.FirstContentDeadline.Equal(wantDeadline) || decision.FirstContent.Status != wantStatus {
				t.Fatalf("quote borrowed a peer clock: %+v", decision.FirstContent)
			}
			p.RemovePending(pr.RequestID)
		})
	}
}

func TestFirstContentDeadlineFinalWriterRejectsQualifiedIdentityDrift(t *testing.T) {
	for _, change := range []string{"missing", "contract", "artifact"} {
		t.Run(change, func(t *testing.T) {
			_, p, pr, frames := deadlineHandoffFixture(t, true)
			if !pr.FirstContentDeadline.Equal(pr.FirstContentQualifiedDeadline) {
				t.Fatal("reservation did not bind exact cutoff")
			}
			_, err := p.WriteInferenceTextDeferred(context.Background(), pr, func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, func(production.TextFrameWriteMetadata) {
				p.Mu().Lock()
				defer p.Mu().Unlock()
				switch change {
				case "missing":
					p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
				case "contract":
					p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("c", 64)
				case "artifact":
					p.BackendCapacity.Slots[0].PromptWorkIdentity.ModelArtifactHash = strings.Repeat("c", 64)
				}
			})
			if !errors.Is(err, production.ErrProviderServingUnauthorized) || frames.Load() != 0 {
				t.Fatalf("unqualified exact frame reached wire: err%v frames%d", err, frames.Load())
			}
			if !pr.FirstContentDeadline.Equal(pr.FirstContentQualifiedDeadline) {
				t.Fatal("handoff changed cutoff or failed unsent retirement")
			}

			p.Mu().Lock()
			p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: pr.PromptWork.ModelArtifactHash, PromptContractID: pr.PromptWork.PromptContractID}
			p.Mu().Unlock()
			if err := p.NewInferenceHandoff(pr).Authorize(); !errors.Is(err, production.ErrProviderServingUnauthorized) {
				t.Fatal("unsent aborted handoff reauthorized", err)
			}
			p.RemovePending(pr.RequestID)
		})
	}
}

func TestFirstContentDeadlineBoundFallbackNeverUpgradesAtHandoff(t *testing.T) {
	_, p, pr, frames := deadlineHandoffFixture(t, false)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: pr.PromptWork.ModelArtifactHash, PromptContractID: pr.PromptWork.PromptContractID}
	p.Mu().Unlock()
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
	pr := &production.PendingRequest{EstimatedPromptTokens: 500, RequestedMaxTokens: 32, MaxTTFTMs: 2000,
		FirstContentFallbackDeadline: time.Now().Add(2 * time.Second), FirstContentQualifiedDeadline: time.Now().Add(4 * time.Second)}
	if pr.QueueWorkload().Comparable {
		t.Fatal("candidate-dependent cutoff reused scalar queue rejection")
	}
}

func TestFirstContentDeadlineReservationRevalidatesRendererHeartbeat(t *testing.T) {
	for _, initiallyMatching := range []bool{true, false} {
		t.Run(map[bool]string{true: "matching_to_missing", false: "missing_to_matching"}[initiallyMatching], func(t *testing.T) {
			preparation := &reservationPreparationFixture{}
			r, p, before, _ := deadlineHandoffFixture(t, initiallyMatching, preparation)
			p.RemovePending(before.RequestID)
			pr := freshServingDeadlineRequest(before, "deadline-revalidation")
			pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
			scans := 0
			preparation.after = func(string) {
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
	preparation := &reservationPreparationFixture{}
	r, p, before, _ := deadlineHandoffFixture(t, true, preparation)
	p.RemovePending(before.RequestID)
	pr := freshServingDeadlineRequest(before, "deadline-plan")
	plan := preparation.planner.ScanCandidates(pr.Model, pr, false).Plan(pr.Model, nil)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	p.Mu().Unlock()
	selected, _, _ := r.ReserveNextFromPlan(pr, plan)
	if selected != p || !pr.FirstContentDeadline.Equal(pr.FirstContentFallbackDeadline) {
		t.Fatal("retained matching snapshot lent renderer cutoff")
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentDeadlineEnvelopeCanReachQualifiedAfterFallbackExpiry(t *testing.T) {
	preparation := &reservationPreparationFixture{}
	r, p, before, _ := deadlineHandoffFixture(t, true, preparation)
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
	r := production.New(testLogger())
	const model = "deadline-expired-peers"
	artifact, contract := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for i := 0; i < 33; i++ {
		p := makeSchedulerProvider(t, r, fmt.Sprintf("expired-%d", i), model, 100)
		p.Mu().Lock()
		p.PrefillTPS = 10000
		p.BackendCapacity.Slots[0].ObservedPrefillTPS = 10000
		p.Mu().Unlock()
	}
	live := makeSchedulerProvider(t, r, "qualified-live", model, 100)
	live.Mu().Lock()
	live.Models[0].WeightHash = artifact
	live.PrefillTPS = 100
	live.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	live.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: artifact, PromptContractID: contract}
	live.Mu().Unlock()
	now := time.Now()
	pr := &production.PendingRequest{RequestID: "deadline-live", Model: model, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
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
