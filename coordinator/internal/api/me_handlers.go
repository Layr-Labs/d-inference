package api

// Account-scoped provider endpoints used by the console-ui /providers dashboard.
//
// These endpoints answer "what machines does THIS user own, and are they earning?"
// by merging persisted ProviderRecord state (which survives coordinator restarts and
// includes offline machines) with the live registry.Provider snapshot (status,
// heartbeat metrics, backend capacity).
//
// Authentication is Privy-only: these are user-scoped views, not API key
// keyspaces. API keys are rejected by the route middleware.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// myReputation is the wire shape for a provider's reputation snapshot.
type myReputation struct {
	Score              float64 `json:"score"`
	TotalJobs          int     `json:"total_jobs"`
	SuccessfulJobs     int     `json:"successful_jobs"`
	FailedJobs         int     `json:"failed_jobs"`
	TotalUptimeSeconds int64   `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64   `json:"avg_response_time_ms"`
	ChallengesPassed   int     `json:"challenges_passed"`
	ChallengesFailed   int     `json:"challenges_failed"`
}

// myProvider is the per-machine payload for /v1/me/providers.
type myProvider struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`

	// Live operational state. Status is "offline" when the machine is not
	// currently connected, "never_seen" when it has a stored record but has
	// not connected since the coordinator started, otherwise mirrors the
	// registry status (online|serving|untrusted).
	Status        string     `json:"status"`
	Online        bool       `json:"online"`
	LastHeartbeat *time.Time `json:"last_heartbeat,omitempty"`

	// Identity / hardware
	Hardware     protocol.Hardware    `json:"hardware"`
	Models       []protocol.ModelInfo `json:"models"`
	Backend      string               `json:"backend,omitempty"`
	Version      string               `json:"version,omitempty"`
	SerialNumber string               `json:"serial_number,omitempty"`

	// Trust & attestation
	TrustLevel        string   `json:"trust_level"`
	Attested          bool     `json:"attested"`
	MDAVerified       bool     `json:"mda_verified"`
	ACMEVerified      bool     `json:"acme_verified"`
	SEKeyBound        bool     `json:"se_key_bound"`
	SEPublicKey       string   `json:"se_public_key,omitempty"`
	SecureEnclave     bool     `json:"secure_enclave"`
	SIPEnabled        bool     `json:"sip_enabled"`
	SecureBootEnabled bool     `json:"secure_boot_enabled"`
	AuthenticatedRoot bool     `json:"authenticated_root_enabled"`
	SystemVolumeHash  string   `json:"system_volume_hash,omitempty"`
	MDACertChain      []string `json:"mda_cert_chain_b64,omitempty"`
	MDASerial         string   `json:"mda_serial,omitempty"`
	MDAUDID           string   `json:"mda_udid,omitempty"`
	MDAOSVersion      string   `json:"mda_os_version,omitempty"`
	MDASEPVersion     string   `json:"mda_sepos_version,omitempty"`

	// Runtime integrity
	RuntimeVerified bool   `json:"runtime_verified"`
	PythonHash      string `json:"python_hash,omitempty"`
	RuntimeHash     string `json:"runtime_hash,omitempty"`

	// Challenge state
	LastChallengeVerified *time.Time `json:"last_challenge_verified,omitempty"`
	FailedChallenges      int        `json:"failed_challenges"`

	// Live snapshot (only set when the machine is currently connected)
	SystemMetrics   *protocol.SystemMetrics   `json:"system_metrics,omitempty"`
	BackendCapacity *protocol.BackendCapacity `json:"backend_capacity,omitempty"`
	WarmModels      []string                  `json:"warm_models,omitempty"`
	CurrentModel    string                    `json:"current_model,omitempty"`
	PendingRequests int                       `json:"pending_requests"`
	MaxConcurrency  int                       `json:"max_concurrency"`
	PrefillTPS      float64                   `json:"prefill_tps,omitempty"`
	DecodeTPS       float64                   `json:"decode_tps,omitempty"`

	// Reputation
	Reputation myReputation `json:"reputation"`

	// Lifetime stats
	LifetimeRequestsServed  int64 `json:"lifetime_requests_served"`
	LifetimeTokensGenerated int64 `json:"lifetime_tokens_generated"`

	// Per-node earnings (lifetime).
	EarningsTotalMicroUSD int64 `json:"earnings_total_micro_usd"`
	EarningsCount         int64 `json:"earnings_count"`

	// Payout configuration
	WalletAddress string `json:"wallet_address,omitempty"`

	// Timestamps
	RegisteredAt *time.Time `json:"registered_at,omitempty"`
	LastSeen     *time.Time `json:"last_seen,omitempty"`
}

