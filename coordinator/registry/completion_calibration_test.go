package registry

import (
	"math"
	"testing"
)

const completionCalibTestModel = "completion-calib-model"

// seedCompletionWindow feeds n completion samples spread uniformly over
// [lo, hi] so the nearest-rank p90 lands near lo + 0.9*(hi-lo).
func seedCompletionWindow(reg *Registry, model string, n, lo, hi int) {
	for i := 0; i < n; i++ {
		v := lo
		if n > 1 {
			v = lo + (hi-lo)*i/(n-1)
		}
		reg.RecordCompletionObservation(model, v)
	}
}

// Below warm-up the expected completion is the requested max (today's
// behaviour) and is reported as not learned.
func TestCompletionCalibrationWarmupPassthrough(t *testing.T) {
	reg := New(testLogger())
	seedCompletionWindow(reg, completionCalibTestModel, completionCalibrationWarmupObs-1, 100, 500)
	got, learned := reg.ExpectedCompletionTokensLearned(completionCalibTestModel, 16384)
	if learned || got != 16384 {
		t.Fatalf("below warm-up: expected=%d learned=%v, want 16384/false", got, learned)
	}
	if got := reg.ExpectedCompletionTokens("never-seen", 8192); got != 8192 {
		t.Fatalf("unseen model: expected=%d, want 8192", got)
	}
	reg.RecordCompletionObservation(completionCalibTestModel, 500)
	if _, learned := reg.ExpectedCompletionTokensLearned(completionCalibTestModel, 16384); !learned {
		t.Fatal("30th observation must cross warm-up")
	}
}

// Once warm: clamp(p90 x 1.25, 64, requestedMax).
func TestCompletionCalibrationExpectedIsP90WithMargin(t *testing.T) {
	reg := New(testLogger())
	seedCompletionWindow(reg, completionCalibTestModel, 50, 100, 500)
	_, p90, n := reg.CompletionCalibrationPercentiles(completionCalibTestModel)
	if n != 50 {
		t.Fatalf("observations=%d, want 50", n)
	}
	if p90 < 440 || p90 > 470 {
		t.Fatalf("p90=%v, want ~460 for a 100..500 ramp", p90)
	}
	want := int(math.Ceil(p90 * completionCalibrationP90Margin))
	got, learned := reg.ExpectedCompletionTokensLearned(completionCalibTestModel, 16384)
	if !learned || got != want {
		t.Fatalf("expected=%d learned=%v, want %d/true", got, learned, want)
	}
	// Never above the client's bound.
	if got := reg.ExpectedCompletionTokens(completionCalibTestModel, 300); got != 300 {
		t.Fatalf("bound clamp: expected=%d, want 300", got)
	}
	// requestedMax <= 0 means no upper bound.
	if got := reg.ExpectedCompletionTokens(completionCalibTestModel, 0); got != want {
		t.Fatalf("unbounded: expected=%d, want %d", got, want)
	}
}

// Very short completions floor at 64 tokens — but never above the bound.
func TestCompletionCalibrationFloor(t *testing.T) {
	reg := New(testLogger())
	seedCompletionWindow(reg, completionCalibTestModel, 40, 5, 20)
	if got := reg.ExpectedCompletionTokens(completionCalibTestModel, 16384); got != completionCalibrationMinTokens {
		t.Fatalf("floor: expected=%d, want %d", got, completionCalibrationMinTokens)
	}
	if got := reg.ExpectedCompletionTokens(completionCalibTestModel, 10); got != 10 {
		t.Fatalf("floor vs bound: expected=%d, want the bound 10", got)
	}
}

// Non-positive samples are ignored; the window slides after 200.
func TestCompletionCalibrationIgnoresInvalidAndSlides(t *testing.T) {
	reg := New(testLogger())
	for i := 0; i < 40; i++ {
		reg.RecordCompletionObservation(completionCalibTestModel, 0)
		reg.RecordCompletionObservation(completionCalibTestModel, -3)
		reg.RecordCompletionObservation("", 100)
	}
	if _, _, n := reg.CompletionCalibrationPercentiles(completionCalibTestModel); n != 0 {
		t.Fatalf("invalid samples recorded: n=%d", n)
	}
	seedCompletionWindow(reg, completionCalibTestModel, completionCalibrationWindowSize, 1000, 1000)
	seedCompletionWindow(reg, completionCalibTestModel, completionCalibrationWindowSize, 100, 100)
	if _, p90, _ := reg.CompletionCalibrationPercentiles(completionCalibTestModel); p90 != 100 {
		t.Fatalf("after the window slid: p90=%v, want 100", p90)
	}
}

