package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"golang.org/x/sync/errgroup"
)

// seedModels are fake model IDs, so seeded usage never reads as real traffic.
var seedModels = []string{"devnet-seed/text-small", "devnet-seed/text-large"}

type seededAccount struct {
	accountID string
	keyID     string
}

type seededProvider struct {
	ownerAccountID string
	providerID     string // the last session's providers.id
	providerKey    string
}

type seedResult struct {
	accounts, apiKeys, providers, sessions, requests int
}

// seed writes through the same store methods the coordinator uses: CreateUser
// (Privy sign-up), CreateAPIKey, UpsertProvider and the provider session calls
// (registry), Credit/Debit (deposits and charges), RecordUsage and
// CreditProviderAccount (request settlement).
func seed(ctx context.Context, st store.Store, o options) (seedResult, error) {
	accounts := make([]seededAccount, o.accounts)
	if err := parallel(ctx, o.workers, o.accounts, func(i int) error {
		account, err := seedAccount(st, i+1, o.keysPerAccount)
		accounts[i] = account
		return err
	}); err != nil {
		return seedResult{}, err
	}

	providers := make([]seededProvider, o.providers)
	if err := parallel(ctx, o.workers, o.providers, func(i int) error {
		provider, err := seedProvider(ctx, st, i+1, accounts[i%len(accounts)].accountID, o.sessionsPerProvider)
		providers[i] = provider
		return err
	}); err != nil {
		return seedResult{}, err
	}

	if err := parallel(ctx, o.workers, o.accounts, func(i int) error {
		return seedRequests(st, i+1, accounts[i], providers, o.requestsPerAccount, o.balanceMicroUSD)
	}); err != nil {
		return seedResult{}, err
	}

	return seedResult{
		accounts:  o.accounts,
		apiKeys:   o.accounts * o.keysPerAccount,
		providers: o.providers,
		sessions:  o.providers * o.sessionsPerProvider,
		requests:  o.accounts * o.requestsPerAccount,
	}, nil
}

// parallel runs fn for 0..n-1 on at most workers goroutines and stops
// starting new work after the first error or cancellation.
func parallel(ctx context.Context, workers, n int, fn func(i int) error) error {
	g, groupCtx := errgroup.WithContext(ctx)
	g.SetLimit(workers)
	for i := 0; i < n && groupCtx.Err() == nil; i++ {
		g.Go(func() error { return fn(i) })
	}
	if err := g.Wait(); err != nil {
		return err
	}
	return ctx.Err()
}

func seedAccount(st store.Store, n, keys int) (seededAccount, error) {
	user := &store.User{
		AccountID:   uuid.NewString(),
		PrivyUserID: fmt.Sprintf("did:privy:seed-%d", n),
		Email:       fmt.Sprintf("seed-%d@example.invalid", n),
	}
	if err := st.CreateUser(user); err != nil {
		return seededAccount{}, fmt.Errorf("account %d: %w", n, err)
	}
	account := seededAccount{accountID: user.AccountID}
	for k := 1; k <= keys; k++ {
		_, key, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{Name: fmt.Sprintf("seed key %d", k)})
		if err != nil {
			return seededAccount{}, fmt.Errorf("account %d key %d: %w", n, k, err)
		}
		if k == 1 {
			account.keyID = key.ID
		}
	}
	return account, nil
}

