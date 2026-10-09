package operations_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

const autopilotRewardsPath = "/v1/admin/autopilot/rewards"

func TestAutopilotRewardRateLimitKeepsNoStoreAndDoesNotFund(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, srv, server := newAutopilotMachineHTTP(t, st)
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	srv.SetAdminEmails([]string{"rate-admin@example.test"})
	if err := st.CreateUser(&store.User{AccountID: "rate-admin", PrivyUserID: "did:privy:rate-admin", Email: "rate-admin@example.test"}); err != nil {
		t.Fatal(err)
	}
	adminJWT := testkit.NewSessions(t, srv, st).Token("rate-admin")
	autopilotMachineRequest(t, server, http.MethodPatch, autopilotRewardsPath+"/pool", adminJWT, `{"cap_micro_usd":100}`, http.StatusOK)
	autopilotMachineRequest(t, server, http.MethodPatch, autopilotRewardsPath+"/pool", adminJWT, `{"cap_micro_usd":200}`, http.StatusTooManyRequests)
	pool, err := st.AutopilotRewardPool(context.Background())
	if err != nil || pool.CapMicroUSD != 100 || pool.SpentMicroUSD != 0 {
		t.Fatalf("throttled request changed money: %+v %v", pool, err)
	}
}

func TestAutopilotRewardsAdminAuthorizationPrecedesParsing(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, srv, server := newAutopilotMachineHTTP(t, st)
	userKey, err := st.CreateKeyForAccount("reward-nonadmin")
	if err != nil {
		t.Fatal(err)
	}
	for _, auth := range []struct {
		token  string
		status int
	}{
		{"", http.StatusUnauthorized}, {"invalid-key", http.StatusUnauthorized}, {userKey, http.StatusForbidden},
	} {
		for _, request := range []struct{ method, path, body string }{
			{http.MethodGet, autopilotRewardsPath + "?limit=bad", ""},
			{http.MethodPatch, autopilotRewardsPath + "/pool", `{"cap_micro_usd":`},
			{http.MethodPost, autopilotRewardsPath + "/machines/not-a-uuid/baseline", `{}`},
		} {
			autopilotMachineRequest(t, server, request.method, request.path, auth.token, request.body, auth.status)
		}
	}
	srv.SetAdminEmails([]string{"reward-admin@example.test"})
	if err := st.CreateUser(&store.User{AccountID: "reward-admin", PrivyUserID: "did:privy:reward-admin", Email: "reward-admin@example.test"}); err != nil {
		t.Fatal(err)
	}
	adminJWT := testkit.NewSessions(t, srv, st).Token("reward-admin")
	for _, token := range []string{autopilotMachinesAdminKey, adminJWT} {
		autopilotMachineRequest(t, server, http.MethodPatch, autopilotRewardsPath+"/pool", token, `{"cap_micro_usd":100}`, http.StatusOK)
		autopilotMachineRequest(t, server, http.MethodGet, autopilotRewardsPath, token, "", http.StatusOK)
	}
	pool, err := st.AutopilotRewardPool(context.Background())
	if err != nil || pool.CapMicroUSD != 100 || pool.SpentMicroUSD != 0 {
		t.Fatalf("funding mutated payments: %+v %v", pool, err)
	}
}

func TestAutopilotRewardPoolRejectsAmbiguousAmounts(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	for _, body := range []string{
		``, `{}`, `null`, `[]`, `{"cap_micro_usd":null}`, `{"cap_micro_usd":-1}`,
		`{"cap_micro_usd":1.5}`, `{"cap_micro_usd":"100"}`, `{"cap_micro_usd":9223372036854775808}`,
		`{"cap_micro_usd":0,"cap_micro_usd":100}`, `{"CAP_MICRO_USD":100}`, `{"cap_micro_usd":100,"enabled":true}`,
		`{"cap_micro_usd":100} {}`, `{"cap_micro_usd":100}null`, `{"cap_micro_usd":100}` + strings.Repeat(" ", 1024),
	} {
		autopilotMachineRequest(t, server, http.MethodPatch, autopilotRewardsPath+"/pool", autopilotMachinesAdminKey, body, http.StatusBadRequest)
	}
	pool, err := st.AutopilotRewardPool(context.Background())
	if err != nil || pool.CapMicroUSD != 0 || pool.SpentMicroUSD != 0 {
		t.Fatalf("invalid requests funded pool: %+v %v", pool, err)
	}
}