// Kill switch: expected returns requestedMax (not learned); learning continues.
func TestCompletionCalibrationKillSwitch(t *testing.T) {
	reg := New(testLogger())
	seedCompletionWindow(reg, completionCalibTestModel, 50, 100, 500)
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "off")
	got, learned := reg.ExpectedCompletionTokensLearned(completionCalibTestModel, 16384)
	if learned || got != 16384 {
		t.Fatalf("switch off: expected=%d learned=%v, want 16384/false", got, learned)
	}
	reg.RecordCompletionObservation(completionCalibTestModel, 480)
	if _, _, n := reg.CompletionCalibrationPercentiles(completionCalibTestModel); n != 51 {
		t.Fatalf("learning must continue while off: n=%d", n)
	}
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
	if _, learned := reg.ExpectedCompletionTokensLearned(completionCalibTestModel, 16384); !learned {
		t.Fatal("switch on: expected a learned value")
	}
}

// thisReqDecodeTokens is the scheduler seam: the expected completion (never
// above the bound) replaces the bound in the decode half of thisReqMs; the
// decode rate is untouched. Off-switch = the bound, byte-identical to before.
func TestThisReqDecodeTokens(t *testing.T) {
	pr := &PendingRequest{RequestedMaxTokens: 16384, ExpectedCompletionTokens: 625}
	if got := thisReqDecodeTokens(pr, 16384); got != 625 {
		t.Fatalf("expected set: tokens=%d, want 625", got)
	}
	// Unset / oversized expected / nil → the bound.
	if got := thisReqDecodeTokens(&PendingRequest{}, 16384); got != 16384 {
		t.Fatalf("unset expected: tokens=%d, want 16384", got)
	}
	if got := thisReqDecodeTokens(&PendingRequest{ExpectedCompletionTokens: 99999}, 512); got != 512 {
		t.Fatalf("oversized expected: tokens=%d, want 512", got)
	}
	if got := thisReqDecodeTokens(nil, 512); got != 512 {
		t.Fatalf("nil pr: tokens=%d, want 512", got)
	}
	// The kill switch is enforced where ExpectedCompletionTokens is computed
	// (expected(), once per request), not in this per-candidate seam: with
	// the switch off the registry hands the consumer requestedMax, so the
	// carried value equals the bound and the seam returns the bound.
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "off")
	pr.ExpectedCompletionTokens = New(testLogger()).ExpectedCompletionTokens("m", 16384)
	if got := thisReqDecodeTokens(pr, 16384); got != 16384 {
		t.Fatalf("switch off: tokens=%d, want 16384", got)
	}
}

// Through the real scheduler: a request carrying an expected completion is
// scored with it (ThisReqMs shrinks), while admission still charges the bound
// (pendingTokenBudget / ledger unchanged).
func TestReserveUsesExpectedCompletionForCostOnly(t *testing.T) {
	reg := New(testLogger())
	const model = "expected-cost-model"
	p := makeSchedulerProvider(t, reg, "expected-cost-p1", model, 40)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 40
	p.mu.Unlock()

	bound := &PendingRequest{RequestID: "bound", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 16384}
	sel, boundDec := reg.ReserveProviderEx(model, bound)
	if sel == nil {
		t.Fatalf("reserve failed: %+v", boundDec)
	}
	sel.RemovePending(bound.RequestID)

	expected := &PendingRequest{RequestID: "expected", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 16384, ExpectedCompletionTokens: 500}
	sel, expDec := reg.ReserveProviderEx(model, expected)
	if sel == nil {
		t.Fatalf("reserve failed: %+v", expDec)
	}
	sel.RemovePending(expected.RequestID)

	// Decode halves: 16384/40 s vs 500/40 s → ~397s apart.
	if diff := boundDec.ThisReqMs - expDec.ThisReqMs; diff < 390_000 || diff > 405_000 {
		t.Fatalf("ThisReqMs bound=%v expected=%v: diff %v, want ~397100ms", boundDec.ThisReqMs, expDec.ThisReqMs, diff)
	}
	if got := pendingTokenBudget(expected); got != 100+16384 {
		t.Fatalf("pendingTokenBudget=%d, want prompt+bound %d (admission keeps the worst case)", got, 100+16384)
	}
}
