package memory

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// Store implements the shared persistence contract.
var _ contracts.Store = (*Store)(nil)

// keySpend tracks per-key spend for cap enforcement. Day buckets (UTC date →
// micro-USD) let us answer daily/weekly/monthly windowed queries cheaply
// (≤31 buckets retained); lifetime is a running total. Buckets older than the
// retention horizon are pruned lazily on write.
type keySpend struct {
	lifetime int64
	days     map[string]int64 // "2006-01-02" (UTC) → micro-USD
}

const keySpendRetentionDays = 40

// Store manages API keys, usage records, payments, and balances in memory.
type Store struct {
	mu            sync.RWMutex
	keyRecords    map[string]*contracts.APIKey // raw key → record (metadata + limits)
	keysByID      map[string]string            // public key ID → raw key
	keySpend      map[string]*keySpend
	usage         []contracts.UsageRecord
	payments      []contracts.PaymentRecord
	balances      map[string]int64 // accountID → micro-USD
	withdrawable  map[string]int64 // accountID → withdrawable micro-USD (subset of balance)
	ledgerEntries []contracts.LedgerEntry
	ledgerSeq     int64 // auto-increment ID

	// Referral system
	referrersByCode    map[string]*contracts.Referrer // code → referrer
	referrersByAccount map[string]*contracts.Referrer // accountID → referrer
	referrals          map[string]string              // referredAccountID → referrerCode
	referralCounts     map[string]int                 // referrerCode → count of referred accounts

	// Billing sessions
	billingSessions map[string]*contracts.BillingSession // sessionID → session

	// Custom pricing
	modelPrices map[string]contracts.ModelPrice // "accountID:model" → price

	// Model registry (manifest-backed catalog)
	modelRegistry      map[string]*contracts.ModelRegistryEntry
	modelVersions      map[string]*contracts.ModelVersion // modelID:version → version
	modelVersionByID   map[int64]*contracts.ModelVersion
	modelVersionFiles  map[int64][]contracts.ModelVersionFile
	activeModelVersion map[string]int64 // modelID → modelVersionID
	modelVersionSeq    int64
	publishingAPIKeys  map[string]*contracts.PublishingAPIKey
	modelAliases       map[string]*contracts.ModelAlias // aliasID → alias

	// Users (Privy)
	usersByPrivyID         map[string]*contracts.User // privyUserID → user
	usersByAccountID       map[string]*contracts.User // accountID → user
	usersByStripeAccountID map[string]*contracts.User // stripeAccountID → user (subset of usersByAccountID)

	// Global Payouts use the same balance lock as Connect withdrawals.
	globalRecipients map[string]contracts.GlobalRecipient
	globalPayouts    map[string]contracts.GlobalPayout

	// Stripe Connect withdrawals
	stripeWithdrawalsByID         map[string]*contracts.StripeWithdrawal
	stripeWithdrawalsByTransferID map[string]string   // transferID → withdrawalID
	stripeWithdrawalsByPayoutID   map[string]string   // payoutID → withdrawalID
	stripeWithdrawalsByAccount    map[string][]string // accountID → []withdrawalID, newest last

	// Device authorization
	deviceCodesByCode     map[string]*contracts.DeviceCode // deviceCode → DeviceCode
	deviceCodesByUserCode map[string]*contracts.DeviceCode // userCode → DeviceCode

	// Provider tokens
	providerTokens map[string]*contracts.ProviderToken // tokenHash → ProviderToken

	// Invite codes
	inviteCodes        map[string]*contracts.InviteCode        // code → InviteCode
	inviteRedemptions  map[string][]contracts.InviteRedemption // code → list of redemptions
	accountRedemptions map[string]map[string]bool              // accountID → set of redeemed codes

	// Provider earnings (per-node tracking)
	providerEarnings    []contracts.ProviderEarning
	providerEarningsSeq int64 // auto-increment ID

	// Provider payouts (wallet-based)
	providerPayouts   []contracts.ProviderPayout
	providerPayoutSeq int64 // auto-increment ID

	// Releases (provider binary versioning)
	releases map[string]*contracts.Release // "version:platform" → Release

	// Provider fleet persistence
	providerRecords    map[string]*contracts.ProviderRecord   // providerID → record
	reputationRecords  map[string]*contracts.ReputationRecord // providerID → reputation
	serialToProviderID map[string]string                      // serialNumber → providerID

	// APNs code-identity attestation reuse cache (W5 Fix 2). Keyed by SE pubkey.
	// In the memory store this is lost on restart (same as the in-memory throttle
	// it backs), but the methods exist so the store seam is uniform and Postgres
	// persists for real once it is the production backend.
	codeAttestations      map[string]contracts.CodeAttestation
	codeAttestPushBudgets map[string]contracts.CodeAttestPushBudget

	// Provider trust-reuse cache (DAR-326 Phase 0). Keyed by SE pubkey. Mirrors
	// codeAttestations: lost on restart in the memory store (same as the in-memory
	// cache it backs), but the methods exist so the store seam is uniform and
	// Postgres persists for real as the production backend.
	providerTrustReuse map[string]contracts.ProviderTrustReuse

	// Durable scheduler parity for tests/development. Key is SE key + task kind.
	verificationJobs map[string]contracts.VerificationJob

	// Provider log reports
	logReports   []contracts.LogReport
	logReportSeq int64

	// Provider sessions (connect→disconnect uptime history)
	providerSessions   []contracts.ProviderSession
	providerSessionSeq int64

	// Inference routing telemetry
	inferenceRoutes        []contracts.InferenceRouteRecord
	inferenceRouteIndex    map[string]int // request_id/attempt -> index in inferenceRoutes
	inferenceRouteOutcomes map[string]contracts.InferenceRouteOutcome

	// Rejected inbound inference requests (4xx/5xx) with servability snapshot.
	inferenceRejections []contracts.RejectionRecord

	// System profiler: per-attempt request profiles (write-once per
	// request_id/attempt, mirroring the Postgres UNIQUE + DO NOTHING) and
	// per-tick fleet snapshots. Both are append-only and capped by Prune.
	requestOutcomes    map[string]contracts.RequestOutcomeRecord
	requestProfiles    []contracts.RequestProfileRecord
	requestProfileKeys map[string]struct{} // request_id/attempt -> present
	fleetSnapshots     []contracts.FleetSnapshotRow

	// Base rewards — per-epoch floor draws (idempotent on provider_key|epoch_id).
	providerFloorDraws []contracts.ProviderFloorDraw
	floorDrawSeq       int64
	floorDrawKeys      map[string]struct{} // "providerKey|epochID" → settled marker

}

