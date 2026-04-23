package payments

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func testEngine(t *testing.T) (*StreamEngine, *store.MemoryStore) {
	t.Helper()
	st := store.NewMemory("test-key")
	logger := testLogger()
	se := NewStreamEngine(st, logger, StreamEngineConfig{
		Enabled:         true,
		BudgetAccountID: "test_budget",
	})
	return se, st
}

func TestLookupStreamRate_ExactMatch(t *testing.T) {
	hw := protocol.Hardware{ChipFamily: "m4", MemoryGB: 64}
	rate := LookupStreamRate(hw)
	if rate.MonthlyMicroUSD != 17_000_000 {
		t.Errorf("m4:64 rate = %d, want 17_000_000", rate.MonthlyMicroUSD)
	}
}

func TestLookupStreamRate_FallbackToLowerBucket(t *testing.T) {
	hw := protocol.Hardware{ChipFamily: "m4", MemoryGB: 50}
	rate := LookupStreamRate(hw)
	// 50GB falls into 48GB bucket for m4
	if rate.MonthlyMicroUSD != 15_500_000 {
		t.Errorf("m4:50 rate = %d, want 15_500_000 (48GB bucket)", rate.MonthlyMicroUSD)
	}
}

func TestLookupStreamRate_FallbackToBase(t *testing.T) {
	hw := protocol.Hardware{ChipFamily: "unknown_chip", MemoryGB: 16}
	rate := LookupStreamRate(hw)
	if rate.MonthlyMicroUSD != 10_000_000 {
		t.Errorf("unknown chip rate = %d, want 10_000_000 (base)", rate.MonthlyMicroUSD)
	}
}

func TestLookupStreamRate_AllFamilies(t *testing.T) {
	families := []string{"m1", "m2", "m3", "m4"}
	for _, f := range families {
		hw := protocol.Hardware{ChipFamily: f, MemoryGB: 16}
		rate := LookupStreamRate(hw)
		if rate.MonthlyMicroUSD < 10_000_000 || rate.MonthlyMicroUSD > 20_000_000 {
			t.Errorf("%s:16 rate = %d, want in range [10M, 20M]", f, rate.MonthlyMicroUSD)
		}
	}
}

func TestMonthlyRateToPerSecond(t *testing.T) {
	// $15/mo = 15_000_000 micro-USD / 2_592_000 seconds ≈ 5 micro-USD/sec
	perSec := MonthlyRateToPerSecond(15_000_000)
	if perSec < 5 || perSec > 6 {
		t.Errorf("per-second rate = %d, want ~5", perSec)
	}
}

func TestStreamEngine_DisabledNoPayment(t *testing.T) {
	st := store.NewMemory("test-key")
	se := NewStreamEngine(st, testLogger(), StreamEngineConfig{Enabled: false})

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("disabled engine paid %d, want 0", paid)
	}
}

func TestStreamEngine_NoAccountNoPayment(t *testing.T) {
	se, _ := testEngine(t)

	paid := se.ProcessHeartbeat("p1", "",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("unlinked provider paid %d, want 0", paid)
	}
}

func TestStreamEngine_FirstHeartbeatInitializesOnly(t *testing.T) {
	se, _ := testEngine(t)

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("first heartbeat paid %d, want 0 (initialization)", paid)
	}
}

func TestStreamEngine_SecondHeartbeatPays(t *testing.T) {
	se, st := testEngine(t)

	// Create account
	_ = st.CreateUser(&store.User{AccountID: "acct1", PrivyUserID: "did:privy:test"})

	// First heartbeat — initializes
	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Simulate time passing
	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	// Second heartbeat — should pay
	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	if paid <= 0 {
		t.Errorf("second heartbeat paid %d, want > 0", paid)
	}

	// Check account was credited
	balance := st.GetBalance("acct1")
	if balance != paid {
		t.Errorf("account balance = %d, want %d", balance, paid)
	}
}

func TestStreamEngine_HighMemoryPressureSkips(t *testing.T) {
	se, _ := testEngine(t)

	// Initialize
	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	// High memory pressure heartbeat
	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.90, ThermalState: "nominal"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("high memory pressure paid %d, want 0", paid)
	}
}

func TestStreamEngine_CriticalThermalSkips(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "critical"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("critical thermal paid %d, want 0", paid)
	}
}

func TestStreamEngine_ServingStatusPays(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"serving",
	)

	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"serving",
	)
	if paid <= 0 {
		t.Errorf("serving status should pay, got %d", paid)
	}
}

func TestStreamEngine_UnknownStatusSkips(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"offline",
	)
	if paid != 0 {
		t.Errorf("offline status should not pay, got %d", paid)
	}
}

func TestStreamEngine_MaxPaymentGapCaps(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Simulate very long gap (5 minutes)
	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-5 * time.Minute)
	se.mu.Unlock()

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Should be capped at MaxPaymentGap (60s) worth of payment
	rate := LookupStreamRate(protocol.Hardware{ChipFamily: "m4", MemoryGB: 64})
	perSec := MonthlyRateToPerSecond(rate.MonthlyMicroUSD)
	maxPay := perSec * 60

	if paid > maxPay {
		t.Errorf("payment %d exceeds max gap cap %d", paid, maxPay)
	}
	if paid <= 0 {
		t.Errorf("payment should be > 0 after long gap, got %d", paid)
	}
}