type myProvidersResponse struct {
	Providers             []myProvider `json:"providers"`
	LatestProviderVersion string       `json:"latest_provider_version"`
	MinProviderVersion    string       `json:"min_provider_version"`
	HeartbeatTimeoutSec   int          `json:"heartbeat_timeout_seconds"`
	ChallengeMaxAgeSec    int          `json:"challenge_max_age_seconds"`
}

// myFleetCounts aggregates machine counts by status for the dashboard header.
type myFleetCounts struct {
	Total     int `json:"total"`
	Online    int `json:"online"`          // status==online
	Serving   int `json:"serving"`         // status==serving
	Offline   int `json:"offline"`         // status==offline OR never_seen
	Untrusted int `json:"untrusted"`       // status==untrusted
	Hardware  int `json:"hardware"`        // trust_level==hardware
	NeedsAttn int `json:"needs_attention"` // any of: !runtime_verified, trust!=hardware, untrusted, version below min
}

// mySummaryResponse is the page-level dashboard header at /v1/me/summary.
type mySummaryResponse struct {
	AccountID                   string        `json:"account_id"`
	WalletAddress               string        `json:"wallet_address,omitempty"`
	AvailableBalanceMicroUSD    int64         `json:"available_balance_micro_usd"`
	WithdrawableBalanceMicroUSD int64         `json:"withdrawable_balance_micro_usd"`
	PayoutReady                 bool          `json:"payout_ready"`
	LifetimeMicroUSD            int64         `json:"lifetime_micro_usd"`
	LifetimeJobs                int64         `json:"lifetime_jobs"`
	Last24hMicroUSD             int64         `json:"last_24h_micro_usd"`
	Last24hJobs                 int64         `json:"last_24h_jobs"`
	Last7dMicroUSD              int64         `json:"last_7d_micro_usd"`
	Last7dJobs                  int64         `json:"last_7d_jobs"`
	Counts                      myFleetCounts `json:"counts"`
	LatestProviderVersion       string        `json:"latest_provider_version"`
	MinProviderVersion          string        `json:"min_provider_version"`
}

func (s *Server) handleMySummary(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	accountID := user.AccountID

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	recent, err := s.store.GetAccountEarnings(accountID, 5000)
	if err != nil {
		s.logger.Error("get account earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}
	now := time.Now()
	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)
	var last24Money, last7dMoney int64
	var last24Jobs, last7dJobs int64
	for _, e := range recent {
		if e.CreatedAt.After(cutoff7d) {
			last7dMoney += e.AmountMicroUSD
			last7dJobs++
			if e.CreatedAt.After(cutoff24h) {
				last24Money += e.AmountMicroUSD
				last24Jobs++
			}
		}
	}

	fleet, err := s.mergeFleet(r.Context(), accountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", accountID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list providers"))
		return
	}

	counts := myFleetCounts{}
	for i := range fleet {
		tallyCounts(&counts, &fleet[i], s.minProviderVersion)
	}

	resp := mySummaryResponse{
		AccountID:                   accountID,
		WalletAddress:               user.SolanaWalletAddress,
		AvailableBalanceMicroUSD:    s.store.GetBalance(accountID),
		WithdrawableBalanceMicroUSD: s.store.GetWithdrawableBalance(accountID),
		PayoutReady:                 user.StripeAccountStatus == "ready" || user.SolanaWalletAddress != "",
		LifetimeMicroUSD:            summary.TotalMicroUSD,
		LifetimeJobs:                summary.Count,
		Last24hMicroUSD:             last24Money,
		Last24hJobs:                 last24Jobs,
		Last7dMicroUSD:              last7dMoney,
		Last7dJobs:                  last7dJobs,
		Counts:                      counts,
		LatestProviderVersion:       LatestProviderVersion,
		MinProviderVersion:          s.minProviderVersion,
	}
	writeJSON(w, http.StatusOK, resp)
}

// tallyCounts updates the fleet aggregate based on one machine's merged state.
func tallyCounts(c *myFleetCounts, mp *myProvider, minVersion string) {
	c.Total++
	switch mp.Status {
	case "serving":
		c.Serving++
	case string(registry.StatusOnline):
		c.Online++
	case string(registry.StatusUntrusted):
		c.Untrusted++
	default: // offline, never_seen
		c.Offline++
	}
	if mp.TrustLevel == string(registry.TrustHardware) {
		c.Hardware++
	}
	if needsAttention(mp, minVersion) {
		c.NeedsAttn++
	}
}

