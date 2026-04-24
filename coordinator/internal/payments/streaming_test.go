package payments

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

func newTestTracker() (*StreamTracker, *store.MemoryStore) {
	st := store.NewMemory("")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	return NewStreamTracker(st, logger), st
}

func TestStreamRate(t *testing.T) {
	tests := []struct {
		name     string
		memoryGB int
		bwGBs    float64
		want     int64
	}{
		// Below minimum memory — ineligible regardless of bandwidth.
		{"16GB/100bw", 16, 100, 0},
		{"24GB/273bw", 24, 273, 0},
		{"31GB/400bw", 31, 400, 0},

		// 32-47GB tier ($6 base) + bandwidth bonus
		{"M1 Max 32GB", 32, 400, 12_000_000},  // $6 + $6
		{"M2 Max 32GB", 32, 400, 12_000_000},  // $6 + $6
		{"M3 Pro 36GB", 36, 150, 10_000_000},  // $6 + $4
		{"M3 Max 36GB", 36, 300, 11_000_000},  // $6 + $5
		{"M4 Max 36GB", 36, 546, 13_000_000},  // $6 + $7

		// 48GB tier ($7 base) + bandwidth bonus
		{"M4 Pro 48GB", 48, 273, 12_000_000},  // $7 + $5
		{"M3 Max 48GB", 48, 400, 13_000_000},  // $7 + $6
		{"M4 Max 48GB", 48, 546, 14_000_000},  // $7 + $7

		// 64GB tier ($9 base) + bandwidth bonus
		{"M1 Max 64GB", 64, 400, 15_000_000},  // $9 + $6
		{"M4 Max 64GB", 64, 546, 16_000_000},  // $9 + $7

		// 96GB tier ($10 base) + bandwidth bonus
		{"M2 Max 96GB", 96, 400, 16_000_000},  // $10 + $6
		{"M3 Max 96GB", 96, 400, 16_000_000},  // $10 + $6

		// 128GB+ tier ($12 base) + bandwidth bonus
		{"M4 Max 128GB", 128, 546, 19_000_000},   // $12 + $7
		{"M2 Ultra 128GB", 128, 800, 20_000_000},  // $12 + $8
		{"M3 Ultra 192GB", 192, 819, 20_000_000},  // $12 + $8
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := StreamRate(tt.memoryGB, tt.bwGBs)
			if got != tt.want {
				t.Errorf("StreamRate(%d, %.0f) = %d, want %d", tt.memoryGB, tt.bwGBs, got, tt.want)
			}
		})
	}
}

func TestStreamRate_Range(t *testing.T) {
	configs := []struct {
		mem int
		bw  float64
	}{
		{32, 100}, {32, 400}, {32, 546},
		{36, 100}, {36, 150}, {36, 273}, {36, 400}, {36, 546}, {36, 800},
		{48, 150}, {48, 273}, {48, 400}, {48, 546}, {48, 800},
		{64, 150}, {64, 400}, {64, 546}, {64, 800},
		{96, 400}, {96, 546}, {96, 800},
		{128, 400}, {128, 546}, {128, 800},
		{192, 800}, {256, 800},
	}
	for _, c := range configs {
		rate := StreamRate(c.mem, c.bw)
		usd := float64(rate) / 1_000_000
		if usd < 10.0 || usd > 20.0 {
			t.Errorf("StreamRate(%d, %.0f) = $%.2f — out of $10-$20 range", c.mem, c.bw, usd)
		}
	}
}

func TestStreamRatePerMin(t *testing.T) {
	got := StreamRatePerMin(10_000_000)
	if got != 231 {
		t.Errorf("StreamRatePerMin(10_000_000) = %d, want 231", got)
	}

	got = StreamRatePerMin(20_000_000)
	if got != 462 {
		t.Errorf("StreamRatePerMin(20_000_000) = %d, want 462", got)
	}
}

func TestStreamEligible(t *testing.T) {
	tests := []struct {
		name           string
		memoryPressure float64
		thermalState   string
		hasWarmModel   bool
		want           bool
	}{
		{"nominal with model", 0.3, "nominal", true, true},
		{"no model loaded", 0.3, "nominal", false, false},
		{"fair thermal", 0.5, "fair", true, true},
		{"high pressure", 0.8, "nominal", true, false},
		{"over pressure", 0.95, "nominal", true, false},
		{"critical thermal", 0.3, "critical", true, false},
		{"both bad", 0.9, "critical", true, false},
		{"edge pressure", 0.79, "nominal", true, true},
		{"serious thermal ok", 0.3, "serious", true, true},
		{"all bad no model", 0.9, "critical", false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := streamEligible(tt.memoryPressure, tt.thermalState, tt.hasWarmModel)
			if got != tt.want {
				t.Errorf("streamEligible(%v, %q, %v) = %v, want %v",
					tt.memoryPressure, tt.thermalState, tt.hasWarmModel, got, tt.want)
			}
		})
	}
}