func seedProvider(ctx context.Context, st store.Store, n int, ownerAccountID string, sessions int) (seededProvider, error) {
	serial := fmt.Sprintf("SEED%08d", n)
	keyBytes := sha256.Sum256([]byte("devnet-seed provider " + serial))
	providerKey := base64.StdEncoding.EncodeToString(keyBytes[:])
	hardware, err := json.Marshal(protocol.Hardware{
		MachineModel: "SeedMac1,1",
		ChipName:     "Seed Chip",
		ChipFamily:   "seed",
		ChipTier:     "seed",
		MemoryGB:     64,
		CPUCores:     protocol.CPUCores{Total: 12, Performance: 8, Efficiency: 4},
		GPUCores:     32,
	})
	if err != nil {
		return seededProvider{}, err
	}
	models, err := json.Marshal([]protocol.ModelInfo{{ID: seedModels[n%len(seedModels)], ModelType: "seed"}})
	if err != nil {
		return seededProvider{}, err
	}

	provider := seededProvider{ownerAccountID: ownerAccountID, providerKey: providerKey}
	now := time.Now().UTC()
	for s := 0; s < sessions; s++ {
		// Each connection gets its own providers.id, which is also its session ID.
		id := uuid.NewString()
		seen := now.Add(-time.Duration(sessions-s) * time.Hour)
		if err := st.UpsertProvider(ctx, store.ProviderRecord{
			ID:           id,
			Hardware:     hardware,
			Models:       models,
			Backend:      "devnet-seed",
			TrustLevel:   "none",
			PublicKey:    providerKey,
			SerialNumber: serial,
			Version:      "0.0.0-seed",
			AccountID:    ownerAccountID,
			RegisteredAt: seen,
			LastSeen:     seen,
		}); err != nil {
			return seededProvider{}, fmt.Errorf("provider %s: %w", serial, err)
		}
		if err := st.OpenProviderSession(ctx, id, serial, ownerAccountID); err != nil {
			return seededProvider{}, fmt.Errorf("provider %s session: %w", serial, err)
		}
		if err := st.TouchProviderSession(ctx, id, serial, ownerAccountID, providerKey, seen); err != nil {
			return seededProvider{}, fmt.Errorf("provider %s session: %w", serial, err)
		}
		if err := st.CloseProviderSession(ctx, id, "devnet-seed", seen); err != nil {
			return seededProvider{}, fmt.Errorf("provider %s session: %w", serial, err)
		}
		provider.providerID = id
	}
	return provider, nil
}

type seedRequest struct {
	id       string
	model    string
	usage    payments.Usage
	cost     int64
	provider seededProvider
}

// seedRequests deposits exactly enough to pay for the account's requests plus
// the requested remaining balance, then settles each request like a completed
// inference: charge the consumer, record usage, credit the provider owner and
// the platform fee.
func seedRequests(st store.Store, n int, account seededAccount, providers []seededProvider, count int, balance int64) error {
	rates := payments.DefaultRates()
	requests := make([]seedRequest, count)
	deposit := balance
	for r := range requests {
		usage := payments.Usage{PromptTokens: 200 + (n*37+r*53)%1000, CompletionTokens: 50 + (n*11+r*29)%400}
		cost := rates.CostWithMinimum(usage)
		requests[r] = seedRequest{
			id:       fmt.Sprintf("seed-req-%d-%d", n, r+1),
			model:    seedModels[(n+r)%len(seedModels)],
			usage:    usage,
			cost:     cost,
			provider: providers[(n+r)%len(providers)],
		}
		deposit += cost
	}
	if deposit > 0 {
		if err := st.Credit(account.accountID, deposit, store.LedgerDeposit, fmt.Sprintf("seed-deposit-%d", n)); err != nil {
			return fmt.Errorf("account %d deposit: %w", n, err)
		}
	}
	for _, req := range requests {
		if err := st.Debit(account.accountID, req.cost, store.LedgerCharge, req.id); err != nil {
			return fmt.Errorf("request %s charge: %w", req.id, err)
		}
		st.RecordUsage(store.UsageRecord{
			ProviderID:       req.provider.providerID,
			ConsumerKey:      account.accountID,
			KeyID:            account.keyID,
			Model:            req.model,
			PublicModel:      req.model,
			PromptTokens:     req.usage.PromptTokens,
			CompletionTokens: req.usage.CompletionTokens,
			RequestID:        req.id,
			CostMicroUSD:     req.cost,
		})
		if payout := payments.ProviderPayout(req.cost); payout > 0 {
			if err := st.CreditProviderAccount(&store.ProviderEarning{
				AccountID:        req.provider.ownerAccountID,
				ProviderID:       req.provider.providerID,
				ProviderKey:      req.provider.providerKey,
				JobID:            req.id,
				Model:            req.model,
				AmountMicroUSD:   payout,
				PromptTokens:     req.usage.PromptTokens,
				CompletionTokens: req.usage.CompletionTokens,
				CreatedAt:        time.Now().UTC(),
			}); err != nil {
				return fmt.Errorf("request %s provider credit: %w", req.id, err)
			}
		}
		if fee := payments.PlatformFee(req.cost); fee > 0 {
			if err := st.Credit("platform", fee, store.LedgerPlatformFee, req.id); err != nil {
				return fmt.Errorf("request %s platform fee: %w", req.id, err)
			}
		}
	}
	return nil
}