// needsAttention is the server-side mirror of the client warning logic. It's
// only used for the summary count, not for individual warning text. The UI
// renders detailed warnings from the per-machine payload.
func needsAttention(mp *myProvider, minVersion string) bool {
	if mp.Status == string(registry.StatusUntrusted) {
		return true
	}
	if mp.Status == "offline" || mp.Status == "never_seen" {
		return true
	}
	if !mp.RuntimeVerified {
		return true
	}
	if mp.TrustLevel != string(registry.TrustHardware) {
		return true
	}
	if mp.FailedChallenges > 0 {
		return true
	}
	if minVersion != "" && mp.Version != "" && semverLess(mp.Version, minVersion) {
		return true
	}
	return false
}

// mergeFleet builds a deduplicated list of myProvider structs for an account
// by combining persisted ProviderRecords (covers offline machines) with the
// live registry snapshot (status, heartbeat metrics, backend capacity).
func (s *Server) mergeFleet(ctx context.Context, accountID string) ([]myProvider, error) {
	records, err := s.store.ListProvidersByAccount(ctx, accountID)
	if err != nil {
		return nil, fmt.Errorf("list providers by account: %w", err)
	}

	live := make(map[string]*registry.Provider)
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		if p.AccountID == accountID {
			live[p.ID] = p
		}
		p.Mu().Unlock()
	})

	deduped := dedupeRecordsByIdentity(records)
	seen := make(map[string]bool, len(deduped))
	out := make([]myProvider, 0, len(deduped))
	for i := range deduped {
		mp := buildMyProvider(&deduped[i], live[deduped[i].ID])
		out = append(out, mp)
		seen[deduped[i].ID] = true
	}
	for id, p := range live {
		if seen[id] {
			continue
		}
		if liveMatchesEmittedIdentity(p, out) {
			continue
		}
		out = append(out, buildMyProvider(nil, p))
	}
	return out, nil
}

func (s *Server) handleMyProviders(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}

	fleet, err := s.mergeFleet(r.Context(), user.AccountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", user.AccountID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list providers"))
		return
	}

	for i := range fleet {
		s.attachStoredReputation(r.Context(), &fleet[i])
		s.attachEarnings(&fleet[i])
	}

	resp := myProvidersResponse{
		Providers:             fleet,
		LatestProviderVersion: LatestProviderVersion,
		MinProviderVersion:    s.minProviderVersion,
		HeartbeatTimeoutSec:   90,
		ChallengeMaxAgeSec:    int((6 * time.Minute).Seconds()),
	}
	writeJSON(w, http.StatusOK, resp)
}

// recordIdentity returns the stable identity for a provider record, preferring
// SerialNumber, then SEPublicKey, then the per-session ID as a last resort.
// Two records with the same identity refer to the same physical machine.
func recordIdentity(rec *store.ProviderRecord) string {
	if rec.SerialNumber != "" {
		return "serial:" + rec.SerialNumber
	}
	if rec.SEPublicKey != "" {
		return "sekey:" + rec.SEPublicKey
	}
	return "id:" + rec.ID
}

// liveIdentity computes the same stable identity for a live registry provider
// using the same serial/SE-key precedence so dedup keys are comparable.
func liveIdentity(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.AttestationResult != nil {
		if p.AttestationResult.SerialNumber != "" {
			return "serial:" + p.AttestationResult.SerialNumber
		}
		if p.AttestationResult.PublicKey != "" {
			return "sekey:" + p.AttestationResult.PublicKey
		}
	}
	return "id:" + p.ID
}

// dedupeRecordsByIdentity collapses ProviderRecord rows that refer to the
// same physical machine, keeping the most recently seen one. The input order
// is the store's LastSeen-DESC order; we honour it for ties.
func dedupeRecordsByIdentity(records []store.ProviderRecord) []store.ProviderRecord {
	if len(records) <= 1 {
		return records
	}
	picked := make(map[string]int, len(records))
	for i := range records {
		key := recordIdentity(&records[i])
		if existing, ok := picked[key]; !ok || records[i].LastSeen.After(records[existing].LastSeen) {
			picked[key] = i
		}
	}
	out := make([]store.ProviderRecord, 0, len(picked))
	for i := range records {
		if picked[recordIdentity(&records[i])] == i {
			out = append(out, records[i])
		}
	}
	return out
}

// liveMatchesEmittedIdentity reports whether the live provider corresponds to
// a machine we already emitted from the persisted-records pass. This avoids
// duplicating a card when a stored record's session ID drifted from the live
// session ID (post-reconnect) but they share a serial/SE key.
func liveMatchesEmittedIdentity(p *registry.Provider, emitted []myProvider) bool {
	id := liveIdentity(p)
	for i := range emitted {
		if emittedIdentity(&emitted[i]) == id {
			return true
		}
	}
	return false
}

