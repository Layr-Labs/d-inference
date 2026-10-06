package memory

import (
	"github.com/eigeninference/d-inference/coordinator/internal/store/consumersettlement"
	inventory "github.com/eigeninference/d-inference/coordinator/internal/store/inventory"

	"sync"
	"time"

	epochlocks "github.com/eigeninference/d-inference/coordinator/internal/store/epochlocks"

	memoryhistory "github.com/eigeninference/d-inference/coordinator/internal/store/memoryhistory"
	"github.com/eigeninference/d-inference/coordinator/store"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Compile-time check that MemoryStore implements Store.
var _ store.Store = (*MemoryStore)(nil)

// MemoryStore manages API keys, usage records, payments, and balances in memory.
type MemoryStore struct {
	now                       func() time.Time
	history                   *memoryhistory.State
	smallModelsInterest       map[string]store.SmallModelsInterest
	autopilotRecords          map[string]store.AutopilotRecord
	modelTokenProviderCarries map[string]int64
	modelTokenPromotions      map[string]store.ModelTokenPromotion
	modelTokenGrants          map[string]map[string]store.ModelTokenGrant
	modelTokenReservations    map[string]store.ModelTokenReservation
	consumerSettlements       map[string]consumersettlement.Record

	mu           sync.RWMutex
	epochLocks   epochlocks.Owner
	keyRecords   map[string]*store.APIKey // raw key → record (metadata + limits)
	keysByID     map[string]string        // public key ID → raw key
	keySpend     map[string]*keySpend
	balances     map[string]int64 // accountID → micro-USD
	withdrawable map[string]int64 // accountID → withdrawable micro-USD (subset of balance)
	ledgerSeq    int64            // auto-increment ID

	// Observation-only keys; independent from provider/rewards identity.
	appAttestShadowKeys     map[string]store.AppAttestShadowKey
	appAttestRevocations    map[string]bool
	machineInventory        *inventory.State
	appAttestEvidence       map[string]memoryAppAttestEvidence
	appAttestEnrollments    map[string]store.AppAttestEnrollment
	appAttestBuilds         map[string]store.AppAttestBuildQualification
	cacheHolders            map[crs.HolderKey]crs.HolderRecord
	cacheDemand             map[string]time.Time
	cacheRoutingFingerprint string
	appAttestRotations      map[string]store.AppAttestKeyRotation

	// Referral system
	referrersByCode    map[string]*store.Referrer // code → referrer
	referrersByAccount map[string]*store.Referrer // accountID → referrer
	referrals          map[string]string          // referredAccountID → referrerCode
	referralCounts     map[string]int             // referrerCode → count of referred accounts

	// Billing sessions
	billingSessions map[string]*store.BillingSession // sessionID → session

	// Custom pricing
	modelPrices map[string]store.ModelPrice // "accountID:model" → price

	// Model registry (manifest-backed catalog)
	modelRegistry      map[string]*store.ModelRegistryEntry
	modelVersions      map[string]*store.ModelVersion // modelID:version → version
	modelVersionByID   map[int64]*store.ModelVersion
	modelVersionFiles  map[int64][]store.ModelVersionFile
	activeModelVersion map[string]int64 // modelID → modelVersionID
	modelVersionSeq    int64
	publishingAPIKeys  map[string]*store.PublishingAPIKey
	modelAliases       map[string]*store.ModelAlias // aliasID → alias

	// Users (Privy)
	usersByPrivyID         map[string]*store.User // privyUserID → user
	usersByAccountID       map[string]*store.User // accountID → user
	usersByStripeAccountID map[string]*store.User // stripeAccountID → user (subset of usersByAccountID)

	// Global Payouts use the same balance lock as Connect withdrawals.
	globalRecipients map[string]store.GlobalRecipient
	globalPayouts    map[string]store.GlobalPayout

	// Stripe Connect withdrawals
	stripeWithdrawalsByID         map[string]*store.StripeWithdrawal
	stripeWithdrawalsByTransferID map[string]string   // transferID → withdrawalID
	stripeWithdrawalsByPayoutID   map[string]string   // payoutID → withdrawalID
	stripeWithdrawalsByAccount    map[string][]string // accountID → []withdrawalID, newest last

	// Device authorization

	// Provider tokens
	providerTokens map[string]*store.ProviderToken // tokenHash → ProviderToken

	// Invite codes
	inviteCodes        map[string]*store.InviteCode        // code → InviteCode
	inviteRedemptions  map[string][]store.InviteRedemption // code → list of redemptions
	accountRedemptions map[string]map[string]bool          // accountID → set of redeemed codes

	// Provider earnings (per-node tracking)
	providerEarningsSeq int64 // auto-increment ID

	// Releases (provider binary versioning)
	releases map[string]*store.Release // "version:platform" → Release

	// Provider fleet persistence
	providerRecords   map[string]*store.ProviderRecord   // providerID → record
	reputationRecords map[string]*store.ReputationRecord // providerID → reputation

	// APNs code-identity attestation reuse cache (W5 Fix 2). Keyed by SE pubkey.
	// In the memory store this is lost on restart (same as the in-memory throttle
	// it backs), but the methods exist so the store seam is uniform and Postgres
	// persists for real once it is the production backend.
	codeAttestations      map[string]store.CodeAttestation
	codeAttestPushBudgets map[string]store.CodeAttestPushBudget

	// Provider trust-reuse cache (DAR-326 Phase 0). Keyed by SE pubkey. Mirrors
	// codeAttestations: lost on restart in the memory store (same as the in-memory
	// cache it backs), but the methods exist so the store seam is uniform and
	// Postgres persists for real as the production backend.
	providerTrustReuse    map[string]store.ProviderTrustReuse
	legacyMDMCohortCutoff time.Time
	legacyMDMCohort       []store.LegacyMDMMachine

	// Durable scheduler parity for tests/development. Key is SE key + task kind.
	verificationJobs map[string]store.VerificationJob

	// Provider log reports
	logReportSeq int64

	// Provider sessions (connect→disconnect uptime history)

	// Inference routing telemetry
	inferenceRoutes        []store.InferenceRouteRecord
	inferenceRouteIndex    map[string]int // request_id/attempt -> index in inferenceRoutes
	inferenceRouteOutcomes map[string]store.InferenceRouteOutcome

	// Rejected inbound inference requests (4xx/5xx) with servability snapshot.
	inferenceRejections []store.RejectionRecord

	// System profiler: per-attempt request profiles (write-once per
	// request_id/attempt, mirroring the Postgres UNIQUE + DO NOTHING) and
	// per-tick fleet snapshots. Both are append-only and capped by Prune.
	modelDemand          map[string]modelDemandObservation
	modelDemandStartedAt time.Time

	// Base rewards — per-epoch floor draws (idempotent on provider_key|epoch_id).
	floorDrawSeq  int64
	floorDrawKeys map[string]struct{} // "providerKey|epochID" → settled marker

	// Account erasure requests and their outbox rows.
	erasureSEOwners    map[string]map[string]bool
	erasureRequests    map[string]*memoryErasureRequest
	erasureOutbox      []store.ErasureOutboxItem
	erasureOutboxLease map[string]time.Time // outbox row ID → lease end
	// Erased accounts refuse credits; refused ones are kept for review.
	erasedAccounts           map[string]bool
	erasureRefusedCredits    []store.ErasureRefusedCredit
	erasureRefusedSeq        int64
	erasureRefusedIdentities map[refusedCreditIdentity]bool
}

// NewMemory creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func NewMemory(scfg store.Config) *MemoryStore {
	now := scfg.Now
	if now == nil {
		now = time.Now
	}
	s := &MemoryStore{
		consumerSettlements:           make(map[string]consumersettlement.Record),
		now:                           now,
		history:                       memoryhistory.New(),
		smallModelsInterest:           make(map[string]store.SmallModelsInterest),
		modelDemandStartedAt:          time.Now().UTC(),
		erasureSEOwners:               make(map[string]map[string]bool),
		erasureRequests:               make(map[string]*memoryErasureRequest),
		erasureOutboxLease:            make(map[string]time.Time),
		erasedAccounts:                make(map[string]bool),
		keyRecords:                    make(map[string]*store.APIKey),
		keysByID:                      make(map[string]string),
		keySpend:                      make(map[string]*keySpend),
		balances:                      make(map[string]int64),
		withdrawable:                  make(map[string]int64),
		referrersByCode:               make(map[string]*store.Referrer),
		referrersByAccount:            make(map[string]*store.Referrer),
		referrals:                     make(map[string]string),
		referralCounts:                make(map[string]int),
		billingSessions:               make(map[string]*store.BillingSession),
		modelPrices:                   make(map[string]store.ModelPrice),
		modelRegistry:                 make(map[string]*store.ModelRegistryEntry),
		modelAliases:                  make(map[string]*store.ModelAlias),
		modelVersions:                 make(map[string]*store.ModelVersion),
		modelVersionByID:              make(map[int64]*store.ModelVersion),
		modelVersionFiles:             make(map[int64][]store.ModelVersionFile),
		activeModelVersion:            make(map[string]int64),
		publishingAPIKeys:             make(map[string]*store.PublishingAPIKey),
		usersByPrivyID:                make(map[string]*store.User),
		usersByAccountID:              make(map[string]*store.User),
		usersByStripeAccountID:        make(map[string]*store.User),
		stripeWithdrawalsByID:         make(map[string]*store.StripeWithdrawal),
		stripeWithdrawalsByTransferID: make(map[string]string),
		stripeWithdrawalsByPayoutID:   make(map[string]string),
		stripeWithdrawalsByAccount:    make(map[string][]string),
		providerTokens:                make(map[string]*store.ProviderToken),
		inviteCodes:                   make(map[string]*store.InviteCode),
		inviteRedemptions:             make(map[string][]store.InviteRedemption),
		accountRedemptions:            make(map[string]map[string]bool),
		releases:                      make(map[string]*store.Release),
		providerRecords:               make(map[string]*store.ProviderRecord),
		reputationRecords:             make(map[string]*store.ReputationRecord),
		codeAttestations:              make(map[string]store.CodeAttestation),
		codeAttestPushBudgets:         make(map[string]store.CodeAttestPushBudget),
		providerTrustReuse:            make(map[string]store.ProviderTrustReuse),
		verificationJobs:              make(map[string]store.VerificationJob),
		inferenceRoutes:               make([]store.InferenceRouteRecord, 0),
		inferenceRouteIndex:           make(map[string]int),
		inferenceRouteOutcomes:        make(map[string]store.InferenceRouteOutcome),
		inferenceRejections:           make([]store.RejectionRecord, 0),
		floorDrawKeys:                 make(map[string]struct{}),
	}
	if scfg.AdminKey != "" {
		s.keyRecords[scfg.AdminKey] = &store.APIKey{
			ID:         "key_admin_seed",
			Name:       "admin",
			Label:      store.KeyLabel(scfg.AdminKey),
			LimitReset: store.KeyResetNone,
			CreatedAt:  time.Now(),
		}
		s.keysByID["key_admin_seed"] = scfg.AdminKey
	}
	return s
}
