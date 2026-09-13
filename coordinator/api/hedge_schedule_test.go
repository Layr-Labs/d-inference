package api

import (
	"testing"
	"time"
)

// TestHedgeLaunchOffsetTable pins exact scheduling arithmetic across the
// deadline shapes the coordinator actually serves: the unit-test 5s base, the
// production 9s + 1ms/token slope, and the tightened exact-model policy (#787,
// Qwen3-VL Instruct at 4s). Values are hand-computed from
// min(deadline/2, deadline - max(q90, 1s) - 500ms), floored at 0.
func TestHedgeLaunchOffsetTable(t *testing.T) {
	tests := []struct {
		name       string
		deadline   time.Duration
		backupQ90  time.Duration
		confidence hedgeQuoteConfidence
		want       time.Duration
	}{
		{
			name:       "fast backup stays at half point",
			deadline:   9 * time.Second,
			backupQ90:  200 * time.Millisecond, // floored to 1s: 9s-1s-0.5s=7.5s > 4.5s
			confidence: hedgeConfidenceHigh,
			want:       4500 * time.Millisecond,
		},
		{
			name:       "slow backup launches earlier than half",
			deadline:   9 * time.Second,
			backupQ90:  6 * time.Second, // 9s-6s-0.5s = 2.5s < 4.5s
			confidence: hedgeConfidenceHigh,
			want:       2500 * time.Millisecond,
		},
		{
			name:       "hopeless backup launches immediately",
			deadline:   9 * time.Second,
			backupQ90:  9 * time.Second, // 9s-9s-0.5s < 0 → 0
			confidence: hedgeConfidenceHigh,
			want:       0,
		},
		{
			name:       "production token slope shifts both terms",
			deadline:   9*time.Second + 321*time.Millisecond, // 9s base + 321 prompt tokens
			backupQ90:  7 * time.Second,                      // 9.321s-7s-0.5s = 1.821s
			confidence: hedgeConfidenceHigh,
			want:       1821 * time.Millisecond,
		},
		{
			name:       "tightened exact-model deadline",
			deadline:   4 * time.Second, // Qwen3-VL policy base
			backupQ90:  500 * time.Millisecond,
			confidence: hedgeConfidenceHigh,
			want:       2 * time.Second, // 4s-1s-0.5s = 2.5s, half point 2s wins
		},
		{
			name:       "low confidence collapses to half point",
			deadline:   9 * time.Second,
			backupQ90:  8 * time.Second,
			confidence: hedgeConfidenceLow,
			want:       4500 * time.Millisecond,
		},
		{
			name:       "no quote collapses to half point",
			deadline:   9 * time.Second,
			backupQ90:  0,
			confidence: hedgeConfidenceNone,
			want:       4500 * time.Millisecond,
		},
		{
			name:       "zero deadline launches immediately",
			deadline:   0,
			backupQ90:  time.Second,
			confidence: hedgeConfidenceHigh,
			want:       0,
		},
		{
			name:       "negative deadline is zero-value safe",
			deadline:   -time.Second,
			backupQ90:  0,
			confidence: hedgeConfidenceNone,
			want:       0,
		},
		{
			name:       "zero q90 at high confidence hits the 1s floor",
			deadline:   2 * time.Second, // 2s-1s-0.5s = 0.5s < half point 1s
			backupQ90:  0,
			confidence: hedgeConfidenceHigh,
			want:       500 * time.Millisecond,
		},
	}
	for _, tt := range tests {
		got := hedgeLaunchOffset(tt.deadline, tt.backupQ90, tt.confidence)
		if got != tt.want {
			t.Errorf("%s: hedgeLaunchOffset(%v, %v, %d) = %v, want %v",
				tt.name, tt.deadline, tt.backupQ90, tt.confidence, got, tt.want)
		}
	}
}

// TestHedgeLaunchOffsetNeverExceedsHalfPoint sweeps deadlines (including the
// model-specific ones), backup estimates, and confidences and asserts the two
// schedule invariants hold everywhere: the offset never passes the 50% point
// (so the adaptive path can only launch EARLIER than the legacy
// speculativeTimerRatio), and it is never negative (a past launch point means
// "now", never a time subtraction that could confuse the caller's timer).
func TestHedgeLaunchOffsetNeverExceedsHalfPoint(t *testing.T) {
	deadlines := []time.Duration{
		100 * time.Millisecond,
		400 * time.Millisecond,
		time.Second,
		4 * time.Second,                        // Qwen3-VL exact-model base
		4*time.Second + 321*time.Millisecond,   // tightened base + token slope
		5 * time.Second,                        // unit-test base
		9 * time.Second,                        // production base
		9*time.Second + 2048*time.Millisecond,  // production + 2048-token slope
		9*time.Second + 32768*time.Millisecond, // production + long prompt
		15 * time.Second,
	}
	confidences := []hedgeQuoteConfidence{
		hedgeConfidenceNone, hedgeConfidenceLow, hedgeConfidenceHigh,
	}
	for _, deadline := range deadlines {
		for q90 := time.Duration(0); q90 <= deadline+2*time.Second; q90 += 250 * time.Millisecond {
			for _, confidence := range confidences {
				got := hedgeLaunchOffset(deadline, q90, confidence)
				if half := deadline / 2; got > half {
					t.Fatalf("hedgeLaunchOffset(%v, %v, %d) = %v exceeds half point %v",
						deadline, q90, confidence, got, half)
				}
				if got < 0 {
					t.Fatalf("hedgeLaunchOffset(%v, %v, %d) = %v is negative",
						deadline, q90, confidence, got)
				}
			}
		}
	}
}

// TestHedgeLaunchOffsetLowConfidenceIgnoresQuote proves the collapse rule: any
// confidence below high schedules at exactly the half point regardless of how
// extreme the quoted q90 is — a low-trust number must not move the launch.
func TestHedgeLaunchOffsetLowConfidenceIgnoresQuote(t *testing.T) {
	const deadline = 9 * time.Second
	for _, confidence := range []hedgeQuoteConfidence{hedgeConfidenceNone, hedgeConfidenceLow} {
		for _, q90 := range []time.Duration{0, time.Second, 8 * time.Second, time.Minute} {
			if got := hedgeLaunchOffset(deadline, q90, confidence); got != deadline/2 {
				t.Fatalf("confidence %d q90 %v: offset = %v, want half point %v",
					confidence, q90, got, deadline/2)
			}
		}
	}
}

// TestHedgeLaunchAtAnchorsOnReceivedAt verifies the absolute form is exactly
// receivedAt + offset — the launch time lives inside the existing
// request-absolute clock and never extends past receivedAt + deadline.
func TestHedgeLaunchAtAnchorsOnReceivedAt(t *testing.T) {
	receivedAt := time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)
	const deadline = 9 * time.Second

	at := hedgeLaunchAt(receivedAt, deadline, 6*time.Second, hedgeConfidenceHigh)
	if want := receivedAt.Add(2500 * time.Millisecond); !at.Equal(want) {
		t.Fatalf("launch at = %v, want %v", at, want)
	}
	if at.After(receivedAt.Add(deadline)) {
		t.Fatalf("launch at %v extends past absolute deadline %v",
			at, receivedAt.Add(deadline))
	}

	// Immediate-launch case: the anchor IS the launch point.
	at = hedgeLaunchAt(receivedAt, deadline, 20*time.Second, hedgeConfidenceHigh)
	if !at.Equal(receivedAt) {
		t.Fatalf("hopeless-backup launch at = %v, want receivedAt %v", at, receivedAt)
	}
}
