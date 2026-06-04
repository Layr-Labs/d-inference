package store

// In-memory implementation of the Store interface.
//
// MemoryStore keeps all data (API keys, usage records, balances, ledger entries)
// in memory protected by a single RWMutex. This is suitable for development,
// testing, and single-instance deployments where persistence across restarts
// is not needed.
//
// API keys are stored as raw strings (no hashing) for simplicity in the
// in-memory implementation. The PostgresStore uses SHA-256 hashing.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Compile-time check that MemoryStore implements Store.
var _ Store = (*MemoryStore)(nil)

// keySpend tracks per-key spend for cap enforcement. Day buckets (UTC date →
// micro-USD) let us answer daily/weekly/monthly windowed queries cheaply
// (≤31 buckets retained); lifetime is a running total. Buckets older than the
// retention horizon are pruned lazily on write.
type keySpend struct {
	lifetime int64
	days     map[string]int64 // "2006-01-02" (UTC) → micro-USD
}

const keySpendRetentionDays = 40

// MemoryStore manages API keys, usage records, payments, and balances in memory.
type MemoryStore struct {
	mu            sync.RWMutex
	keyRecords    map[string]*APIKey // raw key → record (metadata + limits)
	keysByID      map[string]string  // public key ID → raw key
	keySpend      map[string]*keySpend
	usage         []UsageRecord
	payments      []PaymentRecord
	balances      map[string]int64 // accountID → micro-USD
	withdrawable  map[string]int64 // accountID → withdrawable micro-USD (subset of balance)
	ledgerEntries []LedgerEntry
	ledgerSeq     int64 // auto-increment ID

	// Referral system
	referrersByCode    map[string]*Referrer // code → referrer
	referrersByAccount map[string]*Referrer // accountID → referrer
	referrals          map[string]string    // referredAccountID → referrerCode
	referralCounts     map[string]int       // referrerCode → count of referred accounts

	// Billing sessions
	billingSessions map[string]*BillingSession // sessionID → session

	// Custom pricing
	modelPrices map[string]ModelPrice // "accountID:model" → price

	// Model registry (manifest-backed catalog)
	modelRegistry      map[string]*ModelRegistryEntry
	modelVersions      map[string]*ModelVersion // modelID:version → version
	modelVersionByID   map[int64]*ModelVersion
	modelVersionFiles  map[int64][]ModelVersionFile
	activeModelVersion map[string]int64 // modelID → modelVersionID
	modelVersionSeq    int64
	publishingAPIKeys  map[string]*PublishingAPIKey

	// Users (Privy)
	usersByPrivyID         map[string]*User // privyUserID → user
	usersByAccountID       map[string]*User // accountID → user
	usersByStripeAccountID map[string]*User // stripeAccountID → user (subset of usersByAccountID)

	// Stripe Connect withdrawals
	stripeWithdrawalsByID         map[string]*StripeWithdrawal
	stripeWithdrawalsByTransferID map[string]string   // transferID → withdrawalID
	stripeWithdrawalsByPayoutID   map[string]string   // payoutID → withdrawalID
	stripeWithdrawalsByAccount    map[string][]string // accountID → []withdrawalID, newest last

	// Device authorization
	deviceCodesByCode     map[string]*DeviceCode // deviceCode → DeviceCode
	deviceCodesByUserCode map[string]*DeviceCode // userCode → DeviceCode

	// Provider tokens
	providerTokens map[string]*ProviderToken // tokenHash → ProviderToken

	// Invite codes
	inviteCodes        map[string]*InviteCode        // code → InviteCode
	inviteRedemptions  map[string][]InviteRedemption // code → list of redemptions
	accountRedemptions map[string]map[string]bool    // accountID → set of redeemed codes

	// Provider earnings (per-node tracking)
	providerEarnings    []ProviderEarning
	providerEarningsSeq int64 // auto-increment ID

	// Provider payouts (wallet-based)
	providerPayouts   []ProviderPayout
	providerPayoutSeq int64 // auto-increment ID

	// Releases (provider binary versioning)
	releases map[string]*Release // "version:platform" → Release

	// Provider fleet persistence
	providerRecords    map[string]*ProviderRecord   // providerID → record
	reputationRecords  map[string]*ReputationRecord // providerID → reputation
	serialToProviderID map[string]string            // serialNumber → providerID

	// Provider log reports
	logReports   []LogReport
	logReportSeq int64
}

// NewMemory creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func NewMemory(scfg Config) *MemoryStore {
	s := &MemoryStore{
		keyRecords:                    make(map[string]*APIKey),
		keysByID:                      make(map[string]string),
		keySpend:                      make(map[string]*keySpend),
		usage:                         make([]UsageRecord, 0),
		payments:                      make([]PaymentRecord, 0),
		balances:                      make(map[string]int64),
		withdrawable:                  make(map[string]int64),
		ledgerEntries:                 make([]LedgerEntry, 0),
		referrersByCode:               make(map[string]*Referrer),
		referrersByAccount:            make(map[string]*Referrer),
		referrals:                     make(map[string]string),
		referralCounts:                make(map[string]int),
		billingSessions:               make(map[string]*BillingSession),
		modelPrices:                   make(map[string]ModelPrice),
		modelRegistry:                 make(map[string]*ModelRegistryEntry),
		modelVersions:                 make(map[string]*ModelVersion),
		modelVersionByID:              make(map[int64]*ModelVersion),
		modelVersionFiles:             make(map[int64][]ModelVersionFile),
		activeModelVersion:            make(map[string]int64),
		publishingAPIKeys:             make(map[string]*PublishingAPIKey),
		usersByPrivyID:                make(map[string]*User),
		usersByAccountID:              make(map[string]*User),
		usersByStripeAccountID:        make(map[string]*User),
		stripeWithdrawalsByID:         make(map[string]*StripeWithdrawal),
		stripeWithdrawalsByTransferID: make(map[string]string),
		stripeWithdrawalsByPayoutID:   make(map[string]string),
		stripeWithdrawalsByAccount:    make(map[string][]string),
		deviceCodesByCode:             make(map[string]*DeviceCode),
		deviceCodesByUserCode:         make(map[string]*DeviceCode),
		providerTokens:                make(map[string]*ProviderToken),
		inviteCodes:                   make(map[string]*InviteCode),
		inviteRedemptions:             make(map[string][]InviteRedemption),
		accountRedemptions:            make(map[string]map[string]bool),
		providerEarnings:              make([]ProviderEarning, 0),
		providerPayouts:               make([]ProviderPayout, 0),
		releases:                      make(map[string]*Release),
		providerRecords:               make(map[string]*ProviderRecord),
		reputationRecords:             make(map[string]*ReputationRecord),
		serialToProviderID:            make(map[string]string),
	}
	if scfg.AdminKey != "" {
		s.keyRecords[scfg.AdminKey] = &APIKey{
			ID:         "key_admin_seed",
			Name:       "admin",
			Label:      KeyLabel(scfg.AdminKey),
			LimitReset: KeyResetNone,
			CreatedAt:  time.Now(),
		}
		s.keysByID["key_admin_seed"] = scfg.AdminKey
	}
	return s
}

// DefaultPruneMaxEntries is the default per-slice cap used by Prune.
// At ~1 KB per entry this keeps each slice around ~100 MB, well under the
// coordinator's typical memory budget on a t3.small.
const DefaultPruneMaxEntries = 100_000