func TestStartSession_NoAccount(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "", "hardware", 64, 546)

	if len(tracker.ActiveSessions()) != 0 {
		t.Fatal("expected no sessions for unlinked provider")
	}
}

func TestStartSession_NoTrust(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "none", 64, 546)

	if len(tracker.ActiveSessions()) != 0 {
		t.Fatal("expected no sessions for unverified provider")
	}
}

func TestStartSession_SelfSignedAllowed(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "self_signed", 64, 400)

	if len(tracker.ActiveSessions()) != 1 {
		t.Fatal("self_signed providers should qualify")
	}
}

func TestStartSession_IneligibleMemory(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 24, 200)

	if len(tracker.ActiveSessions()) != 0 {
		t.Fatal("expected no sessions for 24GB machine")
	}
}

func TestStartSession_EligibleMemory(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 546)

	sessions := tracker.ActiveSessions()
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}
	if sessions[0].MemoryGB != 64 {
		t.Errorf("session memory = %d, want 64", sessions[0].MemoryGB)
	}
	if sessions[0].BandwidthGBs != 546 {
		t.Errorf("session bandwidth = %.0f, want 546", sessions[0].BandwidthGBs)
	}
	if sessions[0].MonthlyRateUSD < 15.9 || sessions[0].MonthlyRateUSD > 16.1 {
		t.Errorf("monthly rate = %.2f, want ~16.00", sessions[0].MonthlyRateUSD)
	}
}

func TestStartSession_Idempotent(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)

	if len(tracker.ActiveSessions()) != 1 {
		t.Fatal("duplicate StartSession should be no-op")
	}
}

func TestHeartbeat_NoSession(t *testing.T) {
	tracker, _ := newTestTracker()
	accrued := tracker.Heartbeat("p1", 0.3, "nominal", true)
	if accrued != 0 {
		t.Errorf("heartbeat without session should return 0, got %d", accrued)
	}
}

func TestHeartbeat_Ineligible(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)

	accrued := tracker.Heartbeat("p1", 0.9, "nominal", true)
	if accrued != 0 {
		t.Errorf("heartbeat with high memory pressure should return 0, got %d", accrued)
	}
}

func TestHeartbeat_NoModel(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)

	tracker.mu.Lock()
	tracker.sessions["p1"].LastAccrual = time.Now().Add(-2 * time.Minute)
	tracker.mu.Unlock()

	accrued := tracker.Heartbeat("p1", 0.3, "nominal", false)
	if accrued != 0 {
		t.Errorf("heartbeat without warm model should return 0, got %d", accrued)
	}
}

func TestHeartbeat_AccruesOverTime(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 48, 273)

	tracker.mu.Lock()
	tracker.sessions["p1"].LastAccrual = time.Now().Add(-2 * time.Minute)
	tracker.mu.Unlock()

	accrued := tracker.Heartbeat("p1", 0.3, "nominal", true)

	ratePerMin := StreamRatePerMin(12_000_000)
	expected := ratePerMin * 2
	if accrued < expected-10 || accrued > expected+10 {
		t.Errorf("heartbeat accrual = %d, want ~%d (±10)", accrued, expected)
	}
}

func TestHeartbeat_BandwidthAffectsRate(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 36, 150)
	tracker.StartSession("p2", "key2", "acc2", "hardware", 36, 546)

	tracker.mu.Lock()
	tracker.sessions["p1"].LastAccrual = time.Now().Add(-2 * time.Minute)
	tracker.sessions["p2"].LastAccrual = time.Now().Add(-2 * time.Minute)
	tracker.mu.Unlock()

	a1 := tracker.Heartbeat("p1", 0.3, "nominal", true)
	a2 := tracker.Heartbeat("p2", 0.3, "nominal", true)

	if a2 <= a1 {
		t.Errorf("higher bandwidth should earn more: a1=%d (150 GB/s), a2=%d (546 GB/s)", a1, a2)
	}
}