func emittedIdentity(mp *myProvider) string {
	if mp.SerialNumber != "" {
		return "serial:" + mp.SerialNumber
	}
	if mp.SEPublicKey != "" {
		return "sekey:" + mp.SEPublicKey
	}
	return "id:" + mp.ID
}

func (s *Server) attachEarnings(mp *myProvider) {
	if mp.AccountID == "" {
		return
	}
	summary, err := s.store.GetAccountEarningsSummary(mp.AccountID)
	if err != nil {
		s.logger.Debug("get account earnings summary failed",
			"provider_id", mp.ID, "account_id", mp.AccountID, "error", err)
		return
	}
	mp.EarningsTotalMicroUSD = summary.TotalMicroUSD
	mp.EarningsCount = summary.Count
}

func (s *Server) attachStoredReputation(ctx context.Context, mp *myProvider) {
	if mp.ID == "" || mp.Reputation.TotalJobs > 0 || mp.Reputation.ChallengesPassed > 0 || mp.Reputation.ChallengesFailed > 0 {
		return
	}
	rep, err := s.store.GetReputation(ctx, mp.ID)
	if err != nil || rep == nil {
		return
	}
	r := registry.NewReputation()
	r.TotalJobs = rep.TotalJobs
	r.SuccessfulJobs = rep.SuccessfulJobs
	r.FailedJobs = rep.FailedJobs
	r.TotalUptime = time.Duration(rep.TotalUptimeSeconds) * time.Second
	r.AvgResponseTime = time.Duration(rep.AvgResponseTimeMs) * time.Millisecond
	r.ChallengesPassed = rep.ChallengesPassed
	r.ChallengesFailed = rep.ChallengesFailed
	mp.Reputation = myReputation{
		Score:              r.Score(),
		TotalJobs:          r.TotalJobs,
		SuccessfulJobs:     r.SuccessfulJobs,
		FailedJobs:         r.FailedJobs,
		TotalUptimeSeconds: int64(r.TotalUptime / time.Second),
		AvgResponseTimeMs:  int64(r.AvgResponseTime / time.Millisecond),
		ChallengesPassed:   r.ChallengesPassed,
		ChallengesFailed:   r.ChallengesFailed,
	}
}