// Prune drops the oldest entries from append-only history slices so they
// don't grow unboundedly in long-running processes. Entries are kept in
// append order, so this is equivalent to a bounded ring buffer.
//
// This is a no-op when the PostgresStore is used — Postgres has its own
// retention story (SQL DELETE or partitioning).
//
// maxEntries <= 0 uses DefaultPruneMaxEntries.
func (s *MemoryStore) Prune(maxEntries int) {
	if maxEntries <= 0 {
		maxEntries = DefaultPruneMaxEntries
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if n := len(s.usage); n > maxEntries {
		s.usage = append([]UsageRecord(nil), s.usage[n-maxEntries:]...)
	}
	if n := len(s.payments); n > maxEntries {
		s.payments = append([]PaymentRecord(nil), s.payments[n-maxEntries:]...)
	}
	if n := len(s.ledgerEntries); n > maxEntries {
		s.ledgerEntries = append([]LedgerEntry(nil), s.ledgerEntries[n-maxEntries:]...)
	}
	if n := len(s.providerEarnings); n > maxEntries {
		s.providerEarnings = append([]ProviderEarning(nil), s.providerEarnings[n-maxEntries:]...)
	}
	if n := len(s.providerPayouts); n > maxEntries {
		s.providerPayouts = append([]ProviderPayout(nil), s.providerPayouts[n-maxEntries:]...)
	}

	// Expired device codes can be dropped outright.
	now := time.Now()
	for code, dc := range s.deviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.deviceCodesByCode, code)
			delete(s.deviceCodesByUserCode, dc.UserCode)
		}
	}
}

// CreateKey generates a cryptographically random API key, stores it, and
// returns it. The key is unlinked to any account (legacy bootstrap helper).
func (s *MemoryStore) CreateKey() (string, error) {
	raw, _, err := s.CreateAPIKey("", APIKeyCreate{})
	return raw, err
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *MemoryStore) CreateKeyForAccount(accountID string) (string, error) {
	raw, _, err := s.CreateAPIKey(accountID, APIKeyCreate{})
	return raw, err
}

// CreateAPIKey mints a new API key with optional per-key limits.
func (s *MemoryStore) CreateAPIKey(accountID string, opts APIKeyCreate) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	id, err := GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	rec := &APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          KeyLabel(raw),
		KeyHash:        sha256Hex(raw),
		LimitMicroUSD:  cloneInt64Ptr(opts.LimitMicroUSD),
		LimitReset:     NormalizeResetWindow(opts.LimitReset),
		RPMLimit:       cloneInt64Ptr(opts.RPMLimit),
		ITPMLimit:      cloneInt64Ptr(opts.ITPMLimit),
		OTPMLimit:      cloneInt64Ptr(opts.OTPMLimit),
		AllowedModels:  append([]string(nil), opts.AllowedModels...),
		SelfRouteOnly:  opts.SelfRouteOnly,
		ExpiresAt:      cloneTimePtr(opts.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	s.mu.Lock()
	s.keyRecords[raw] = rec
	s.keysByID[id] = raw
	s.mu.Unlock()
	out := *rec
	return raw, &out, nil
}

// ValidateKey returns true if the given key exists, is active, and is not
// expired. Expiry is enforced here (not just in AuthenticateKey) so callers
// like telemetry attribution don't treat an expired key as a live account.
func (s *MemoryStore) ValidateKey(key string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[key]
	if !ok || rec.Disabled {
		return false
	}
	if rec.ExpiresAt != nil && time.Now().After(*rec.ExpiresAt) {
		return false
	}
	return true
}

// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
func (s *MemoryStore) GetKeyAccount(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if rec, ok := s.keyRecords[key]; ok {
		return rec.OwnerAccountID
	}
	return ""
}

// ValidateKeyFull returns the active status and owner account ID for an
// API key in a single lookup. Returns an error if the key does not exist.
func (s *MemoryStore) ValidateKeyFull(key string) (bool, string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[key]
	if !ok {
		return false, "", fmt.Errorf("key not found")
	}
	return !rec.Disabled, rec.OwnerAccountID, nil
}

// AuthenticateKey resolves a raw key to its active record for request auth.
func (s *MemoryStore) AuthenticateKey(rawKey string) (*APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[rawKey]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	if rec.Disabled {
		return nil, fmt.Errorf("key disabled")
	}
	if rec.ExpiresAt != nil && time.Now().After(*rec.ExpiresAt) {
		return nil, fmt.Errorf("key expired")
	}
	out := cloneAPIKey(rec)
	return out, nil
}

// RevokeKey deactivates a key (soft-disable), matching PostgresStore semantics
// and the Store interface contract ("deactivates a key"). The record is kept so
// it still appears in ListAPIKeys as disabled. Returns true only if the key
// existed AND was active (a second revoke returns false). By-ID deletion
// (RevokeAPIKeyByID) is the hard-delete path.
func (s *MemoryStore) RevokeKey(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.keyRecords[key]
	if !ok || rec.Disabled {
		return false
	}
	rec.Disabled = true
	return true
}

// ListAPIKeys returns all keys owned by an account, newest first.
func (s *MemoryStore) ListAPIKeys(accountID string) ([]APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]APIKey, 0)
	for _, rec := range s.keyRecords {
		if rec.OwnerAccountID != accountID || rec.ID == "" {
			continue
		}
		out = append(out, *cloneAPIKey(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

// GetAPIKeyByID returns a single key by ID, scoped to the owner.
func (s *MemoryStore) GetAPIKeyByID(accountID, id string) (*APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return nil, fmt.Errorf("key not found")
	}
	return cloneAPIKey(rec), nil
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *MemoryStore) UpdateAPIKey(accountID, id string, mutable APIKey) (*APIKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return nil, fmt.Errorf("key not found")
	}
	rec.Name = mutable.Name
	rec.Disabled = mutable.Disabled
	rec.LimitMicroUSD = cloneInt64Ptr(mutable.LimitMicroUSD)
	rec.LimitReset = NormalizeResetWindow(mutable.LimitReset)
	rec.RPMLimit = cloneInt64Ptr(mutable.RPMLimit)
	rec.ITPMLimit = cloneInt64Ptr(mutable.ITPMLimit)
	rec.OTPMLimit = cloneInt64Ptr(mutable.OTPMLimit)
	rec.AllowedModels = append([]string(nil), mutable.AllowedModels...)
	rec.SelfRouteOnly = mutable.SelfRouteOnly
	rec.ExpiresAt = cloneTimePtr(mutable.ExpiresAt)
	return cloneAPIKey(rec), nil
}

// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
func (s *MemoryStore) RevokeAPIKeyByID(accountID, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return fmt.Errorf("key not found")
	}
	delete(s.keyRecords, raw)
	delete(s.keysByID, id)
	return nil
}

// RotateAPIKey atomically replaces a key (see Store interface).
func (s *MemoryStore) RotateAPIKey(accountID, id string) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	newID, err := GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	oldRaw, ok := s.keysByID[id]
	if !ok {
		return "", nil, fmt.Errorf("key not found")
	}
	old, ok := s.keyRecords[oldRaw]
	if !ok || old.OwnerAccountID != accountID {
		return "", nil, fmt.Errorf("key not found")
	}
	rec := &APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          KeyLabel(raw),
		KeyHash:        sha256Hex(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  cloneInt64Ptr(old.LimitMicroUSD),
		LimitReset:     NormalizeResetWindow(old.LimitReset),
		RPMLimit:       cloneInt64Ptr(old.RPMLimit),
		ITPMLimit:      cloneInt64Ptr(old.ITPMLimit),
		OTPMLimit:      cloneInt64Ptr(old.OTPMLimit),
		AllowedModels:  append([]string(nil), old.AllowedModels...),
		SelfRouteOnly:  old.SelfRouteOnly,
		ExpiresAt:      cloneTimePtr(old.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	delete(s.keyRecords, oldRaw)
	delete(s.keysByID, id)
	s.keyRecords[raw] = rec
	s.keysByID[newID] = raw
	return raw, cloneAPIKey(rec), nil
}

// TouchAPIKey records that a key was used at the given time.
func (s *MemoryStore) TouchAPIKey(id string, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return
	}
	if rec, ok := s.keyRecords[raw]; ok {
		t := at.UTC()
		rec.LastUsedAt = &t
	}
}

// KeySpendSince returns total micro-USD charged to a key since `since` (UTC).
func (s *MemoryStore) KeySpendSince(keyID string, since time.Time) int64 {
	if keyID == "" {
		return 0
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	ks, ok := s.keySpend[keyID]
	if !ok {
		return 0
	}
	if since.IsZero() {
		return ks.lifetime
	}
	startDay := since.UTC().Format("2006-01-02")
	var total int64
	for day, amt := range ks.days {
		if day >= startDay {
			total += amt
		}
	}
	return total
}

// RecordUsage appends a usage record to the in-memory log.
func (s *MemoryStore) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Timestamp:        time.Now(),
	})
}