func TestHeartbeat_SkipsShortInterval(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)

	accrued := tracker.Heartbeat("p1", 0.3, "nominal", true)
	if accrued != 0 {
		t.Errorf("heartbeat within 30s should return 0, got %d", accrued)
	}
}

func TestStopSession_FlushesRemaining(t *testing.T) {
	tracker, st := newTestTracker()

	_ = st.Credit("acc1", 0, store.LedgerDeposit, "")

	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)

	tracker.mu.Lock()
	tracker.sessions["p1"].LastAccrual = time.Now().Add(-5 * time.Minute)
	tracker.mu.Unlock()
	tracker.Heartbeat("p1", 0.3, "nominal", true)

	tracker.StopSession("p1")

	if len(tracker.ActiveSessions()) != 0 {
		t.Fatal("expected 0 sessions after stop")
	}

	balance := st.GetBalance("acc1")
	if balance <= 0 {
		t.Errorf("expected positive balance after flush, got %d", balance)
	}
}

func TestStopSession_NoSession(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StopSession("nonexistent")
}

func TestFlushAll(t *testing.T) {
	tracker, st := newTestTracker()

	_ = st.Credit("acc1", 0, store.LedgerDeposit, "")
	_ = st.Credit("acc2", 0, store.LedgerDeposit, "")

	tracker.StartSession("p1", "key1", "acc1", "hardware", 36, 150)
	tracker.StartSession("p2", "key2", "acc2", "hardware", 128, 800)

	tracker.mu.Lock()
	tracker.sessions["p1"].LastAccrual = time.Now().Add(-3 * time.Minute)
	tracker.sessions["p2"].LastAccrual = time.Now().Add(-3 * time.Minute)
	tracker.mu.Unlock()

	tracker.Heartbeat("p1", 0.3, "nominal", true)
	tracker.Heartbeat("p2", 0.3, "nominal", true)

	tracker.FlushAll()

	b1 := st.GetBalance("acc1")
	b2 := st.GetBalance("acc2")
	if b1 <= 0 {
		t.Errorf("acc1 balance should be positive, got %d", b1)
	}
	if b2 <= 0 {
		t.Errorf("acc2 balance should be positive, got %d", b2)
	}
	if b2 <= b1 {
		t.Errorf("128GB/800bw machine should earn more than 36GB/150bw: b2=%d <= b1=%d", b2, b1)
	}
}

func TestFlushAll_NoAccrual(t *testing.T) {
	tracker, _ := newTestTracker()
	tracker.StartSession("p1", "key1", "acc1", "hardware", 64, 400)
	tracker.FlushAll()
}

func TestMultipleSessions(t *testing.T) {
	tracker, _ := newTestTracker()

	tracker.StartSession("p1", "key1", "acc1", "hardware", 36, 150)
	tracker.StartSession("p2", "key2", "acc2", "hardware", 48, 273)
	tracker.StartSession("p3", "key3", "acc3", "hardware", 96, 400)

	if len(tracker.ActiveSessions()) != 3 {
		t.Fatal("expected 3 sessions")
	}

	tracker.StopSession("p2")

	if len(tracker.ActiveSessions()) != 2 {
		t.Fatal("expected 2 sessions after stop")
	}
}

func TestStreamRatesRoundTrip(t *testing.T) {
	tiers := []struct {
		name    string
		memGB   int
		bw      float64
		monthly int64
	}{
		{"M3 Pro 36GB", 36, 150, 10_000_000},
		{"M4 Pro 48GB", 48, 273, 12_000_000},
		{"M1 Max 64GB", 64, 400, 15_000_000},
		{"M2 Max 96GB", 96, 400, 16_000_000},
		{"M2 Ultra 128GB", 128, 800, 20_000_000},
	}

	const minutesPerMonth = 30 * 24 * 60
	for _, tier := range tiers {
		t.Run(tier.name, func(t *testing.T) {
			rate := StreamRate(tier.memGB, tier.bw)
			if rate != tier.monthly {
				t.Errorf("StreamRate(%d, %.0f) = %d, want %d", tier.memGB, tier.bw, rate, tier.monthly)
			}
			perMin := StreamRatePerMin(rate)
			reconstructed := perMin * minutesPerMonth
			diff := tier.monthly - reconstructed
			if diff < 0 {
				diff = -diff
			}
			if diff > 50_000 {
				t.Errorf("round-trip error: monthly=%d, reconstructed=%d, diff=%d µUSD",
					tier.monthly, reconstructed, diff)
			}
		})
	}
}
