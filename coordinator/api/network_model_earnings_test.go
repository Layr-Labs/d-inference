package api

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStatsIncludesPublicSevenDayModelEarnings(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now().UTC()
	for i, row := range []store.ProviderEarning{
		{AccountID: "private-account", ProviderID: "private-mac", Model: "large", AmountMicroUSD: 9007199254740993},
		{AccountID: "other-account", Model: "small", AmountMicroUSD: 20},
		{AccountID: "private-account", Model: "base_reward", AmountMicroUSD: 9999999},
	} {
		row.CreatedAt = now.Add(-time.Hour)
		row.JobID = string(rune('a' + i))
		if err := st.RecordProviderEarning(&row); err != nil {
			t.Fatal(err)
		}
	}
	body, capturedAt, _ := readStatsSnapshot(t, newStatsSnapshotServer(st))
	var response struct {
		Earnings struct {
			Window string                `json:"window"`
			Since  time.Time             `json:"since"`
			AsOf   time.Time             `json:"as_of"`
			Models []networkModelEarning `json:"models"`
		} `json:"model_earnings"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatal(err)
	}
	e := response.Earnings
	if e.Window != "7d" || !e.AsOf.Equal(capturedAt) || e.AsOf.Sub(e.Since) != 7*24*time.Hour {
		t.Fatalf("wrong window: %+v", e)
	}
	if len(e.Models) != 2 || e.Models[0].ID != "large" || e.Models[0].MicroUSD != "9007199254740993" || e.Models[1].ID != "small" {
		t.Fatalf("wrong ranking or precision: %+v", e.Models)
	}
	for _, private := range []string{"private-account", "private-mac", "other-account"} {
		if strings.Contains(string(body), private) {
			t.Fatal("public aggregate exposed identity")
		}
	}
}

type unavailableModelEarningsStore struct{ store.Store }

func (unavailableModelEarningsStore) NetworkModelEarnings(context.Context, time.Time, time.Time) (map[string]int64, error) {
	return nil, errors.New("database unavailable")
}

func TestStatsModelEarningsFailurePreservesOtherStats(t *testing.T) {
	body, _, _ := readStatsSnapshot(t, newStatsSnapshotServer(unavailableModelEarningsStore{store.NewMemory(store.Config{})}))
	var response map[string]json.RawMessage
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatal(err)
	}
	if string(response["model_earnings"]) != "null" || response["total_tokens"] == nil {
		t.Fatalf("failed aggregate changed stats: %s", body)
	}
}