// RecordPayment appends a payment record to the in-memory log.
func (s *MemoryStore) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check for duplicate tx_hash.
	for _, p := range s.payments {
		if p.TxHash == txHash && txHash != "" {
			return fmt.Errorf("duplicate tx_hash: %s", txHash)
		}
	}

	s.payments = append(s.payments, PaymentRecord{
		TxHash:           txHash,
		ConsumerAddress:  consumerAddr,
		ProviderAddress:  providerAddr,
		AmountUSD:        amountUSD,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Memo:             memo,
		CreatedAt:        time.Now(),
	})
	return nil
}

// UsageRecords returns a copy of all usage records.
func (s *MemoryStore) UsageRecords() []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]UsageRecord, len(s.usage))
	copy(out, s.usage)
	for i := range out {
		if out[i].RequestLocation != nil {
			loc := *out[i].RequestLocation
			out[i].RequestLocation = &loc
		}
	}
	return out
}

// UsageRecordsSince returns usage records created at or after the given time.
func (s *MemoryStore) UsageRecordsSince(since time.Time) []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		out := make([]UsageRecord, len(s.usage))
		copy(out, s.usage)
		for i := range out {
			if out[i].RequestLocation != nil {
				loc := *out[i].RequestLocation
				out[i].RequestLocation = &loc
			}
		}
		return out
	}
	var out []UsageRecord
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) {
			continue
		}
		cp := r
		if cp.RequestLocation != nil {
			loc := *cp.RequestLocation
			cp.RequestLocation = &loc
		}
		out = append(out, cp)
	}
	if out == nil {
		return []UsageRecord{}
	}
	return out
}

// UsageCountSince returns the number of usage records created at or after the given time.
func (s *MemoryStore) UsageCountSince(since time.Time) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		return int64(len(s.usage))
	}
	var count int64
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !ts.Before(since) {
			count++
		}
	}
	return count
}

// UsageTotals returns aggregated lifetime totals.
func (s *MemoryStore) UsageTotals() UsageTotals {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t UsageTotals
	for _, r := range s.usage {
		t.Requests++
		t.PromptTokens += int64(r.PromptTokens)
		t.CompletionTokens += int64(r.CompletionTokens)
	}
	return t
}

// UsageTimeSeries buckets usage records by minute since `since`.
func (s *MemoryStore) UsageTimeSeries(since time.Time) []UsageBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()
	buckets := make(map[int64]*UsageBucket)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) {
			continue
		}
		minute := ts.Truncate(time.Minute)
		key := minute.Unix()
		b, ok := buckets[key]
		if !ok {
			b = &UsageBucket{Minute: minute}
			buckets[key] = b
		}
		b.Requests++
		b.PromptTokens += int64(r.PromptTokens)
		b.CompletionTokens += int64(r.CompletionTokens)
	}
	out := make([]UsageBucket, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Minute.Before(out[j].Minute) })
	return out
}

// Leaderboard ranks accounts by the chosen metric across provider_earnings.
func (s *MemoryStore) Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	agg := make(map[string]*LeaderboardRow)
	for _, e := range s.providerEarnings {
		if e.AccountID == "" {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		row, ok := agg[e.AccountID]
		if !ok {
			row = &LeaderboardRow{AccountID: e.AccountID}
			agg[e.AccountID] = row
		}
		row.EarningsMicroUSD += e.AmountMicroUSD
		row.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		row.Jobs++
	}
	rows := make([]LeaderboardRow, 0, len(agg))
	for _, r := range agg {
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		switch metric {
		case LeaderboardTokens:
			return rows[i].Tokens > rows[j].Tokens
		case LeaderboardJobs:
			return rows[i].Jobs > rows[j].Jobs
		default:
			return rows[i].EarningsMicroUSD > rows[j].EarningsMicroUSD
		}
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

// NetworkTotals aggregates metrics across all earnings.
func (s *MemoryStore) NetworkTotals(since time.Time) NetworkTotalsRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t NetworkTotalsRow
	seen := make(map[string]struct{})
	for _, e := range s.providerEarnings {
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		t.EarningsMicroUSD += e.AmountMicroUSD
		t.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		t.Jobs++
		if e.AccountID != "" {
			if _, ok := seen[e.AccountID]; !ok {
				seen[e.AccountID] = struct{}{}
				t.ActiveAccounts++
			}
		}
	}
	return t
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *MemoryStore) UsageByConsumer(consumerKey string) []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []UsageRecord
	for _, u := range s.usage {
		if u.ConsumerKey == consumerKey {
			out = append(out, u)
		}
	}
	return out
}

// RecordUsageWithCost logs a usage event with request ID and cost (in-memory).
func (s *MemoryStore) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation logs a usage event with request location (in-memory).
func (s *MemoryStore) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull logs a usage event with full attribution (incl. API key ID)
// and updates the per-key spend accumulator used for cap enforcement.
func (s *MemoryStore) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	var locCopy *ProviderLocation
	if requestLocation != nil {
		cp := *requestLocation
		locCopy = &cp
	}
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		KeyID:            keyID,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		RequestLocation:  locCopy,
		Timestamp:        now,
		RequestID:        requestID,
		CostMicroUSD:     costMicroUSD,
	})
	if keyID != "" && costMicroUSD > 0 {
		s.addKeySpendLocked(keyID, costMicroUSD, now)
	}
}

// addKeySpendLocked increments the per-key spend accumulator. Caller holds s.mu.
func (s *MemoryStore) addKeySpendLocked(keyID string, amount int64, at time.Time) {
	ks, ok := s.keySpend[keyID]
	if !ok {
		ks = &keySpend{days: make(map[string]int64)}
		s.keySpend[keyID] = ks
	}
	ks.lifetime += amount
	day := at.UTC().Format("2006-01-02")
	ks.days[day] += amount
	// Prune buckets older than the retention horizon to bound memory.
	if len(ks.days) > keySpendRetentionDays {
		cutoff := at.UTC().AddDate(0, 0, -keySpendRetentionDays).Format("2006-01-02")
		for d := range ks.days {
			if d < cutoff {
				delete(ks.days, d)
			}
		}
	}
}

// UsageLocationBuckets returns approximate request-origin aggregates (in-memory).
func (s *MemoryStore) UsageLocationBuckets(since time.Time) []UsageLocationBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type bucketKey struct {
		City        string
		Region      string
		RegionCode  string
		Country     string
		CountryCode string
	}
	type agg struct {
		key                              bucketKey
		latSum, lngSum                   float64
		coordCount                       int
		requests, promptTok, completeTok int64
		providers                        map[string]struct{}
	}
	buckets := make(map[bucketKey]*agg)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !since.IsZero() && ts.Before(since) {
			continue
		}
		if r.RequestLocation == nil {
			continue
		}
		loc := r.RequestLocation
		k := bucketKey{
			City:        loc.City,
			Region:      loc.Region,
			RegionCode:  loc.RegionCode,
			Country:     loc.Country,
			CountryCode: loc.CountryCode,
		}
		b, ok := buckets[k]
		if !ok {
			b = &agg{key: k, providers: make(map[string]struct{})}
			buckets[k] = b
		}
		b.requests++
		b.promptTok += int64(r.PromptTokens)
		b.completeTok += int64(r.CompletionTokens)
		if loc.Latitude != 0 || loc.Longitude != 0 {
			b.latSum += loc.Latitude
			b.lngSum += loc.Longitude
			b.coordCount++
		}
		if r.ProviderID != "" {
			b.providers[r.ProviderID] = struct{}{}
		}
	}
	out := make([]UsageLocationBucket, 0, len(buckets))
	for _, b := range buckets {
		var lat, lng float64
		if b.coordCount > 0 {
			lat = b.latSum / float64(b.coordCount)
			lng = b.lngSum / float64(b.coordCount)
		}
		out = append(out, UsageLocationBucket{
			City:             b.key.City,
			Region:           b.key.Region,
			RegionCode:       b.key.RegionCode,
			Country:          b.key.Country,
			CountryCode:      b.key.CountryCode,
			Latitude:         lat,
			Longitude:        lng,
			Requests:         b.requests,
			PromptTokens:     b.promptTok,
			CompletionTokens: b.completeTok,
			Providers:        len(b.providers),
		})
	}
	return out
}

