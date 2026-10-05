package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
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
	// seKey is kept in the cached projection to derive IsThisMac per request.
	// Unexported, so it is never serialized.
	seKey string
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

const (
	desktopAccountCacheTTL    = 20 * time.Second
	desktopIdentityHeader     = "X-Darkbloom-Device-Identity"
	desktopIdentityMaxBytes   = 4096
	desktopAccountCachePrefix = "desktop-account:"
	desktopRateLimitTier      = "desktop"
	desktopAuthKind           = "provider_token"
)

// requireDesktopProviderToken authenticates only an active, account-linked
// provider token (never Privy JWTs, the admin key, or consumer API keys, which
// requireAuth would accept). It runs on every request, so revocation is
// enforced before any cached projection is read.
func (s *Server) requireDesktopProviderToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setOutcomeStage(r, "auth")
		token, err := s.store.GetProviderToken(extractBearerToken(r))
		if err != nil || token == nil || !token.Active || token.AccountID == "" || strings.HasPrefix(extractBearerToken(r), desktopAccountTokenPrefix) {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "a linked provider token is required"))
			return
		}
		stampAuth(r, desktopAuthKind, true)
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, token.AccountID)))
	}
}

// rateLimitDesktop applies the per-account request limiter (the account's
// inference bucket, read at request time) under its own metrics tier label.
func (s *Server) rateLimitDesktop(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(s.rateLimiterFn, desktopRateLimitTier, next)
}

// handleDesktopAccount is a read-only projection for the token's owner;
// consumer API keys cannot enumerate a fleet. The projection is cached per
// account only: the identity header is client-controlled, so it selects This
// Mac per request and never keys the cache.
func (s *Server) handleDesktopAccount(w http.ResponseWriter, r *http.Request) {
	accountID := consumerKeyFromContext(r.Context())
	if accountID == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "a linked provider token is required"))
		return
	}
	identity := r.Header.Get(desktopIdentityHeader)
	if len(identity) > desktopIdentityMaxBytes {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", "invalid device identity"))
		return
	}
	projection, ok := s.cachedDesktopAccount(accountID)
	if !ok {
		var status int
		var err error
		projection, status, err = s.buildDesktopAccount(r.Context(), accountID)
		if err != nil {
			writeJSON(w, status, errorResponse("unavailable", err.Error()))
			return
		}
		if s.readCache != nil {
			s.readCache.SetValue(desktopAccountCachePrefix+accountID, projection, desktopAccountCacheTTL)
		}
	}
	body, err := json.Marshal(projection.forIdentity(identity))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "could not encode account"))
		return
	}
	writeCachedJSON(w, body)
}

func (s *Server) cachedDesktopAccount(accountID string) (*desktopAccount, bool) {
	value, ok := s.readCacheGetValue(desktopAccountCachePrefix + accountID)
	if !ok {
		return nil, false
	}
	projection, ok := value.(*desktopAccount)
	return projection, ok && projection != nil
}

// forIdentity renders a per-request copy of the shared (immutable) cached
// projection with IsThisMac set for the machine whose SE key matches.
func (a *desktopAccount) forIdentity(identity string) desktopAccount {
	out := *a
	out.Machines = make([]desktopMachine, len(a.Machines))
	for i, machine := range a.Machines {
		machine.IsThisMac = identity != "" && identity == machine.seKey
		out.Machines[i] = machine
	}
	return out
}

// buildDesktopAccount computes the account-level projection. The returned
// error message is safe to show the caller; status is the HTTP code to use.
func (s *Server) buildDesktopAccount(parent context.Context, accountID string) (*desktopAccount, int, error) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	fleet, err := s.mergeFleet(ctx, accountID)
	if err != nil {
		return nil, http.StatusServiceUnavailable, errors.New("fleet data unavailable")
	}
	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		return nil, http.StatusServiceUnavailable, errors.New("earnings unavailable")
	}
	windows, err := s.accountEarningsWindows(accountID)
	if err != nil {
		return nil, http.StatusServiceUnavailable, errors.New("earnings windows unavailable")
	}
	now := time.Now()
	result := &desktopAccount{Linked: true, AccountID: accountID, ObservedAt: now.Unix(),
		LifetimeMicroUSD: strconv.FormatInt(summary.TotalMicroUSD, 10),
		WeekMicroUSD:     strconv.FormatInt(windows.Last7dMicroUSD, 10),
		BalanceMicroUSD:  strconv.FormatInt(s.store.GetWithdrawableBalance(accountID), 10),
		Machines:         make([]desktopMachine, 0, len(fleet)),
	}
	for _, machine := range fleet {
		item := desktopMachine{ID: machine.ID, Name: machine.Hardware.MachineModel, Chip: machine.Hardware.ChipName,
			MemoryGB: machine.Hardware.MemoryGB, Status: machine.Status, Version: machine.Version, Models: []string{},
			seKey: machine.SEPublicKey}
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
	return result, 0, nil
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