// buildMyProvider merges a persisted record with the live registry snapshot.
// Either may be nil (a never-connected stored record OR a fresh registration
// that hasn't been persisted yet), but at least one must be non-nil.
func buildMyProvider(rec *store.ProviderRecord, live *registry.Provider) myProvider {
	mp := myProvider{Status: "never_seen"}

	// 1. Start from the persisted record (covers offline machines).
	if rec != nil {
		mp.ID = rec.ID
		mp.AccountID = rec.AccountID
		mp.Backend = rec.Backend
		mp.Version = rec.Version
		mp.SerialNumber = rec.SerialNumber
		mp.TrustLevel = rec.TrustLevel
		mp.Attested = rec.Attested
		mp.MDAVerified = rec.MDAVerified
		mp.ACMEVerified = rec.ACMEVerified
		mp.SEPublicKey = rec.SEPublicKey
		mp.RuntimeVerified = rec.RuntimeVerified
		mp.PythonHash = rec.PythonHash
		mp.RuntimeHash = rec.RuntimeHash
		mp.LastChallengeVerified = rec.LastChallengeVerified
		mp.FailedChallenges = rec.FailedChallenges
		mp.LifetimeRequestsServed = rec.LifetimeRequestsServed
		mp.LifetimeTokensGenerated = rec.LifetimeTokensGenerated
		if !rec.RegisteredAt.IsZero() {
			t := rec.RegisteredAt
			mp.RegisteredAt = &t
		}
		if !rec.LastSeen.IsZero() {
			t := rec.LastSeen
			mp.LastSeen = &t
		}
		// Decode embedded JSON blobs.
		if len(rec.Hardware) > 0 {
			_ = json.Unmarshal(rec.Hardware, &mp.Hardware)
		}
		if len(rec.Models) > 0 {
			_ = json.Unmarshal(rec.Models, &mp.Models)
		}
		// AttestationResult holds chip name, SE flags, OS security, system
		// volume hash, etc. Source of truth when we don't have a live snapshot.
		if len(rec.AttestationResult) > 0 {
			var ar attestation.VerificationResult
			if err := json.Unmarshal(rec.AttestationResult, &ar); err == nil {
				if ar.SerialNumber != "" {
					mp.SerialNumber = ar.SerialNumber
				}
				if ar.PublicKey != "" {
					mp.SEPublicKey = ar.PublicKey
				}
				mp.SecureEnclave = ar.SecureEnclaveAvailable
				mp.SIPEnabled = ar.SIPEnabled
				mp.SecureBootEnabled = ar.SecureBootEnabled
				mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
				mp.SystemVolumeHash = ar.SystemVolumeHash
			}
		}
		if len(rec.MDACertChain) > 0 {
			var ders [][]byte
			if err := json.Unmarshal(rec.MDACertChain, &ders); err == nil {
				for _, der := range ders {
					mp.MDACertChain = append(mp.MDACertChain, base64.StdEncoding.EncodeToString(der))
				}
			}
		}
		// Default to offline; will be overwritten below if we have a live snapshot.
		mp.Status = "offline"
	}

	// 2. Overlay the live snapshot if present.
	if live != nil {
		live.Mu().Lock()
		mp.ID = live.ID
		if live.AccountID != "" {
			mp.AccountID = live.AccountID
		}
		mp.Status = string(live.Status)
		mp.Online = live.Status != registry.StatusOffline && live.Status != registry.StatusUntrusted
		hb := live.LastHeartbeat
		if !hb.IsZero() {
			mp.LastHeartbeat = &hb
		}
		// Hardware / models from the live snapshot are authoritative because
		// the provider may have re-registered with new specs.
		mp.Hardware = live.Hardware
		mp.Models = append([]protocol.ModelInfo{}, live.Models...)
		mp.Backend = live.Backend
		mp.Version = live.Version
		mp.TrustLevel = string(live.TrustLevel)
		mp.Attested = live.Attested
		mp.MDAVerified = live.MDAVerified
		mp.ACMEVerified = live.ACMEVerified
		mp.SEKeyBound = live.SEKeyBound
		mp.RuntimeVerified = live.RuntimeVerified
		mp.PythonHash = live.PythonHash
		mp.RuntimeHash = live.RuntimeHash
		if !live.LastChallengeVerified.IsZero() {
			t := live.LastChallengeVerified
			mp.LastChallengeVerified = &t
		}
		mp.FailedChallenges = live.FailedChallenges
		mp.LifetimeRequestsServed = live.Stats.RequestsServed
		mp.LifetimeTokensGenerated = live.Stats.TokensGenerated
		mp.PrefillTPS = live.PrefillTPS
		mp.DecodeTPS = live.DecodeTPS
		mp.WalletAddress = live.WalletAddress

		if live.AttestationResult != nil {
			ar := live.AttestationResult
			if ar.SerialNumber != "" {
				mp.SerialNumber = ar.SerialNumber
			}
			if ar.PublicKey != "" {
				mp.SEPublicKey = ar.PublicKey
			}
			mp.SecureEnclave = ar.SecureEnclaveAvailable
			mp.SIPEnabled = ar.SIPEnabled
			mp.SecureBootEnabled = ar.SecureBootEnabled
			mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
			mp.SystemVolumeHash = ar.SystemVolumeHash
		}
		if len(live.MDACertChain) > 0 {
			mp.MDACertChain = mp.MDACertChain[:0]
			for _, der := range live.MDACertChain {
				mp.MDACertChain = append(mp.MDACertChain, base64.StdEncoding.EncodeToString(der))
			}
		}
		if live.MDAResult != nil {
			mp.MDASerial = live.MDAResult.DeviceSerial
			mp.MDAUDID = live.MDAResult.DeviceUDID
			mp.MDAOSVersion = live.MDAResult.OSVersion
			mp.MDASEPVersion = live.MDAResult.SepOSVersion
		}
		// Live system metrics & backend capacity.
		sm := live.SystemMetrics
		mp.SystemMetrics = &sm
		if live.BackendCapacity != nil {
			cap := *live.BackendCapacity
			mp.BackendCapacity = &cap
		}
		mp.WarmModels = append([]string{}, live.WarmModels...)
		mp.CurrentModel = live.CurrentModel
		// Reputation snapshot.
		mp.Reputation = myReputation{
			Score:              live.Reputation.Score(),
			TotalJobs:          live.Reputation.TotalJobs,
			SuccessfulJobs:     live.Reputation.SuccessfulJobs,
			FailedJobs:         live.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(live.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(live.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   live.Reputation.ChallengesPassed,
			ChallengesFailed:   live.Reputation.ChallengesFailed,
		}
		live.Mu().Unlock()
		// Concurrency limit lookup acquires its own lock.
		mp.PendingRequests = live.PendingCount()
		mp.MaxConcurrency = live.MaxConcurrency()
	}

	return mp
}