// UsageFlowBuckets aggregates directional consumer→provider flows in memory.
// providerLocs supplies live provider locations from the registry; the store's
// own providerRecords are used as a fallback for disconnected providers.
func (s *MemoryStore) UsageFlowBuckets(since time.Time, providerLocs map[string]*ProviderLocation) []UsageFlowBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type flowKey struct {
		cCity, cRegion, cCountry string
		pCity, pRegion, pCountry string
	}
	type agg struct {
		b         UsageFlowBucket
		cLatSum   float64
		cLngSum   float64
		cCoordCnt int
		pLatSum   float64
		pLngSum   float64
		pCoordCnt int
	}

	// Resolve provider location: prefer live registry, fall back to stored records.
	resolveProviderLoc := func(providerID string) *ProviderLocation {
		if loc, ok := providerLocs[providerID]; ok && loc != nil {
			return loc
		}
		if rec, ok := s.providerRecords[providerID]; ok {
			return rec.Location
		}
		return nil
	}

	flows := make(map[flowKey]*agg)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !since.IsZero() && ts.Before(since) {
			continue
		}
		if r.RequestLocation == nil {
			continue
		}
		pLoc := resolveProviderLoc(r.ProviderID)
		if pLoc == nil {
			continue
		}
		cLoc := r.RequestLocation
		k := flowKey{
			cCity: cLoc.City, cRegion: cLoc.RegionCode, cCountry: cLoc.CountryCode,
			pCity: pLoc.City, pRegion: pLoc.RegionCode, pCountry: pLoc.CountryCode,
		}
		fa, ok := flows[k]
		if !ok {
			fa = &agg{b: UsageFlowBucket{
				ConsumerCity: cLoc.City, ConsumerRegion: cLoc.Region,
				ConsumerRegionCode: cLoc.RegionCode, ConsumerCountry: cLoc.Country,
				ConsumerCountryCode: cLoc.CountryCode,
				ProviderCity:        pLoc.City, ProviderRegion: pLoc.Region,
				ProviderRegionCode: pLoc.RegionCode, ProviderCountry: pLoc.Country,
				ProviderCountryCode: pLoc.CountryCode,
			}}
			flows[k] = fa
		}
		fa.b.Requests++
		fa.b.PromptTokens += int64(r.PromptTokens)
		fa.b.CompletionTokens += int64(r.CompletionTokens)
		if cLoc.Latitude != 0 || cLoc.Longitude != 0 {
			fa.cLatSum += cLoc.Latitude
			fa.cLngSum += cLoc.Longitude
			fa.cCoordCnt++
		}
		if pLoc.Latitude != 0 || pLoc.Longitude != 0 {
			fa.pLatSum += pLoc.Latitude
			fa.pLngSum += pLoc.Longitude
			fa.pCoordCnt++
		}
	}

	out := make([]UsageFlowBucket, 0, len(flows))
	for _, fa := range flows {
		b := fa.b
		if fa.cCoordCnt > 0 {
			b.ConsumerLatitude = fa.cLatSum / float64(fa.cCoordCnt)
			b.ConsumerLongitude = fa.cLngSum / float64(fa.cCoordCnt)
		}
		if fa.pCoordCnt > 0 {
			b.ProviderLatitude = fa.pLatSum / float64(fa.pCoordCnt)
			b.ProviderLongitude = fa.pLngSum / float64(fa.pCoordCnt)
		}
		out = append(out, b)
	}
	return out
}

// KeyCount returns the number of active API keys.
func (s *MemoryStore) KeyCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, rec := range s.keyRecords {
		if !rec.Disabled {
			n++
		}
	}
	return n
}

// GetBalance returns the current balance in micro-USD for an account.
func (s *MemoryStore) GetBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID]
}

// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
func (s *MemoryStore) GetWithdrawableBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.withdrawable[accountID]
}

// GetBalanceWithWithdrawable returns both balances under a single lock.
func (s *MemoryStore) GetBalanceWithWithdrawable(accountID string) (int64, int64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID], s.withdrawable[accountID]
}

// Credit adds micro-USD to an account and records a ledger entry.
func (s *MemoryStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	return nil
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *MemoryStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	s.withdrawable[accountID] += amountMicroUSD
	return nil
}

// DebitWithdrawable subtracts micro-USD from both the total balance and
// the withdrawable balance. Returns error if withdrawable is insufficient.
func (s *MemoryStore) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.withdrawable[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient withdrawable balance: have %d, need %d micro-USD", s.withdrawable[accountID], amountMicroUSD)
	}
	if s.balances[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient balance: have %d, need %d micro-USD", s.balances[accountID], amountMicroUSD)
	}

	s.balances[accountID] -= amountMicroUSD
	s.withdrawable[accountID] -= amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: -amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
	return nil
}

// Debit subtracts micro-USD from an account. Returns ErrInsufficientBalance
// if the account has insufficient funds.
func (s *MemoryStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.balances[accountID] < amountMicroUSD {
		return ErrInsufficientBalance
	}

	s.balances[accountID] -= amountMicroUSD
	if s.withdrawable[accountID] > s.balances[accountID] {
		s.withdrawable[accountID] = s.balances[accountID]
	}
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: -amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
	return nil
}

// MigrateAccountBalance moves the full balance (and its withdrawable subset)
// from one account ID to another, atomically under the store lock.
func (s *MemoryStore) MigrateAccountBalance(from, to string) (bool, error) {
	if from == "" || to == "" || from == to {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	bal := s.balances[from]
	wdr := s.withdrawable[from]
	if bal == 0 && wdr == 0 {
		return false, nil
	}
	now := time.Now()

	// Debit the source to zero and credit the destination, recording both legs.
	s.balances[from] = 0
	s.withdrawable[from] = 0
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      from,
		Type:           LedgerMigration,
		AmountMicroUSD: -bal,
		BalanceAfter:   0,
		Reference:      "migrate:out",
		CreatedAt:      now,
	})

	s.balances[to] += bal
	s.withdrawable[to] += wdr
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      to,
		Type:           LedgerMigration,
		AmountMicroUSD: bal,
		BalanceAfter:   s.balances[to],
		Reference:      "migrate:in",
		CreatedAt:      now,
	})
	return true, nil
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *MemoryStore) LedgerHistory(accountID string) []LedgerEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var entries []LedgerEntry
	for i := len(s.ledgerEntries) - 1; i >= 0; i-- {
		if s.ledgerEntries[i].AccountID == accountID {
			entries = append(entries, s.ledgerEntries[i])
		}
	}
	if entries == nil {
		return []LedgerEntry{}
	}
	return entries
}

func (s *MemoryStore) creditLocked(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) {
	s.balances[accountID] += amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      createdAt,
	})
}

// --- Referral System ---

// CreateReferrer registers an account as a referrer with the given code.
func (s *MemoryStore) CreateReferrer(accountID, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.referrersByCode[code]; exists {
		return fmt.Errorf("referral code %q already exists", code)
	}
	if _, exists := s.referrersByAccount[accountID]; exists {
		return fmt.Errorf("account %q is already a referrer", accountID)
	}

	ref := &Referrer{
		AccountID: accountID,
		Code:      code,
		CreatedAt: time.Now(),
	}
	s.referrersByCode[code] = ref
	s.referrersByAccount[accountID] = ref
	return nil
}

// GetReferrerByCode returns the referrer for a given referral code.
func (s *MemoryStore) GetReferrerByCode(code string) (*Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("referral code %q not found", code)
	}
	copy := *ref
	return &copy, nil
}

