package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// desktopMachine deliberately excludes device keys, attestation material,
// local hardware controls, and other fields from the interactive console API.
type desktopMachine struct {
	IsThisMac        bool     `json:"is_this_mac"`
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Chip             string   `json:"chip"`
	MemoryGB         int      `json:"memory_gb"`
	Status           string   `json:"status"`
	ObservedAt       *int64   `json:"observed_at,omitempty"`
	Version          string   `json:"version,omitempty"`
	Models           []string `json:"models"`
	EarningsMicroUSD *string  `json:"earnings_micro_usd,omitempty"`
}

type desktopAccount struct {
	Linked           bool             `json:"linked"`
	AccountID        string           `json:"account_id"`
	ObservedAt       int64            `json:"observed_at"`
	LifetimeMicroUSD string           `json:"lifetime_micro_usd"`
	WeekMicroUSD     string           `json:"week_micro_usd"`
	BalanceMicroUSD  string           `json:"balance_micro_usd"`
	Machines         []desktopMachine `json:"machines"`
}

// handleDesktopAccount authenticates a linked provider token directly. It is a
// read-only projection for its owner; consumer API keys cannot enumerate a fleet.
func (s *Server) handleDesktopAccount(w http.ResponseWriter, r *http.Request) {
	token, err := s.store.GetProviderToken(extractBearerToken(r))
	if err != nil || token == nil || !token.Active || token.AccountID == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "a linked provider token is required"))
		return
	}
	accountID := token.AccountID
	identity := r.Header.Get("X-Darkbloom-Device-Identity")
	if len(identity) > 4096 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", "invalid device identity"))
		return
	}
	cacheKey := fmt.Sprintf("desktop-account:%s:%x", accountID, sha256.Sum256([]byte(identity)))
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	fleet, err := s.mergeFleet(ctx, accountID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "fleet data unavailable"))
		return
	}
	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "earnings unavailable"))
		return
	}
	windows, err := s.accountEarningsWindows(accountID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "earnings windows unavailable"))
		return
	}
	now := time.Now()
	result := desktopAccount{Linked: true, AccountID: accountID, ObservedAt: now.Unix(),
		LifetimeMicroUSD: strconv.FormatInt(summary.TotalMicroUSD, 10),
		WeekMicroUSD:     strconv.FormatInt(windows.Last7dMicroUSD, 10),
		BalanceMicroUSD:  strconv.FormatInt(s.store.GetWithdrawableBalance(accountID), 10),
		Machines:         make([]desktopMachine, 0, len(fleet)),
	}
	for _, machine := range fleet {
		item := desktopMachine{IsThisMac: identity != "" && identity == machine.SEPublicKey, ID: machine.ID, Name: machine.Hardware.MachineModel, Chip: machine.Hardware.ChipName,
			MemoryGB: machine.Hardware.MemoryGB, Status: machine.Status, Version: machine.Version, Models: []string{}}
		if item.Name == "" {
			item.Name = "Mac"
		}
		if machine.LastSeen != nil {
			timestamp := machine.LastSeen.Unix()
			item.ObservedAt = &timestamp
		}
		if machine.LastHeartbeat != nil {
			timestamp := machine.LastHeartbeat.Unix()
			item.ObservedAt = &timestamp
		}
		item.Models = append(item.Models, machine.WarmModels...)
		item.EarningsMicroUSD = desktopUsageEarnings(ctx, s.store, accountID, machine.ProviderKey, now)

		result.Machines = append(result.Machines, item)
	}
	body, err := json.Marshal(result)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "could not encode account"))
		return
	}
	s.readCache.Set(cacheKey, body, 20*time.Second)
	writeCachedJSON(w, body)
}

// Earnings keys may survive an ownership change. Always scope historical rows
// to both the authenticated account and the current machine's known key.
func desktopUsageEarnings(ctx context.Context, st store.Store, accountID, providerKey string, now time.Time) *string {
	if providerKey == "" {
		return nil
	}
	rewards, ok := store.As[store.MachineRewardStore](st)
	if !ok {
		return nil
	}
	amount, err := rewards.SumProviderEarningsByKeysForAccount(ctx, accountID, []string{providerKey}, now.Add(-7*24*time.Hour), now)
	if err != nil {
		return nil
	}
	value := strconv.FormatInt(amount, 10)
	return &value
}
