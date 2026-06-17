package store

import (
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
	modelAliases       map[string]*ModelAlias // aliasID → alias

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

	// APNs code-identity attestation reuse cache (W5 Fix 2). Keyed by SE pubkey.
	// In the memory store this is lost on restart (same as the in-memory throttle
	// it backs), but the methods exist so the store seam is uniform and Postgres
	// persists for real once it is the production backend.
	codeAttestations map[string]CodeAttestation

	// Provider log reports
	logReports   []LogReport
	logReportSeq int64

	// Provider sessions (connect→disconnect uptime history)
	providerSessions   []ProviderSession
	providerSessionSeq int64

	// Inference routing telemetry
	inferenceRoutes        []InferenceRouteRecord
	inferenceRouteIndex    map[string]int // request_id/attempt -> index in inferenceRoutes
	inferenceRouteOutcomes map[string]InferenceRouteOutcome

	// Rejected inbound inference requests (4xx/5xx) with servability snapshot.
	inferenceRejections []RejectionRecord
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
		modelAliases:                  make(map[string]*ModelAlias),
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
		codeAttestations:              make(map[string]CodeAttestation),
		inferenceRoutes:               make([]InferenceRouteRecord, 0),
		inferenceRouteIndex:           make(map[string]int),
		inferenceRouteOutcomes:        make(map[string]InferenceRouteOutcome),
		inferenceRejections:           make([]RejectionRecord, 0),
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
	if n := len(s.providerSessions); n > maxEntries {
		s.providerSessions = append([]ProviderSession(nil), s.providerSessions[n-maxEntries:]...)
	}
	if n := len(s.logReports); n > maxEntries {
		s.logReports = append([]LogReport(nil), s.logReports[n-maxEntries:]...)
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
