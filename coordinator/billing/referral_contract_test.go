package billing

import (
	"encoding/json"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
	"log/slog"
	"testing"
)

func TestReferralProgramFixedSpendShare(t *testing.T) {
	t.Setenv("EIGENINFERENCE_REFERRAL_SHARE_PCT", "50")
	st := store.NewMemory(store.Config{})
	svc := NewService(st, payments.NewLedger(st), slog.Default(), ReadConfig())
	if got := svc.Referral().SharePercent(); got != 5 {
		t.Fatalf("share = %d, want 5", got)
	}
	if _, err := svc.Referral().Register("partner", "PARTNER"); err != nil {
		t.Fatal(err)
	}
	stats, err := svc.Referral().Stats("partner")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(stats)
	var fields map[string]any
	_ = json.Unmarshal(data, &fields)
	if fields["reward_basis"] != "consumer_spend" {
		t.Fatalf("reward basis missing: %s", data)
	}
}

func TestReferralApplyRetryAndASCII(t *testing.T) {
	svc, _ := newTestService(t)
	if _, err := svc.Referral().Register("partner", "PARTNER"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := svc.Referral().Apply("consumer", " partner "); err != nil {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if _, err := svc.Referral().Register("unicode", "CÓDE"); err == nil {
		t.Fatal("non-ASCII referral code accepted")
	}
}

type unavailableReferrerStore struct{ store.Store }

func (s unavailableReferrerStore) GetReferrerByAccount(string) (*store.Referrer, error) {
	return nil, errors.New("database unavailable")
}

func TestReferralRegisterDoesNotTreatOutageAsMissing(t *testing.T) {
	inner := store.NewMemory(store.Config{})
	svc := NewReferralService(unavailableReferrerStore{inner}, slog.Default())
	if _, err := svc.Register("account", "PARTNER"); err == nil {
		t.Fatal("outage accepted")
	}
	if _, err := inner.GetReferrerByAccount("account"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("registered during outage: %v", err)
	}
}

func TestReferralApplyLegacyUnicodeCode(t *testing.T) {
	svc, st := newTestService(t)
	// Older releases allowed Unicode letters when creating codes.
	if err := st.CreateReferrer("legacy-partner", "CAFÉ"); err != nil {
		t.Fatal(err)
	}
	if err := svc.Referral().Apply("consumer", " café "); err != nil {
		t.Fatalf("legacy code no longer usable: %v", err)
	}
}
