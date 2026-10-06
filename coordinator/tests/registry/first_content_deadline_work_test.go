package registry_test

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestDeadlineWorkNonemptyOwnersRetainOriginalPrompt(t *testing.T) {
	measurements := &protocol.PerformanceMeasurements{Epoch: "engine"}
	for _, tc := range []struct {
		name    string
		prefill int64
		decode  int64
		valid   bool
	}{
		{"zero work", 0, 0, false},
		{"decode without original prompt", 0, 128, false},
		{"positive prompt with zero output", 1, 0, true},
		{"cached or retiring owner retains full prompt", 4000, 128, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			work := &protocol.DeadlineWork{Version: 1, Epoch: "engine", Known: true,
				PrefillTokens: tc.prefill, DecodeTokens: tc.decode, RequestCount: 1,
				ContextTokensMax: max(1, int(tc.prefill+tc.decode)), ServiceFraction: .5}
			if got := deadline.ValidWork(work, measurements); got != tc.valid {
				t.Fatalf("known envelope valid=%t, want %t: %+v", got, tc.valid, work)
			}
		})
	}
	idle := &protocol.DeadlineWork{Version: 1, Epoch: "engine", Known: true}
	if !deadline.ValidWork(idle, measurements) {
		t.Fatal("an idle owner set must still permit zero work")
	}
}

func TestDeadlineWorkKnownAggregateContextBounds(t *testing.T) {
	for _, tc := range []struct {
		name            string
		prefill, decode int64
		count, context  int
		valid           bool
	}{
		{"one token per owner", 2, 0, 2, 1, true},
		{"fewer prompt tokens than owners", 1, 1, 2, 1, false},
		{"single owner exact context", 4000, 128, 1, 4128, true},
		{"single owner understated context", 4000, 128, 1, 4096, false},
		{"single owner overstated context", 4000, 128, 1, 8192, false},
		{"multiple owner context envelope", 8, 4, 2, 7, true},
		{"maximum leaves one token for other owner", 2, 1, 2, 2, true},
		{"maximum consumes another owners token", 2, 1, 2, 3, false},
		{"total exceeds all owners context", 8, 4, 2, 5, false},
		{"maximum exceeds total work", 8, 4, 2, 13, false},
		{"maximum aggregate fits", 64 << 20, 0, 64, 1 << 20, true},
		{"bounded fields impossible aggregate", 1 << 30, 1 << 30, 64, 1 << 20, false},
		{"oversized sum rejected before arithmetic", math.MaxInt64, math.MaxInt64, 1, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			work := &protocol.DeadlineWork{Version: 1, Epoch: "engine", Known: true,
				PrefillTokens: tc.prefill, DecodeTokens: tc.decode, RequestCount: tc.count,
				ContextTokensMax: tc.context, ServiceFraction: 1}
			if got := deadline.ValidWork(work, &protocol.PerformanceMeasurements{Epoch: "engine"}); got != tc.valid {
				t.Fatalf("aggregate valid=%t, want %t: %+v", got, tc.valid, work)
			}
		})
	}
}

func TestCalibratedWorkRejectsNonemptyZeroPromptAndUsesOrdinaryForecast(t *testing.T) {
	for _, decode := range []int64{0, 128} {
		t.Run(fmt.Sprintf("decode%d", decode), func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			p, profile, pr := f.provider, f.profile, f.request
			// Use the reviewed cooled policy. Work-envelope validation remains
			// necessary independently of whether that profile is currently idle.
			*profile.MinimumWholeMacQuiescenceMS = 20000
			slot := &p.BackendCapacity.Slots[0]
			slot.State, slot.NumRunning = "running", 1
			slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true,
				PrefillTokens: 4000, DecodeTokens: decode, RequestCount: 1,
				ContextTokensMax: 4000 + int(decode), ServiceFraction: .0625}
			*p.BackendCapacity.WholeMacServiceUsed = .0625
			valid := f.evidence(pr, now).Calibration
			if !valid.WorkKnown || valid.Work.PrefillTokens != 4000 {
				t.Fatal("positive original prompt was not retained in bounded work")
			}

			// A fresh frame with a positive owner count/context/fraction but no
			// original prompt must not turn that owner into free competing work.
			slot.DeadlineWork.PrefillTokens = 0
			got := f.evaluate(pr, now).Estimate
			if f.evidence(pr, now).Calibration.WorkKnown || got.PredictionSource != "" ||
				got.Status != forecast.Unknown || got.Reason != "competing_work_unknown" ||
				got.BudgetMs != 4000 {
				t.Fatalf("impossible work report qualified or changed the original deadline: %+v", got)
			}
			slot.DeadlineProfile = nil
			ordinary := f.evaluate(pr, now).Estimate
			if got != ordinary {
				t.Fatalf("rejected envelope differs from ordinary fallback: %+v vs %+v", got, ordinary)
			}
		})
	}
}