// GetReferrerByAccount returns the referrer record for an account.
func (s *MemoryStore) GetReferrerByAccount(accountID string) (*Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByAccount[accountID]
	if !ok {
		return nil, fmt.Errorf("account %q is not a referrer", accountID)
	}
	copy := *ref
	return &copy, nil
}

// RecordReferral records that referredAccountID was referred by referrerCode.
func (s *MemoryStore) RecordReferral(referrerCode, referredAccountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.referrersByCode[referrerCode]; !exists {
		return fmt.Errorf("referral code %q not found", referrerCode)
	}
	if _, exists := s.referrals[referredAccountID]; exists {
		return errors.New("account already has a referrer")
	}

	s.referrals[referredAccountID] = referrerCode
	s.referralCounts[referrerCode]++
	return nil
}

// GetReferrerForAccount returns the referrer code that referred this account.
func (s *MemoryStore) GetReferrerForAccount(accountID string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	code, ok := s.referrals[accountID]
	if !ok {
		return "", nil
	}
	return code, nil
}

// GetReferralStats returns referral statistics for a code.
func (s *MemoryStore) GetReferralStats(code string) (*ReferralStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("referral code %q not found", code)
	}

	// Sum referral rewards from ledger
	var totalRewards int64
	for _, entry := range s.ledgerEntries {
		if entry.AccountID == ref.AccountID && entry.Type == LedgerReferralReward {
			totalRewards += entry.AmountMicroUSD
		}
	}

	return &ReferralStats{
		Code:                 code,
		TotalReferred:        s.referralCounts[code],
		TotalRewardsMicroUSD: totalRewards,
	}, nil
}

// --- Billing Sessions ---

// CreateBillingSession stores a new billing session.
func (s *MemoryStore) CreateBillingSession(session *BillingSession) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.billingSessions[session.ID]; exists {
		return fmt.Errorf("billing session %q already exists", session.ID)
	}
	copy := *session
	s.billingSessions[session.ID] = &copy
	return nil
}

// GetBillingSession retrieves a billing session by ID.
func (s *MemoryStore) GetBillingSession(sessionID string) (*BillingSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	session, ok := s.billingSessions[sessionID]
	if !ok {
		return nil, fmt.Errorf("billing session %q not found", sessionID)
	}
	copy := *session
	return &copy, nil
}

// CompleteBillingSession marks a session as completed.
func (s *MemoryStore) CompleteBillingSession(sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	session, ok := s.billingSessions[sessionID]
	if !ok {
		return fmt.Errorf("billing session %q not found", sessionID)
	}
	if session.Status == "completed" {
		return fmt.Errorf("billing session %q already completed", sessionID)
	}
	session.Status = "completed"
	now := time.Now()
	session.CompletedAt = &now
	return nil
}

// IsExternalIDProcessed returns true if a completed billing session with this external ID exists.
func (s *MemoryStore) IsExternalIDProcessed(externalID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, session := range s.billingSessions {
		if session.ExternalID == externalID && session.Status == "completed" {
			return true
		}
	}
	return false
}

// --- Custom Pricing ---

func (s *MemoryStore) SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	s.modelPrices[key] = ModelPrice{
		AccountID:   accountID,
		Model:       model,
		InputPrice:  inputPrice,
		OutputPrice: outputPrice,
	}
	return nil
}

func (s *MemoryStore) GetModelPrice(accountID, model string) (int64, int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	mp, ok := s.modelPrices[accountID+":"+model]
	if !ok {
		return 0, 0, false
	}
	return mp.InputPrice, mp.OutputPrice, true
}

func (s *MemoryStore) ListModelPrices(accountID string) []ModelPrice {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var prices []ModelPrice
	for _, mp := range s.modelPrices {
		if mp.AccountID == accountID {
			prices = append(prices, mp)
		}
	}
	return prices
}

func (s *MemoryStore) DeleteModelPrice(accountID, model string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	if _, ok := s.modelPrices[key]; !ok {
		return fmt.Errorf("no custom price for model %q", model)
	}
	delete(s.modelPrices, key)
	return nil
}

// --- Model Registry ---

func (s *MemoryStore) UpsertModelRegistryEntry(entry *ModelRegistryEntry) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := cloneModelRegistryEntry(entry)
	if existing, ok := s.modelRegistry[entry.ID]; ok && !existing.CreatedAt.IsZero() {
		cp.CreatedAt = existing.CreatedAt
		cp.Status = existing.Status
	} else if cp.CreatedAt.IsZero() {
		cp.CreatedAt = now
	}
	if cp.UpdatedAt.IsZero() {
		cp.UpdatedAt = now
	}
	s.modelRegistry[entry.ID] = &cp
	return nil
}

func (s *MemoryStore) SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	entryCopy := cloneModelRegistryEntry(entry)
	if existing, ok := s.modelRegistry[entry.ID]; ok && !existing.CreatedAt.IsZero() {
		entryCopy.CreatedAt = existing.CreatedAt
		entryCopy.Status = existing.Status
	} else if entryCopy.CreatedAt.IsZero() {
		entryCopy.CreatedAt = now
	}
	if entryCopy.UpdatedAt.IsZero() {
		entryCopy.UpdatedAt = now
	}
	s.modelRegistry[entry.ID] = &entryCopy

	key := modelVersionKey(version.ModelID, version.Version)
	versionCopy := cloneModelVersion(version)
	if existing, ok := s.modelVersions[key]; ok {
		versionCopy.ID = existing.ID
		if versionCopy.UploadedAt.IsZero() {
			versionCopy.UploadedAt = existing.UploadedAt
		}
		versionCopy.PromotedAt = cloneTimePtr(existing.PromotedAt)
	} else {
		s.modelVersionSeq++
		versionCopy.ID = s.modelVersionSeq
	}
	if versionCopy.UploadedAt.IsZero() {
		versionCopy.UploadedAt = now
	}
	s.modelVersions[key] = &versionCopy
	s.modelVersionByID[versionCopy.ID] = &versionCopy
	version.ID = versionCopy.ID
	version.UploadedAt = versionCopy.UploadedAt

	fileCopies := make([]ModelVersionFile, len(files))
	for i := range files {
		fileCopies[i] = files[i]
		fileCopies[i].ID = int64(i + 1)
		fileCopies[i].ModelVersionID = versionCopy.ID
	}
	s.modelVersionFiles[versionCopy.ID] = fileCopies
	return nil
}

func (s *MemoryStore) PromoteModelVersion(modelID, version string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	v, ok := s.modelVersions[modelVersionKey(modelID, version)]
	if !ok {
		return fmt.Errorf("model version %q %q not found", modelID, version)
	}
	now := time.Now()
	v.PromotedAt = &now
	s.activeModelVersion[modelID] = v.ID
	return nil
}

func (s *MemoryStore) SetModelStatus(modelID, status string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	entry, ok := s.modelRegistry[modelID]
	if !ok {
		return fmt.Errorf("model %q not found", modelID)
	}
	entry.Status = status
	entry.UpdatedAt = time.Now()
	return nil
}

func (s *MemoryStore) ListActiveModelRegistry() []ModelRegistryRecord {
	records, _ := s.ListActiveModelRegistryWithError()
	return records
}

func (s *MemoryStore) ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ModelRegistryRecord, 0, len(s.activeModelVersion))
	for modelID := range s.activeModelVersion {
		if rec := s.modelRegistryRecordLocked(modelID); rec != nil {
			records = append(records, *rec)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].MinRAMGB == records[j].MinRAMGB {
			return records[i].ID < records[j].ID
		}
		return records[i].MinRAMGB < records[j].MinRAMGB
	})
	return records, nil
}

func (s *MemoryStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rec := s.modelRegistryRecordLocked(modelID)
	if rec == nil {
		return nil, fmt.Errorf("model %q not found", modelID)
	}
	return rec, nil
}

func (s *MemoryStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	rec, err := s.GetModelRegistryRecord(modelID)
	if err != nil {
		return nil, err
	}
	return manifestFromRecord(rec), nil
}