// New creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func New(scfg contracts.Config) *Store {
	s := &Store{
		keyRecords:                    make(map[string]*contracts.APIKey),
		keysByID:                      make(map[string]string),
		keySpend:                      make(map[string]*keySpend),
		usage:                         make([]contracts.UsageRecord, 0),
		payments:                      make([]contracts.PaymentRecord, 0),
		balances:                      make(map[string]int64),
		withdrawable:                  make(map[string]int64),
		ledgerEntries:                 make([]contracts.LedgerEntry, 0),
		referrersByCode:               make(map[string]*contracts.Referrer),
		referrersByAccount:            make(map[string]*contracts.Referrer),
		referrals:                     make(map[string]string),
		referralCounts:                make(map[string]int),
		billingSessions:               make(map[string]*contracts.BillingSession),
		modelPrices:                   make(map[string]contracts.ModelPrice),
		modelRegistry:                 make(map[string]*contracts.ModelRegistryEntry),
		modelAliases:                  make(map[string]*contracts.ModelAlias),
		modelVersions:                 make(map[string]*contracts.ModelVersion),
		modelVersionByID:              make(map[int64]*contracts.ModelVersion),
		modelVersionFiles:             make(map[int64][]contracts.ModelVersionFile),
		activeModelVersion:            make(map[string]int64),
		publishingAPIKeys:             make(map[string]*contracts.PublishingAPIKey),
		usersByPrivyID:                make(map[string]*contracts.User),
		usersByAccountID:              make(map[string]*contracts.User),
		usersByStripeAccountID:        make(map[string]*contracts.User),
		stripeWithdrawalsByID:         make(map[string]*contracts.StripeWithdrawal),
		stripeWithdrawalsByTransferID: make(map[string]string),
		stripeWithdrawalsByPayoutID:   make(map[string]string),
		stripeWithdrawalsByAccount:    make(map[string][]string),
		deviceCodesByCode:             make(map[string]*contracts.DeviceCode),
		deviceCodesByUserCode:         make(map[string]*contracts.DeviceCode),
		providerTokens:                make(map[string]*contracts.ProviderToken),
		inviteCodes:                   make(map[string]*contracts.InviteCode),
		inviteRedemptions:             make(map[string][]contracts.InviteRedemption),
		accountRedemptions:            make(map[string]map[string]bool),
		providerEarnings:              make([]contracts.ProviderEarning, 0),
		providerPayouts:               make([]contracts.ProviderPayout, 0),
		releases:                      make(map[string]*contracts.Release),
		providerRecords:               make(map[string]*contracts.ProviderRecord),
		reputationRecords:             make(map[string]*contracts.ReputationRecord),
		serialToProviderID:            make(map[string]string),
		codeAttestations:              make(map[string]contracts.CodeAttestation),
		codeAttestPushBudgets:         make(map[string]contracts.CodeAttestPushBudget),
		providerTrustReuse:            make(map[string]contracts.ProviderTrustReuse),
		verificationJobs:              make(map[string]contracts.VerificationJob),
		inferenceRoutes:               make([]contracts.InferenceRouteRecord, 0),
		inferenceRouteIndex:           make(map[string]int),
		inferenceRouteOutcomes:        make(map[string]contracts.InferenceRouteOutcome),
		inferenceRejections:           make([]contracts.RejectionRecord, 0),
		requestProfiles:               make([]contracts.RequestProfileRecord, 0),
		requestProfileKeys:            make(map[string]struct{}),
		fleetSnapshots:                make([]contracts.FleetSnapshotRow, 0),
		providerFloorDraws:            make([]contracts.ProviderFloorDraw, 0),
		floorDrawKeys:                 make(map[string]struct{}),
	}
	if scfg.AdminKey != "" {
		s.keyRecords[scfg.AdminKey] = &contracts.APIKey{
			ID:         "key_admin_seed",
			Name:       "admin",
			Label:      contracts.KeyLabel(scfg.AdminKey),
			LimitReset: contracts.KeyResetNone,
			CreatedAt:  time.Now(),
		}
		s.keysByID["key_admin_seed"] = scfg.AdminKey
	}
	return s
}
