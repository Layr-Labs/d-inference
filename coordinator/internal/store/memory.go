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
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"time"
)

// Compile-time check that MemoryStore implements Store.
var _ Store = (*MemoryStore)(nil)

// MemoryStore manages API keys, usage records, payments, and balances in memory.
type MemoryStore struct {
	mu            sync.RWMutex
	keys          map[string]bool   // key → valid
	keyAccounts   map[string]string // key → accountID (owner)
	usage         []UsageRecord
	payments      []PaymentRecord
	balances      map[string]int64 // accountID → micro-USD
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

	// Supported models (admin-managed catalog)
	supportedModels map[string]*SupportedModel // modelID → model

	// Users (Privy)
	usersByPrivyID   map[string]*User // privyUserID → user
	usersByAccountID map[string]*User // accountID → user

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

	// Telemetry ring buffer (bounded at memTelemetryCap)
	telemetryEvents []TelemetryEventRecord
}

// NewMemory creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func NewMemory(adminKey string) *MemoryStore {
	s := &MemoryStore{
		keys:                  make(map[string]bool),
		keyAccounts:           make(map[string]string),
		usage:                 make([]UsageRecord, 0),
		payments:              make([]PaymentRecord, 0),
		balances:              make(map[string]int64),
		ledgerEntries:         make([]LedgerEntry, 0),
		referrersByCode:       make(map[string]*Referrer),
		referrersByAccount:    make(map[string]*Referrer),
		referrals:             make(map[string]string),
		referralCounts:        make(map[string]int),
		billingSessions:       make(map[string]*BillingSession),
		modelPrices:           make(map[string]ModelPrice),
		supportedModels:       make(map[string]*SupportedModel),
		usersByPrivyID:        make(map[string]*User),
		usersByAccountID:      make(map[string]*User),
		deviceCodesByCode:     make(map[string]*DeviceCode),
		deviceCodesByUserCode: make(map[string]*DeviceCode),
		providerTokens:        make(map[string]*ProviderToken),
		inviteCodes:           make(map[string]*InviteCode),
		inviteRedemptions:     make(map[string][]InviteRedemption),
		accountRedemptions:    make(map[string]map[string]bool),
		providerEarnings:      make([]ProviderEarning, 0),
		providerPayouts:       make([]ProviderPayout, 0),
		releases:              make(map[string]*Release),
		providerRecords:       make(map[string]*ProviderRecord),
		reputationRecords:     make(map[string]*ReputationRecord),
		serialToProviderID:    make(map[string]string),
		telemetryEvents:       make([]TelemetryEventRecord, 0, memTelemetryCap),
	}
	if adminKey != "" {
		s.keys[adminKey] = true
	}
	return s
}

// CreateKey generates a cryptographically random API key, stores it, and
// returns it.
func (s *MemoryStore) CreateKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	key := "eigeninference-" + hex.EncodeToString(b)

	s.mu.Lock()
	s.keys[key] = true
	s.mu.Unlock()

	return key, nil
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *MemoryStore) CreateKeyForAccount(accountID string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	key := "eigeninference-" + hex.EncodeToString(b)

	s.mu.Lock()
	s.keys[key] = true
	s.keyAccounts[key] = accountID
	s.mu.Unlock()

	return key, nil
}

// ValidateKey returns true if the given key exists and is valid.
func (s *MemoryStore) ValidateKey(key string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.keys[key]
}

// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
func (s *MemoryStore) GetKeyAccount(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.keyAccounts[key]
}

// RevokeKey removes a key from the store. Returns true if the key existed.
func (s *MemoryStore) RevokeKey(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.keys[key] {
		delete(s.keys, key)
		return true
	}
	return false
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
	return out
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
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Timestamp:        time.Now(),
		RequestID:        requestID,
		CostMicroUSD:     costMicroUSD,
	})
}

// KeyCount returns the number of active API keys.
func (s *MemoryStore) KeyCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.keys)
}

// GetBalance returns the current balance in micro-USD for an account.
func (s *MemoryStore) GetBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID]
}

// Credit adds micro-USD to an account and records a ledger entry.
func (s *MemoryStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	return nil
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *MemoryStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.balances[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient balance: have %d, need %d micro-USD", s.balances[accountID], amountMicroUSD)
	}

	s.balances[accountID] -= amountMicroUSD
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
		return fmt.Errorf("account already has a referrer")
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

// --- Supported Models ---

func (s *MemoryStore) SetSupportedModel(model *SupportedModel) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *model
	s.supportedModels[model.ID] = &cp
	return nil
}

func (s *MemoryStore) ListSupportedModels() []SupportedModel {
	s.mu.RLock()
	defer s.mu.RUnlock()

	models := make([]SupportedModel, 0, len(s.supportedModels))
	for _, m := range s.supportedModels {
		models = append(models, *m)
	}
	// Sort by MinRAMGB ascending
	for i := 0; i < len(models); i++ {
		for j := i + 1; j < len(models); j++ {
			if models[j].MinRAMGB < models[i].MinRAMGB {
				models[i], models[j] = models[j], models[i]
			}
		}
	}
	return models
}

func (s *MemoryStore) DeleteSupportedModel(modelID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.supportedModels[modelID]; !ok {
		return fmt.Errorf("model %q not found", modelID)
	}
	delete(s.supportedModels, modelID)
	return nil
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
		return nil, fmt.Errorf("device code not found")
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
		return fmt.Errorf("device code not found")
	}
	if dc.Status != "pending" {
		return fmt.Errorf("device code is %s, not pending", dc.Status)
	}
	if time.Now().After(dc.ExpiresAt) {
		dc.Status = "expired"
		return fmt.Errorf("device code has expired")
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
		return fmt.Errorf("provider token already exists")
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
		return nil, fmt.Errorf("provider token not found")
	}
	if !pt.Active {
		return nil, fmt.Errorf("provider token is revoked")
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
		return fmt.Errorf("provider token not found")
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
		return fmt.Errorf("provider earning is required")
	}
	if earning.AccountID == "" {
		return fmt.Errorf("provider earning account_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *earning
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}

	s.creditLocked(cp.AccountID, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.CreatedAt)
	s.providerEarningsSeq++
	cp.ID = s.providerEarningsSeq
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *MemoryStore) CreditProviderWallet(payout *ProviderPayout) error {
	if payout == nil {
		return fmt.Errorf("provider payout is required")
	}
	if payout.ProviderAddress == "" {
		return fmt.Errorf("provider payout address is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *payout
	if cp.Timestamp.IsZero() {
		cp.Timestamp = time.Now()
	}

	s.creditLocked(cp.ProviderAddress, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.Timestamp)
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
		return fmt.Errorf("version and platform are required")
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
	return &cp, nil
}

func (s *MemoryStore) ListProviderRecords(_ context.Context) ([]ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0, len(s.providerRecords))
	for _, p := range s.providerRecords {
		records = append(records, *p)
	}
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

// sha256Hex returns the hex-encoded SHA-256 digest of s.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