func (s *MemoryStore) UpsertPublishingAPIKey(key *PublishingAPIKey) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *key
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	cp.LastUsedAt = cloneTimePtr(key.LastUsedAt)
	s.publishingAPIKeys[key.ID] = &cp
	return nil
}

func (s *MemoryStore) FindPublishingAPIKeys() []PublishingAPIKey {
	keys, _ := s.FindPublishingAPIKeysWithError()
	return keys
}

func (s *MemoryStore) FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	keys := make([]PublishingAPIKey, 0, len(s.publishingAPIKeys))
	for _, key := range s.publishingAPIKeys {
		cp := *key
		cp.LastUsedAt = cloneTimePtr(key.LastUsedAt)
		keys = append(keys, cp)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].CreatedAt.Before(keys[j].CreatedAt) })
	return keys, nil
}

func (s *MemoryStore) MarkPublishingAPIKeyUsed(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, ok := s.publishingAPIKeys[id]
	if !ok {
		return fmt.Errorf("publishing API key %q not found", id)
	}
	now := time.Now()
	key.LastUsedAt = &now
	return nil
}

func (s *MemoryStore) modelRegistryRecordLocked(modelID string) *ModelRegistryRecord {
	entry, ok := s.modelRegistry[modelID]
	if !ok || (entry.Status != "active" && entry.Status != "beta") {
		return nil
	}
	versionID, ok := s.activeModelVersion[modelID]
	if !ok {
		return nil
	}
	version, ok := s.modelVersionByID[versionID]
	if !ok || version.Status != "ready" {
		return nil
	}
	entryCopy := cloneModelRegistryEntry(entry)
	versionCopy := cloneModelVersion(version)
	files := append([]ModelVersionFile(nil), s.modelVersionFiles[versionID]...)
	return &ModelRegistryRecord{ModelRegistryEntry: entryCopy, ActiveVersion: &versionCopy, Files: files}
}

func modelVersionKey(modelID, version string) string {
	return modelID + "\x00" + version
}

func cloneModelRegistryEntry(entry *ModelRegistryEntry) ModelRegistryEntry {
	if entry == nil {
		return ModelRegistryEntry{}
	}
	cp := *entry
	cp.Capabilities = append([]string(nil), entry.Capabilities...)
	cp.RuntimeParameters = cloneMetadata(entry.RuntimeParameters)
	cp.Metadata = cloneMetadata(entry.Metadata)
	return cp
}

func cloneModelVersion(version *ModelVersion) ModelVersion {
	if version == nil {
		return ModelVersion{}
	}
	cp := *version
	cp.PromotedAt = cloneTimePtr(version.PromotedAt)
	cp.Metadata = cloneMetadata(version.Metadata)
	return cp
}

func cloneMetadata(metadata map[string]any) map[string]any {
	if metadata == nil {
		return map[string]any{}
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		return map[string]any{}
	}
	out := map[string]any{}
	if err := json.Unmarshal(data, &out); err != nil {
		return map[string]any{}
	}
	return out
}

func cloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	cp := *t
	return &cp
}

func cloneInt64Ptr(v *int64) *int64 {
	if v == nil {
		return nil
	}
	cp := *v
	return &cp
}

// cloneAPIKey returns a deep copy of a key record so callers can never mutate
// the store's internal state through the returned pointer.
func cloneAPIKey(rec *APIKey) *APIKey {
	if rec == nil {
		return nil
	}
	cp := *rec
	cp.LimitMicroUSD = cloneInt64Ptr(rec.LimitMicroUSD)
	cp.RPMLimit = cloneInt64Ptr(rec.RPMLimit)
	cp.ITPMLimit = cloneInt64Ptr(rec.ITPMLimit)
	cp.OTPMLimit = cloneInt64Ptr(rec.OTPMLimit)
	cp.ExpiresAt = cloneTimePtr(rec.ExpiresAt)
	cp.LastUsedAt = cloneTimePtr(rec.LastUsedAt)
	cp.AllowedModels = append([]string(nil), rec.AllowedModels...)
	return &cp
}

func manifestFromRecord(rec *ModelRegistryRecord) *ModelManifest {
	if rec == nil || rec.ActiveVersion == nil {
		return nil
	}
	files := make([]ManifestFile, len(rec.Files))
	for i, f := range rec.Files {
		files[i] = ManifestFile{Path: f.Path, SizeBytes: f.SizeBytes, SHA256: f.SHA256, Role: f.Role}
	}
	return &ModelManifest{
		SchemaVersion:   1,
		ModelID:         rec.ID,
		Version:         rec.ActiveVersion.Version,
		R2Prefix:        rec.ActiveVersion.R2Prefix,
		AggregateSHA256: rec.ActiveVersion.AggregateSHA256,
		TotalSizeBytes:  rec.ActiveVersion.TotalSizeBytes,
		FileCount:       rec.ActiveVersion.FileCount,
		Files:           files,
		CreatedAt:       rec.ActiveVersion.UploadedAt,
	}
}

// --- Users (Privy) ---

// CreateUser creates a new user record linked to a Privy identity.
func (s *MemoryStore) CreateUser(user *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.usersByPrivyID[user.PrivyUserID]; exists {
		return fmt.Errorf("user with Privy ID %q already exists", user.PrivyUserID)
	}
	if _, exists := s.usersByAccountID[user.AccountID]; exists {
		return fmt.Errorf("user with account ID %q already exists", user.AccountID)
	}

	copy := *user
	copy.CreatedAt = time.Now()
	s.usersByPrivyID[user.PrivyUserID] = &copy
	s.usersByAccountID[user.AccountID] = &copy
	return nil
}

// GetUserByPrivyID returns the user for a Privy DID.
func (s *MemoryStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByPrivyID[privyUserID]
	if !ok {
		return nil, fmt.Errorf("user with Privy ID %q not found", privyUserID)
	}
	copy := *u
	return &copy, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *MemoryStore) GetUserByAccountID(accountID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return nil, fmt.Errorf("user with account ID %q not found", accountID)
	}
	copy := *u
	return &copy, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
func (s *MemoryStore) SetUserStripeAccount(accountID, stripeAccountID, status, destinationType, destinationLast4 string, instantEligible bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}

	// Maintain the by-stripe-account index. A user may switch accounts (e.g.
	// after a manual reset) so we drop the old mapping if it was different.
	if u.StripeAccountID != "" && u.StripeAccountID != stripeAccountID {
		delete(s.usersByStripeAccountID, u.StripeAccountID)
	}

	u.StripeAccountID = stripeAccountID
	u.StripeAccountStatus = status
	u.StripeDestinationType = destinationType
	u.StripeDestinationLast4 = destinationLast4
	u.StripeInstantEligible = instantEligible

	if stripeAccountID != "" {
		s.usersByStripeAccountID[stripeAccountID] = u
	}
	return nil
}

// GetUserByStripeAccount finds a user by their Stripe connected account ID.
func (s *MemoryStore) GetUserByStripeAccount(stripeAccountID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByStripeAccountID[stripeAccountID]
	if !ok {
		return nil, fmt.Errorf("user with Stripe account %q not found", stripeAccountID)
	}
	copy := *u
	return &copy, nil
}

// GetUserByEmail returns the user for an email address.
func (s *MemoryStore) GetUserByEmail(email string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	lower := strings.ToLower(email)
	for _, u := range s.usersByAccountID {
		if strings.ToLower(u.Email) == lower {
			copy := *u
			return &copy, nil
		}
	}
	return nil, fmt.Errorf("user with email %q not found", email)
}

// SetUserRole sets the account role on a user record.
func (s *MemoryStore) SetUserRole(accountID, role string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	u.Role = role
	return nil
}

// SetUserPlatformFeePercent sets (or clears, when nil) the per-account
// platform fee override. A fresh pointer is allocated so stored state is never
// aliased by the caller.
func (s *MemoryStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	if feePercent == nil {
		u.PlatformFeePercent = nil
	} else {
		v := *feePercent
		u.PlatformFeePercent = &v
	}
	return nil
}

