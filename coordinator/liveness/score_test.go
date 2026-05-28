package liveness

import (
	"math"
	"testing"
	"time"
)

func approxEqual(t *testing.T, got, want, eps float64, label string) {
	t.Helper()
	if math.Abs(got-want) > eps {
		t.Fatalf("%s: want %v ± %v, got %v", label, want, eps, got)
	}
}

func TestComputeLivenessScoreEmpty(t *testing.T) {
	// Brand-new provider with no sessions: all features at zero. Score should
	// be close to zero (only the MTBF sigmoid contributes, and at mtbf=0 the
	// sigmoid is well below 0.5).
	now := time.Now()
	got := computeLivenessScore(0, 0, 0, 0, time.Time{}, now)
	// sigmoid((0 - 14400) / 3600) = sigmoid(-4) ≈ 0.0180
	// score = 0.25 · 0.018 ≈ 0.0045
	if got > 0.01 {
		t.Fatalf("empty-provider score should be near 0, got %v", got)
	}
}

func TestComputeLivenessScorePerfect(t *testing.T) {
	// Perfect provider: 100% uptime, always stays ≥ 8h, large MTBF, no
	// recent disconnect. Should saturate at 1.0.
	now := time.Now()
	mtbf := int64(48 * 3600) // 48h
	got := computeLivenessScore(1.0, 1.0, 1.0, mtbf, time.Time{}, now)
	approxEqual(t, got, 1.0, 0.01, "perfect score")
}

func TestComputeLivenessScoreFlaky(t *testing.T) {
	// High uptime but flaky: lots of short sessions. PStays4h low, PStays8h
	// zero, low MTBF, recent disconnect. Score should be meaningfully lower
	// than uptime alone would suggest.
	now := time.Now()
	lastDisc := now.Add(-1 * time.Hour) // 1h ago → ~96% recency penalty
	got := computeLivenessScore(0.99, 0.1, 0.0, int64(300), lastDisc, now)
	// 0.35·0.99 + 0.25·0.1 + 0.15·0 + 0.25·sigmoid((300-14400)/3600) - 0.10·(1 - 1/24)
	// ≈ 0.347 + 0.025 + 0 + 0.25·0.0197 - 0.0958
	// ≈ 0.281
	if got > 0.40 {
		t.Fatalf("flaky provider should score well below uptime (0.99), got %v", got)
	}
	if got < 0.20 {
		t.Fatalf("flaky provider score too low (uptime is still 0.99): got %v", got)
	}
}

func TestComputeLivenessScoreRecencyDecays(t *testing.T) {
	// Same provider, same features — only the disconnect age varies. The
	// score should monotonically increase as the disconnect ages.
	now := time.Now()
	score := func(ageHours float64) float64 {
		return computeLivenessScore(0.9, 0.6, 0.4, int64(7200), now.Add(-time.Duration(ageHours*float64(time.Hour))), now)
	}
	hot := score(0.1) // 6 min ago — recency penalty nearly maxed
	warm := score(6)  // 6h ago — half decayed
	cold := score(48) // 48h ago — well past the 24h window
	if !(hot < warm && warm < cold) {
		t.Fatalf("recency should monotonically improve score: hot=%v warm=%v cold=%v", hot, warm, cold)
	}
	// cold should be > 0 (no recency penalty).
	if cold <= warm+0.001 {
		t.Fatalf("cold disconnect (48h) should fully clear recency penalty: cold=%v warm=%v", cold, warm)
	}
}

func TestComputeLivenessScoreClampedToUnitInterval(t *testing.T) {
	// Pathological inputs at the bounds should never produce values outside
	// [0, 1]. We don't expect callers to pass these, but the scorer is a
	// public-ish surface.
	now := time.Now()
	if got := computeLivenessScore(2.0, 2.0, 2.0, 1<<30, time.Time{}, now); got > 1 {
		t.Fatalf("score must clamp to ≤ 1, got %v", got)
	}
	// Negative uptime + immediate disconnect: would algebraically be < 0.
	if got := computeLivenessScore(-1.0, -1.0, -1.0, 0, now, now); got < 0 {
		t.Fatalf("score must clamp to ≥ 0, got %v", got)
	}
}

func TestSigmoidSanity(t *testing.T) {
	approxEqual(t, sigmoid(0), 0.5, 1e-9, "sigmoid(0)")
	if sigmoid(10) <= 0.999 {
		t.Fatalf("sigmoid(10) should saturate near 1, got %v", sigmoid(10))
	}
	if sigmoid(-10) >= 0.001 {
		t.Fatalf("sigmoid(-10) should saturate near 0, got %v", sigmoid(-10))
	}
}