func TestAutopilotRewardPaginationQueries(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	for _, query := range []string{
		"?limit=0", "?limit=201", "?limit=1&limit=2", "?limit=", "?limit=1.5", "?limit=1e2", "?limit=9223372036854775808",
		"?after=*", "?after=", "?after=00000000-0000-0000-0000-000000000000", "?after=*&after=*",
		"?unknown=true", "?LIMIT=1", "?limit=%zz", "?limit=1;after=*",
	} {
		autopilotMachineRequest(t, server, http.MethodGet, autopilotRewardsPath+query, autopilotMachinesAdminKey, "", http.StatusBadRequest)
	}
	for _, query := range []string{
		"", "?limit=1", "?limit=200", "?limit=001", "?limit=%2B1",
		"?after=abcdefab-1234-1234-1234-abcdefabcdef", "?after=ABCDEFAB-1234-1234-1234-ABCDEFABCDEF&limit=1",
	} {
		body := autopilotMachineRequest(t, server, http.MethodGet, autopilotRewardsPath+query, autopilotMachinesAdminKey, "", http.StatusOK)
		var page struct {
			Enrollments []earningsfloor.Enrollment `json:"enrollments"`
			NextAfter   string                     `json:"next_after"`
		}
		if err := json.Unmarshal(body, &page); err != nil || page.Enrollments == nil || len(page.Enrollments) != 0 || page.NextAfter != "" {
			t.Fatalf("empty page for %q: %s (%v)", query, body, err)
		}
	}
}

func TestAutopilotRewardHistoricalBaselineRepairDoesNotReanchor(t *testing.T) {
	now := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	st := memory.NewMemory(store.Config{Now: func() time.Time { return now }})
	_, _, server := newAutopilotMachineHTTP(t, st)
	machine, err := st.ObserveMachine(context.Background(), store.MachineObservation{
		SessionID: "historic-autopilot", AccountID: "historic-owner", SEKey: "historic-key", At: now.AddDate(0, 0, -20), Source: "live_registration",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveAutopilotConsent(context.Background(), earningsfloor.Consent{
		SessionID: "historic-autopilot", AccountID: "historic-owner", Supported: true, OptedIn: true, At: now,
	}); err != nil {
		t.Fatal(err)
	}
	path := autopilotRewardsPath + "/machines/" + machine.ID + "/baseline"
	for _, body := range []string{
		`{}`, `null`, `{"first_opt_in_at":"2026-10-08T00:00:00Z","seven_day_earnings_micro_usd":null,"evidence":"archive"}`,
		`{"first_opt_in_at":"bad","seven_day_earnings_micro_usd":70000000,"evidence":"archive"}`,
		`{"first_opt_in_at":"2026-10-08T00:00:00Z","seven_day_earnings_micro_usd":-1,"evidence":"archive"}`,
		`{"first_opt_in_at":"2026-10-08T00:00:00Z","seven_day_earnings_micro_usd":70000000,"evidence":" "}`,
		`{"first_opt_in_at":"2026-10-08T00:00:00Z","seven_day_earnings_micro_usd":70000000,"evidence":"archive","evidence":"different"}`,
	} {
		autopilotMachineRequest(t, server, http.MethodPost, path, autopilotMachinesAdminKey, body, http.StatusBadRequest)
	}
	body := `{"first_opt_in_at":"2026-10-08T00:00:00Z","seven_day_earnings_micro_usd":70000000,"evidence":"verified original opt-in plus complete seven-day inference archive"}`
	data := autopilotMachineRequest(t, server, http.MethodPost, path, autopilotMachinesAdminKey, body, http.StatusOK)
	var restored struct {
		Enrollment earningsfloor.Enrollment `json:"enrollment"`
	}
	if err := json.Unmarshal(data, &restored); err != nil || !restored.Enrollment.BaselineKnown || restored.Enrollment.DailyFloorMicroUSD != 11_000_000 || restored.Enrollment.FirstOptInAt == nil || restored.Enrollment.FirstOptInAt.Format(time.RFC3339) != "2026-10-08T00:00:00Z" {
		t.Fatalf("bad repair response: %s (%v)", data, err)
	}
	if !restored.Enrollment.NextDay.Equal(now) {
		t.Fatal("historical baseline repair manufactured past reward days")
	}
	autopilotMachineRequest(t, server, http.MethodPost, path, autopilotMachinesAdminKey, strings.Replace(body, "70000000", "140000000", 1), http.StatusConflict)
	data = autopilotMachineRequest(t, server, http.MethodGet, autopilotRewardsPath+"?limit=1", autopilotMachinesAdminKey, "", http.StatusOK)
	var status struct {
		Enabled     bool                       `json:"enabled"`
		Pool        earningsfloor.Pool         `json:"pool"`
		Enrollments []earningsfloor.Enrollment `json:"enrollments"`
		NextAfter   string                     `json:"next_after"`
	}
	if err := json.Unmarshal(data, &status); err != nil || status.Enabled || len(status.Enrollments) != 1 || status.NextAfter != machine.ID || status.Enrollments[0].SevenDayEarningsMicroUSD != 70_000_000 || status.Pool.CapMicroUSD != 0 {
		t.Fatalf("read projection changed policy: %s (%v)", data, err)
	}
	autopilotMachineRequest(t, server, http.MethodGet, fmt.Sprintf("%s?after=%s&limit=1", autopilotRewardsPath, machine.ID), autopilotMachinesAdminKey, "", http.StatusOK)
}
