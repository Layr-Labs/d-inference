package store

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestConsumeDeviceCodeMemory(t *testing.T) { deviceCodeConsumptionContract(t, NewMemory(Config{})) }
func TestConsumeDeviceCodePostgres(t *testing.T) {
	deviceCodeConsumptionContract(t, testPostgresStore(t))
}

func deviceCodeConsumptionContract(t *testing.T, s Store) {
	t.Helper()
	for _, scenario := range []struct {
		name, status string
		expired      bool
		allowed      bool
	}{
		{"approved", "approved", false, true},
		{"pending", "pending", false, false},
		{"consumed", "consumed", false, false},
		{"expired", "approved", true, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			expiry := time.Now().Add(time.Hour)
			if scenario.expired {
				expiry = time.Now().Add(-time.Hour)
			}
			code := "consumption-" + scenario.name
			if err := s.CreateDeviceCode(&DeviceCode{DeviceCode: code, UserCode: fmt.Sprintf("C-%s", scenario.name), Status: scenario.status, AccountID: "consumption-account", ExpiresAt: expiry}); err != nil {
				t.Fatal(err)
			}
			var winners atomic.Int32
			var group sync.WaitGroup
			for range 16 {
				group.Add(1)
				go func() {
					defer group.Done()
					if s.ConsumeDeviceCode(code) == nil {
						winners.Add(1)
					}
				}()
			}
			group.Wait()
			want := int32(0)
			if scenario.allowed {
				want = 1
			}
			if got := winners.Load(); got != want {
				t.Fatalf("successful exchanges = %d, want %d", got, want)
			}
			stored, err := s.GetDeviceCode(code)
			if err != nil {
				t.Fatal(err)
			}
			wantStatus := scenario.status
			if scenario.allowed {
				wantStatus = "consumed"
			}
			if stored.Status != wantStatus || stored.AccountID != "consumption-account" {
				t.Fatalf("unexpected grant after exchange: %+v", stored)
			}
			if err := s.ConsumeDeviceCode(code); err == nil {
				t.Fatal("grant exchanged again")
			}
		})
	}
	if err := s.ConsumeDeviceCode("missing-grant"); err == nil {
		t.Fatal("unknown grant exchanged")
	}
}