func TestStreamEngine_DisconnectCleansUp(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	if se.GetProviderStreamState("p1") == nil {
		t.Fatal("stream state should exist after heartbeat")
	}

	se.OnProviderDisconnect("p1")

	if se.GetProviderStreamState("p1") != nil {
		t.Error("stream state should be nil after disconnect")
	}
}

func TestStreamEngine_Stats(t *testing.T) {
	se, _ := testEngine(t)

	// Initialize two providers
	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	se.ProcessHeartbeat("p2", "acct2",
		protocol.Hardware{ChipFamily: "m3", MemoryGB: 32},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	stats := se.Stats()
	if stats.ActiveProviders != 2 {
		t.Errorf("active providers = %d, want 2", stats.ActiveProviders)
	}
}

func TestStreamEngine_MultipleProviders(t *testing.T) {
	se, st := testEngine(t)

	// Initialize both
	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 128},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	se.ProcessHeartbeat("p2", "acct2",
		protocol.Hardware{ChipFamily: "m1", MemoryGB: 16},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Simulate time
	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.states["p2"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	paid1 := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 128},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	paid2 := se.ProcessHeartbeat("p2", "acct2",
		protocol.Hardware{ChipFamily: "m1", MemoryGB: 16},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// M4 128GB should pay more than M1 16GB
	if paid1 <= paid2 {
		t.Errorf("m4:128 paid %d should be > m1:16 paid %d", paid1, paid2)
	}

	bal1 := st.GetBalance("acct1")
	bal2 := st.GetBalance("acct2")
	if bal1 != paid1 {
		t.Errorf("acct1 balance = %d, want %d", bal1, paid1)
	}
	if bal2 != paid2 {
		t.Errorf("acct2 balance = %d, want %d", bal2, paid2)
	}
}

func TestStreamEngine_MinPaymentInterval(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Set last payment to 1 second ago (less than MinPaymentInterval)
	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-1 * time.Second)
	se.mu.Unlock()

	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)
	if paid != 0 {
		t.Errorf("payment within min interval should be 0, got %d", paid)
	}
}

func TestStreamEngine_FairThermalPays(t *testing.T) {
	se, _ := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	se.mu.Lock()
	se.states["p1"].LastPaymentTime = time.Now().Add(-10 * time.Second)
	se.mu.Unlock()

	// "fair" thermal is acceptable, "serious" too — only "critical" stops payment
	paid := se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "fair"},
		"idle",
	)
	if paid <= 0 {
		t.Errorf("fair thermal should pay, got %d", paid)
	}
}

func TestStreamEngine_MemBucket(t *testing.T) {
	tests := []struct {
		gb   int
		want string
	}{
		{8, "16"},
		{16, "16"},
		{17, "16"},
		{24, "24"},
		{31, "24"},
		{32, "32"},
		{36, "36"},
		{48, "48"},
		{64, "64"},
		{96, "96"},
		{128, "128"},
		{192, "192"},
		{256, "256"},
		{512, "256"},
	}
	for _, tt := range tests {
		got := memBucket(tt.gb)
		if got != tt.want {
			t.Errorf("memBucket(%d) = %q, want %q", tt.gb, got, tt.want)
		}
	}
}

func TestStreamEngine_PaymentAccumulates(t *testing.T) {
	se, st := testEngine(t)

	se.ProcessHeartbeat("p1", "acct1",
		protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
		protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
		"idle",
	)

	// Simulate 3 heartbeats with 5s intervals
	var totalPaid int64
	for i := 0; i < 3; i++ {
		se.mu.Lock()
		se.states["p1"].LastPaymentTime = time.Now().Add(-5 * time.Second)
		se.mu.Unlock()

		paid := se.ProcessHeartbeat("p1", "acct1",
			protocol.Hardware{ChipFamily: "m4", MemoryGB: 64},
			protocol.SystemMetrics{MemoryPressure: 0.3, ThermalState: "nominal"},
			"idle",
		)
		totalPaid += paid
	}

	if totalPaid <= 0 {
		t.Fatal("total paid should be > 0 after 3 heartbeats")
	}

	balance := st.GetBalance("acct1")
	if balance != totalPaid {
		t.Errorf("account balance %d != total paid %d", balance, totalPaid)
	}

	state := se.GetProviderStreamState("p1")
	if state == nil {
		t.Fatal("stream state should exist")
	}
	if state.TotalPaidSession != totalPaid {
		t.Errorf("session total %d != total paid %d", state.TotalPaidSession, totalPaid)
	}
}

func TestStreamEngine_DisconnectUnknown(t *testing.T) {
	se, _ := testEngine(t)
	// Should not panic.
	se.OnProviderDisconnect("nonexistent")
}