// --- Stripe Withdrawals ---

func (s *MemoryStore) CreateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.stripeWithdrawalsByID[w.ID]; exists {
		return fmt.Errorf("stripe withdrawal %q already exists", w.ID)
	}
	cp := *w
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	if cp.UpdatedAt.IsZero() {
		cp.UpdatedAt = cp.CreatedAt
	}
	s.stripeWithdrawalsByID[cp.ID] = &cp
	if cp.TransferID != "" {
		s.stripeWithdrawalsByTransferID[cp.TransferID] = cp.ID
	}
	if cp.PayoutID != "" {
		s.stripeWithdrawalsByPayoutID[cp.PayoutID] = cp.ID
	}
	s.stripeWithdrawalsByAccount[cp.AccountID] = append(s.stripeWithdrawalsByAccount[cp.AccountID], cp.ID)
	return nil
}

func (s *MemoryStore) GetStripeWithdrawal(id string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal %q not found", id)
	}
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByPayoutID[payoutID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with payout %q not found", payoutID)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByTransferID[transferID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with transfer %q not found", transferID)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) UpdateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, ok := s.stripeWithdrawalsByID[w.ID]
	if !ok {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	// Re-index transfer/payout IDs if they changed.
	if existing.TransferID != w.TransferID {
		if existing.TransferID != "" {
			delete(s.stripeWithdrawalsByTransferID, existing.TransferID)
		}
		if w.TransferID != "" {
			s.stripeWithdrawalsByTransferID[w.TransferID] = w.ID
		}
	}
	if existing.PayoutID != w.PayoutID {
		if existing.PayoutID != "" {
			delete(s.stripeWithdrawalsByPayoutID, existing.PayoutID)
		}
		if w.PayoutID != "" {
			s.stripeWithdrawalsByPayoutID[w.PayoutID] = w.ID
		}
	}
	cp := *w
	cp.UpdatedAt = time.Now()
	s.stripeWithdrawalsByID[w.ID] = &cp
	return nil
}

func (s *MemoryStore) ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := s.stripeWithdrawalsByAccount[accountID]
	if len(ids) == 0 {
		return []StripeWithdrawal{}, nil
	}
	out := make([]StripeWithdrawal, 0, len(ids))
	for i := len(ids) - 1; i >= 0; i-- {
		w, ok := s.stripeWithdrawalsByID[ids[i]]
		if !ok {
			continue
		}
		out = append(out, *w)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, nil
}

// --- Device Authorization ---

func (s *MemoryStore) CreateDeviceCode(dc *DeviceCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.deviceCodesByUserCode[dc.UserCode]; exists {
		return fmt.Errorf("user code %q already exists", dc.UserCode)
	}
	copy := *dc
	s.deviceCodesByCode[dc.DeviceCode] = &copy
	s.deviceCodesByUserCode[dc.UserCode] = &copy
	return nil
}

func (s *MemoryStore) GetDeviceCode(deviceCode string) (*DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.deviceCodesByCode[deviceCode]
	if !ok {
		return nil, errors.New("device code not found")
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.deviceCodesByUserCode[userCode]
	if !ok {
		return nil, fmt.Errorf("user code %q not found", userCode)
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) ApproveDeviceCode(deviceCode, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	dc, ok := s.deviceCodesByCode[deviceCode]
	if !ok {
		return errors.New("device code not found")
	}
	if dc.Status != "pending" {
		return fmt.Errorf("device code is %s, not pending", dc.Status)
	}
	if time.Now().After(dc.ExpiresAt) {
		dc.Status = "expired"
		return errors.New("device code has expired")
	}
	dc.Status = "approved"
	dc.AccountID = accountID
	return nil
}

func (s *MemoryStore) DeleteExpiredDeviceCodes() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	for code, dc := range s.deviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.deviceCodesByCode, code)
			delete(s.deviceCodesByUserCode, dc.UserCode)
		}
	}
	return nil
}

// --- Provider Tokens ---

func (s *MemoryStore) CreateProviderToken(pt *ProviderToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.providerTokens[pt.TokenHash]; exists {
		return errors.New("provider token already exists")
	}
	copy := *pt
	s.providerTokens[pt.TokenHash] = &copy
	return nil
}

func (s *MemoryStore) GetProviderToken(token string) (*ProviderToken, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	h := sha256Hex(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return nil, errors.New("provider token not found")
	}
	if !pt.Active {
		return nil, errors.New("provider token is revoked")
	}
	copy := *pt
	return &copy, nil
}

func (s *MemoryStore) RevokeProviderToken(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	h := sha256Hex(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return errors.New("provider token not found")
	}
	pt.Active = false
	return nil
}

// --- Invite Codes ---

func (s *MemoryStore) CreateInviteCode(code *InviteCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.inviteCodes[code.Code]; exists {
		return fmt.Errorf("invite code %q already exists", code.Code)
	}
	cp := *code
	s.inviteCodes[code.Code] = &cp
	return nil
}

func (s *MemoryStore) GetInviteCode(code string) (*InviteCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return nil, fmt.Errorf("invite code %q not found", code)
	}
	cp := *ic
	return &cp, nil
}

func (s *MemoryStore) ListInviteCodes() []InviteCode {
	s.mu.RLock()
	defer s.mu.RUnlock()

	codes := make([]InviteCode, 0, len(s.inviteCodes))
	for _, ic := range s.inviteCodes {
		codes = append(codes, *ic)
	}
	return codes
}

func (s *MemoryStore) DeactivateInviteCode(code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return fmt.Errorf("invite code %q not found", code)
	}
	ic.Active = false
	return nil
}

func (s *MemoryStore) RedeemInviteCode(code string, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return fmt.Errorf("invite code %q not found", code)
	}
	if !ic.Active {
		return fmt.Errorf("invite code %q is inactive", code)
	}
	if ic.ExpiresAt != nil && time.Now().After(*ic.ExpiresAt) {
		return fmt.Errorf("invite code %q has expired", code)
	}
	if ic.MaxUses > 0 && ic.UsedCount >= ic.MaxUses {
		return fmt.Errorf("invite code %q has reached max uses", code)
	}
	if acctCodes, ok := s.accountRedemptions[accountID]; ok && acctCodes[code] {
		return fmt.Errorf("account has already redeemed code %q", code)
	}

	ic.UsedCount++
	s.inviteRedemptions[code] = append(s.inviteRedemptions[code], InviteRedemption{
		Code:      code,
		AccountID: accountID,
		CreatedAt: time.Now(),
	})
	if s.accountRedemptions[accountID] == nil {
		s.accountRedemptions[accountID] = make(map[string]bool)
	}
	s.accountRedemptions[accountID][code] = true
	return nil
}

func (s *MemoryStore) HasRedeemedInviteCode(code, accountID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if acctCodes, ok := s.accountRedemptions[accountID]; ok {
		return acctCodes[code]
	}
	return false
}

// --- Provider Earnings ---

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *MemoryStore) RecordProviderEarning(earning *ProviderEarning) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.providerEarningsSeq++
	cp := *earning
	cp.ID = s.providerEarningsSeq
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
func (s *MemoryStore) GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].ProviderKey == providerKey {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *MemoryStore) GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].AccountID == accountID {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
func (s *MemoryStore) GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.ProviderKey != providerKey {
			continue
		}
		summary.Count++
		summary.TotalMicroUSD += earning.AmountMicroUSD
		summary.PromptTokens += int64(earning.PromptTokens)
		summary.CompletionTokens += int64(earning.CompletionTokens)
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
func (s *MemoryStore) GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.AccountID != accountID {
			continue
		}
		summary.Count++
		summary.TotalMicroUSD += earning.AmountMicroUSD
		summary.PromptTokens += int64(earning.PromptTokens)
		summary.CompletionTokens += int64(earning.CompletionTokens)
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *MemoryStore) RecordProviderPayout(payout *ProviderPayout) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.providerPayoutSeq++
	cp := *payout
	cp.ID = s.providerPayoutSeq
	if cp.Timestamp.IsZero() {
		cp.Timestamp = time.Now()
	}
	s.providerPayouts = append(s.providerPayouts, cp)
	return nil
}

