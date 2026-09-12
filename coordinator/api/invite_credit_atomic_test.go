package api

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type separateInviteCreditFailure struct {
	store.Store
	calls int
}

func (s *separateInviteCreditFailure) Credit(string, int64, store.LedgerEntryType, string) error {
	s.calls++
	return errors.New("standalone balance write unavailable")
}

func TestInviteRedemptionDoesNotSplitCreditFromClaim(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	if err := memory.CreateInviteCode(&store.InviteCode{Code: "INV-ATOMIC", AmountMicroUSD: 2_000_000, MaxUses: 1, Active: true}); err != nil {
		t.Fatal(err)
	}
	st := &separateInviteCreditFailure{Store: memory}
	srv := NewServer(registry.New(slog.Default()), st, ServerConfig{}, slog.Default())
	defer srv.Close()
	request := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/v1/invite/redeem", strings.NewReader(`{"code":"inv-atomic"}`))
		r = r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, "invite-account"))
		w := httptest.NewRecorder()
		srv.handleRedeemInviteCode(w, r)
		return w
	}
	w := request()
	if w.Code != http.StatusOK {
		t.Errorf("status=%d body=%s; claimed=%v balance=%d", w.Code, w.Body.String(), memory.HasRedeemedInviteCode("INV-ATOMIC", "invite-account"), memory.GetBalance("invite-account"))
	}
	if st.calls != 0 {
		t.Errorf("made %d standalone credit calls after claiming invite", st.calls)
	}
	if balance := memory.GetBalance("invite-account"); balance != 2_000_000 {
		t.Errorf("balance=%d want2000000", balance)
	}
	if w := request(); w.Code != http.StatusBadRequest {
		t.Errorf("duplicate status=%d body=%s", w.Code, w.Body.String())
	}
	if memory.GetWithdrawableBalance("invite-account") != 0 {
		t.Fatal("invite credit became withdrawable")
	}
}
