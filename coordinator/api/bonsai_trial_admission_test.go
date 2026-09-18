package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/trial"
)

func bonsaiUnitServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	s, st, _ := billingTestServer(t)
	s.bonsaiTrial = trial.Config{Enabled: true, CampaignID: trial.DefaultCampaignID,
		ModelIDs: []string{trial.BonsaiBuildID, "synthetic-bonsai-fallback"}, TokenLimit: trial.DefaultTokenLimit,
		Rates: trial.Rates{InputMicroUSDPerMillion: 12_000, OutputMicroUSDPerMillion: 47_000}}
	for _, model := range s.bonsaiTrial.ModelIDs {
		if err := st.SetModelVersion(&store.ModelRegistryEntry{ID: model, MaxContextLength: 4096, MaxOutputLength: 1024, Status: "active"}, &store.ModelVersion{ModelID: model, Version: "test-v1", Status: "ready"}, nil); err != nil {
			t.Fatal(err)
		}
		if err := st.PromoteModelVersion(model, "test-v1"); err != nil {
			t.Fatal(err)
		}
		if err := st.SetModelPrice("platform", model, 12_000, 47_000); err != nil {
			t.Fatal(err)
		}
	}
	return s, st
}

func bonsaiUnitRequest(kind trial.AuthKind, endpoint, account string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, endpoint, nil)
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, account)
	ctx = context.WithValue(ctx, ctxKeyAuthKind, kind)
	return r.WithContext(ctx)
}

func bonsaiUnitPrepared(t *testing.T, s *Server, r *http.Request) *http.Request {
	t.Helper()
	w := httptest.NewRecorder()
	r, ok := s.prepareBonsaiTrial(w, r, trial.BonsaiBuildID, false, false, &selfRoutePolicy{}, registry.RequestTraits{})
	if !ok || trialFromRequest(r) == nil {
		t.Fatalf("prepare failed: ok=%v response=%s", ok, w.Body.String())
	}
	return r
}

func TestBonsaiTrialPrepareAuthAndEndpointScope(t *testing.T) {
	s, _ := bonsaiUnitServer(t)
	for _, kind := range []trial.AuthKind{trial.AuthSession, trial.AuthAPIKey, trial.AuthAdmin, trial.AuthProvider, ""} {
		for _, endpoint := range []string{trial.ChatEndpoint, "/v1/responses", "/v1/completions", "/v1/messages"} {
			for _, model := range []string{trial.BonsaiBuildID, "synthetic-bonsai-fallback", "unrelated-model", trial.BonsaiBuildID + "-other"} {
				w := httptest.NewRecorder()
				r := bonsaiUnitRequest(kind, endpoint, "account")
				// Client claims cannot manufacture the verified context marker.
				r.Header.Set("X-Auth-Kind", "session")
				r.Header.Set("X-Free-Trial", "true")
				prepared, ok := s.prepareBonsaiTrial(w, r, model, false, false, &selfRoutePolicy{}, registry.RequestTraits{})
				wantTrial := kind == trial.AuthSession && endpoint == trial.ChatEndpoint && (model == trial.BonsaiBuildID || model == "synthetic-bonsai-fallback")
				if !ok || (trialFromRequest(prepared) != nil) != wantTrial {
					t.Errorf("kind=%q endpoint=%q model=%q: ok=%v trial=%v want=%v", kind, endpoint, model, ok, trialFromRequest(prepared) != nil, wantTrial)
				}
			}
		}
	}
}