// ListProviderPayouts returns all provider payout records in creation order.
func (s *MemoryStore) ListProviderPayouts() ([]ProviderPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.providerPayouts) == 0 {
		return []ProviderPayout{}, nil
	}

	out := make([]ProviderPayout, len(s.providerPayouts))
	copy(out, s.providerPayouts)
	return out, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *MemoryStore) SettleProviderPayout(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.providerPayouts {
		if s.providerPayouts[i].ID != id {
			continue
		}
		if s.providerPayouts[i].Settled {
			return fmt.Errorf("provider payout %d already settled", id)
		}
		s.providerPayouts[i].Settled = true
		return nil
	}

	return fmt.Errorf("provider payout %d not found", id)
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
func (s *MemoryStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *earning
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}

	s.creditLocked(cp.AccountID, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.CreatedAt)
	s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
	s.providerEarningsSeq++
	cp.ID = s.providerEarningsSeq
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *MemoryStore) CreditProviderWallet(payout *ProviderPayout) error {
	if payout == nil {
		return errors.New("provider payout is required")
	}
	if payout.ProviderAddress == "" {
		return errors.New("provider payout address is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *payout
	if cp.Timestamp.IsZero() {
		cp.Timestamp = time.Now()
	}

	s.creditLocked(cp.ProviderAddress, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.Timestamp)
	s.withdrawable[cp.ProviderAddress] += cp.AmountMicroUSD
	s.providerPayoutSeq++
	cp.ID = s.providerPayoutSeq
	s.providerPayouts = append(s.providerPayouts, cp)
	return nil
}

// --- Releases ---

func releaseKey(version, platform string) string {
	return version + ":" + platform
}

func (s *MemoryStore) SetRelease(release *Release) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if release.Version == "" || release.Platform == "" {
		return errors.New("version and platform are required")
	}
	r := *release
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now()
	}
	r.Active = true
	s.releases[releaseKey(r.Version, r.Platform)] = &r
	return nil
}

func (s *MemoryStore) ListReleases() []Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	releases := make([]Release, 0, len(s.releases))
	for _, r := range s.releases {
		releases = append(releases, *r)
	}
	sort.Slice(releases, func(i, j int) bool {
		return releases[i].CreatedAt.After(releases[j].CreatedAt)
	})
	return releases
}

func (s *MemoryStore) GetLatestRelease(platform string) *Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest *Release
	for _, r := range s.releases {
		if r.Platform != platform || !r.Active {
			continue
		}
		if latest == nil ||
			releaseVersionGreater(r.Version, latest.Version) ||
			(r.Version == latest.Version && r.CreatedAt.After(latest.CreatedAt)) {
			latest = r
		}
	}
	if latest == nil {
		return nil
	}
	copy := *latest
	return &copy
}

func (s *MemoryStore) DeleteRelease(version, platform string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := releaseKey(version, platform)
	r, ok := s.releases[key]
	if !ok {
		return fmt.Errorf("release %s/%s not found", version, platform)
	}
	r.Active = false
	return nil
}

// --- Provider Fleet Persistence ---

func (s *MemoryStore) UpsertProvider(_ context.Context, p ProviderRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update serial index
	if p.SerialNumber != "" {
		// Remove old serial mapping if exists
		if old, ok := s.providerRecords[p.ID]; ok && old.SerialNumber != "" && old.SerialNumber != p.SerialNumber {
			delete(s.serialToProviderID, old.SerialNumber)
		}
		s.serialToProviderID[p.SerialNumber] = p.ID
	}

	cp := p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	s.providerRecords[p.ID] = &cp
	return nil
}

func (s *MemoryStore) GetProviderRecord(_ context.Context, id string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) GetProviderBySerial(_ context.Context, serial string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	id, ok := s.serialToProviderID[serial]
	if !ok {
		return nil, fmt.Errorf("provider with serial %q not found", serial)
	}
	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found (stale serial index)", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) ListProviderRecords(_ context.Context) ([]ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0, len(s.providerRecords))
	for _, p := range s.providerRecords {
		cp := *p
		if p.Location != nil {
			loc := *p.Location
			cp.Location = &loc
		}
		records = append(records, cp)
	}
	return records, nil
}

func (s *MemoryStore) ListProvidersByAccount(_ context.Context, accountID string) ([]ProviderRecord, error) {
	if accountID == "" {
		return []ProviderRecord{}, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0)
	for _, p := range s.providerRecords {
		if p.AccountID == accountID {
			cp := *p
			if p.Location != nil {
				loc := *p.Location
				cp.Location = &loc
			}
			records = append(records, cp)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].LastSeen.After(records[j].LastSeen)
	})
	return records, nil
}

func (s *MemoryStore) UpdateProviderLastSeen(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastSeen = time.Now()
	return nil
}

func (s *MemoryStore) UpdateProviderTrust(_ context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.TrustLevel = trustLevel
	p.Attested = attested
	p.AttestationResult = attestationResult
	return nil
}

func (s *MemoryStore) UpdateProviderChallenge(_ context.Context, id string, lastVerified time.Time, failedCount int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastChallengeVerified = &lastVerified
	p.FailedChallenges = failedCount
	return nil
}

func (s *MemoryStore) UpdateProviderRuntime(_ context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.RuntimeVerified = verified
	p.PythonHash = pythonHash
	p.RuntimeHash = runtimeHash
	return nil
}

// --- Provider Reputation Persistence ---

func (s *MemoryStore) UpsertReputation(_ context.Context, providerID string, rep ReputationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := rep
	s.reputationRecords[providerID] = &cp
	return nil
}

func (s *MemoryStore) GetReputation(_ context.Context, providerID string) (*ReputationRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rep, ok := s.reputationRecords[providerID]
	if !ok {
		return nil, fmt.Errorf("reputation for provider %q not found", providerID)
	}
	cp := *rep
	return &cp, nil
}

// --- Provider Log Reports ---

func (s *MemoryStore) StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error {
	const maxSize = 10 << 20 // 10 MB
	if len(logData) > maxSize {
		logData = logData[:maxSize]
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.logReportSeq++
	cp := make([]byte, len(logData))
	copy(cp, logData)
	s.logReports = append(s.logReports, LogReport{
		ID:           s.logReportSeq,
		SerialNumber: serialNumber,
		ProviderID:   providerID,
		AccountID:    accountID,
		LogSizeBytes: int64(len(cp)),
		LogData:      cp,
		CreatedAt:    time.Now(),
	})
	return nil
}

func (s *MemoryStore) GetLogReports(serialNumber string, limit int) ([]LogReport, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	var reports []LogReport
	for i := len(s.logReports) - 1; i >= 0; i-- {
		r := s.logReports[i]
		if r.SerialNumber != serialNumber {
			continue
		}
		// Return without log data for list queries.
		reports = append(reports, LogReport{
			ID:           r.ID,
			SerialNumber: r.SerialNumber,
			ProviderID:   r.ProviderID,
			AccountID:    r.AccountID,
			LogSizeBytes: r.LogSizeBytes,
			CreatedAt:    r.CreatedAt,
		})
		if len(reports) >= limit {
			break
		}
	}
	if reports == nil {
		return []LogReport{}, nil
	}
	return reports, nil
}

func (s *MemoryStore) GetLogReport(id int64) (*LogReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.logReports {
		if s.logReports[i].ID == id {
			r := s.logReports[i]
			cp := LogReport{
				ID:           r.ID,
				SerialNumber: r.SerialNumber,
				ProviderID:   r.ProviderID,
				AccountID:    r.AccountID,
				LogSizeBytes: r.LogSizeBytes,
				CreatedAt:    r.CreatedAt,
				LogData:      make([]byte, len(r.LogData)),
			}
			copy(cp.LogData, r.LogData)
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("log report %d not found", id)
}

// sha256Hex returns the hex-encoded SHA-256 digest of s.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
