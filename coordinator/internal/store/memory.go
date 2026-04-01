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
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// Compile-time check that MemoryStore implements Store.
var _ Store = (*MemoryStore)(nil)

// MemoryStore manages API keys, usage records, payments, and balances in memory.
type MemoryStore struct {
	mu            sync.RWMutex
	keys          map[string]bool    // key → valid
	keyAccounts   map[string]string  // key → accountID (owner)
	usage         []UsageRecord
	payments      []PaymentRecord
	balances      map[string]int64   // accountID → micro-USD
	ledgerEntries []LedgerEntry
	ledgerSeq     int64              // auto-increment ID

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
}

// NewMemory creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func NewMemory(adminKey string) *MemoryStore {
	s := &MemoryStore{
		keys:               make(map[string]bool),
		keyAccounts:        make(map[string]string),
		usage:              make([]UsageRecord, 0),
		payments:           make([]PaymentRecord, 0),
		balances:           make(map[string]int64),
		ledgerEntries:      make([]LedgerEntry, 0),
		referrersByCode:    make(map[string]*Referrer),
		referrersByAccount: make(map[string]*Referrer),
		referrals:          make(map[string]string),
		referralCounts:     make(map[string]int),
		billingSessions:    make(map[string]*BillingSession),
		modelPrices:      make(map[string]ModelPrice),
		supportedModels: make(map[string]*SupportedModel),
		usersByPrivyID:        make(map[string]*User),
		usersByAccountID:      make(map[string]*User),
		deviceCodesByCode:     make(map[string]*DeviceCode),
		deviceCodesByUserCode: make(map[string]*DeviceCode),
		providerTokens:        make(map[string]*ProviderToken),
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
	key := "dginf-" + hex.EncodeToString(b)

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
	key := "dginf-" + hex.EncodeToString(b)

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

	s.balances[accountID] += amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
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

// sha256Hex returns the hex-encoded SHA-256 digest of s.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