func TestBonsaiTrialPrepareDisabledAndUnsupported(t *testing.T) {
	for _, scenario := range []string{"disabled", "bad config", "media", "responses", "owned"} {
		t.Run(scenario, func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			policy := &selfRoutePolicy{enabled: scenario == "owned"}
			if scenario == "disabled" {
				s.bonsaiTrial.Enabled = false
			}
			if scenario == "bad config" {
				s.bonsaiTrial.Rates.InputMicroUSDPerMillion = 0
			}
			w := httptest.NewRecorder()
			r := bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, testConsumerID)
			before := st.GetBalance(testConsumerID)
			prepared, ok := s.prepareBonsaiTrial(w, r, trial.BonsaiBuildID, scenario == "responses", scenario == "media", policy, registry.RequestTraits{})
			if scenario == "responses" || scenario == "owned" {
				if !ok || trialFromRequest(prepared) != nil {
					t.Fatal("non-trial path incorrectly rejected or subsidized")
				}
			} else if ok || w.Code != http.StatusServiceUnavailable {
				t.Fatalf("unsupported trial not rejected: ok=%v status=%d", ok, w.Code)
			}
			if st.GetBalance(testConsumerID) != before {
				t.Fatal("preparation charged consumer")
			}
		})
	}
}

func TestBonsaiTrialReserveFinalBuildSnapshotAndBound(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	fee := int64(25)
	r := bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "fresh-zero-balance-account")
	r = r.WithContext(context.WithValue(r.Context(), auth.CtxKeyUser, &store.User{PlatformFeePercent: &fee}))
	r = bonsaiUnitPrepared(t, s, r)
	if err := s.reserveBonsaiTrial(r, "synthetic-bonsai-fallback", 100); err != nil {
		t.Fatal(err)
	}
	reservation := trialReservationFromRequest(r)
	if reservation == nil || reservation.Model != "synthetic-bonsai-fallback" || reservation.ReservedTokens != 4196 || reservation.LimitTokens != 5_000_000 {
		t.Fatalf("wrong reservation: %+v", reservation)
	}
	fee = 99
	s.bonsaiTrial.Rates.InputMicroUSDPerMillion = 999
	var snapshot trialPriceSnapshot
	if err := json.Unmarshal(reservation.PricingJSON, &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Rates.InputMicroUSDPerMillion != 12_000 || snapshot.FeePercent == nil || *snapshot.FeePercent != 25 {
		t.Fatalf("admission snapshot changed: %+v", snapshot)
	}
	a, err := st.GetTrialAllowance(context.Background(), reservation.AccountID, reservation.CampaignID)
	if err != nil || a.ReservedTokens != 4196 || a.UsedTokens != 0 {
		t.Fatalf("allowance=%+v err=%v", a, err)
	}
	if st.GetBalance(reservation.AccountID) != 0 {
		t.Fatal("trial created consumer money")
	}
}

func TestBonsaiTrialReserveRejectsUnverifiedModelAndPrice(t *testing.T) {
	for _, scenario := range []string{"fallback outside allowlist", "missing model", "missing context", "missing price", "price mismatch", "output above model limit", "zero output"} {
		t.Run(scenario, func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "account"))
			model, output, want := trial.BonsaiBuildID, 100, store.ErrTrialUnavailable
			switch scenario {
			case "fallback outside allowlist":
				model = "unrelated-model"
			case "missing model":
				model = "missing-build"
				s.bonsaiTrial.ModelIDs = append(s.bonsaiTrial.ModelIDs, model)
			case "missing context":
				_ = st.UpsertModelRegistryEntry(&store.ModelRegistryEntry{ID: model, MaxContextLength: 0})
			case "missing price":
				_ = st.DeleteModelPrice("platform", model)
			case "price mismatch":
				_ = st.SetModelPrice("platform", model, 12_001, 47_000)
			case "output above model limit":
				output, want = 1025, store.ErrTrialRequestTooLarge
			case "zero output":
				output = 0
			}
			if err := s.reserveBonsaiTrial(r, model, output); !errors.Is(err, want) {
				t.Fatalf("got %v, want %v", err, want)
			}
			if trialReservationFromRequest(r) != nil {
				t.Fatal("rejected request created reservation")
			}
		})
	}
	// API-key admission has no trial context and must not touch the quota even
	// when the final model would otherwise qualify.
	s, st := bonsaiUnitServer(t)
	r := bonsaiUnitRequest(trial.AuthAPIKey, trial.ChatEndpoint, "key-account")
	if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetTrialAllowance(r.Context(), "key-account", s.bonsaiTrial.CampaignID); !errors.Is(err, store.ErrTrialNotFound) {
		t.Fatalf("API key mutated quota: %v", err)
	}
}

func TestBonsaiTrialErrorContract(t *testing.T) {
	s, _ := bonsaiUnitServer(t)
	for _, tc := range []struct {
		err           error
		status        int
		code, message string
	}{
		{store.ErrTrialExhausted, 402, trial.ExhaustedCode, trial.ExhaustedMessage},
		{store.ErrTrialRequestTooLarge, 402, trial.RequestTooLargeCode, trial.RequestTooLargeMessage},
		{store.ErrTrialBusy, 429, trial.BusyCode, trial.BusyMessage},
		{store.ErrTrialUnavailable, 503, trial.UnavailableCode, trial.UnavailableMessage},
		{errors.New("private database failure"), 503, trial.UnavailableCode, trial.UnavailableMessage},
	} {
		w := httptest.NewRecorder()
		s.writeTrialError(w, tc.err)
		var body struct {
			Error struct{ Code, Message, Type string }
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if w.Code != tc.status || body.Error.Code != tc.code || body.Error.Message != tc.message || body.Error.Type != "insufficient_quota" {
			t.Fatalf("wrong error: %d %s", w.Code, w.Body.String())
		}
		if (w.Header().Get("Retry-After") == "1") != (tc.status == 429) {
			t.Fatal("incorrect retry header")
		}
	}
}

func TestBonsaiTrialFinishUndispatchedOnly(t *testing.T) {
	for _, dispatched := range []bool{false, true} {
		s, st := bonsaiUnitServer(t)
		r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "account"))
		if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 100); err != nil {
			t.Fatal(err)
		}
		tr := trialFromRequest(r)
		if dispatched {
			if err := st.MarkTrialDispatched(r.Context(), tr.reservation.ID); err != nil {
				t.Fatal(err)
			}
			tr.committed.Store(true)
		}
		s.finishTrialRequest(r)
		s.finishTrialRequest(r)
		got, err := st.GetTrialReservation(r.Context(), tr.reservation.ID)
		want := store.TrialReleased
		if dispatched {
			want = store.TrialDispatched
		}
		if err != nil || got.State != want {
			t.Fatalf("dispatched=%v state=%s err=%v", dispatched, got.State, err)
		}
	}
}

// Embedding only Store intentionally hides optional trial capabilities, as an
// unsupported backend would; this is not an Unwrap decorator.
type bonsaiUnsupportedStore struct{ store.Store }

func TestBonsaiTrialOptionalStoreCapabilityAndDecorator(t *testing.T) {
	for _, supported := range []bool{false, true} {
		s, st := bonsaiUnitServer(t)
		if supported {
			s.store = store.NewCached(st, store.CacheConfig{})
		} else {
			s.store = bonsaiUnsupportedStore{Store: st}
		}
		w := httptest.NewRecorder()
		r := bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "account")
		prepared, ok := s.prepareBonsaiTrial(w, r, trial.BonsaiBuildID, false, false, &selfRoutePolicy{}, registry.RequestTraits{})
		if ok != supported {
			t.Fatalf("supported=%v ok=%v status=%d", supported, ok, w.Code)
		}
		if supported {
			if err := s.reserveBonsaiTrial(prepared, trial.BonsaiBuildID, 100); err != nil {
				t.Fatal(err)
			}
			a, err := st.GetTrialAllowance(r.Context(), "account", s.bonsaiTrial.CampaignID)
			if err != nil || a.ReservedTokens != 4196 {
				t.Fatalf("decorator hid trial write: %+v, %v", a, err)
			}
		} else if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("unsupported storage status=%d", w.Code)
		}
	}
}
