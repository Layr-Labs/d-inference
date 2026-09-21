package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestModelTokenPromotionFirst250ClaimsAreAtomic(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := As[ModelTokenPromotionStore](s)
			now := time.Now().UTC().Truncate(time.Second)
			p := ModelTokenPromotion{ModelID: "launch", Tokens: 150_000_000, ClaimStartsAt: now.Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(now.Add(time.Hour)), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 250, Enabled: true}
			if err := b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 270; i++ {
				id := fmt.Sprintf("claimant-%d", i)
				if err := s.CreateUser(&User{AccountID: id, PrivyUserID: "did:privy:" + id}); err != nil {
					t.Fatal(err)
				}
			}
			var wg sync.WaitGroup
			var claimed atomic.Int64
			var soldOut atomic.Int64
			// Existing accounts have no grant until they explicitly claim.
			if grants, err := b.ListModelTokenGrants("claimant-0"); err != nil || len(grants) != 0 {
				t.Fatal(grants, err)
			}
			winners := make(chan string, 270)
			for i := 0; i < 270; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					id := fmt.Sprintf("claimant-%d", i)
					grants, err := b.ClaimModelTokenPromotion(id, p.ModelID, now)
					if err == nil {
						if len(grants) != 1 || grants[0].TotalTokens != 150_000_000 {
							t.Error(grants)
						}
						claimed.Add(1)
						winners <- id
					} else if errors.Is(err, ErrPromotionFull) {
						soldOut.Add(1)
					} else {
						t.Error(err)
					}
				}(i)
			}
			wg.Wait()
			close(winners)
			if claimed.Load() != 250 || soldOut.Load() != 20 {
				t.Fatalf("claimed=%d sold_out=%d", claimed.Load(), soldOut.Load())
			}
			for id := range winners {
				if _, err := b.ClaimModelTokenPromotion(id, p.ModelID, now.Add(48*time.Hour)); err != nil {
					t.Fatal("idempotent winner replay", err)
				}
			}
			promotions, _ := b.ListModelTokenPromotions()
			if promotions[0].ClaimedCount != 250 {
				t.Fatal(promotions)
			}
			p.Enabled = false
			if err := b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			promotions, _ = b.ListModelTokenPromotions()
			if promotions[0].ClaimedCount != 250 {
				t.Fatal("admin retry reset allocation count")
			}
		})
	}
}

func TestModelTokenPromotionSignupCutoffUsesPersistedCreationTime(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := As[ModelTokenPromotionStore](s)
			cutoff := time.Date(2026, 9, 19, 7, 0, 0, 0, time.UTC)
			now := cutoff.Add(12 * time.Hour)
			p := ModelTokenPromotion{ModelID: "eligibility", Tokens: 150_000_000, ClaimStartsAt: cutoff.Add(-24 * time.Hour), ClaimEndsAt: promotionClaimEnd(cutoff.Add(24 * time.Hour)), SignupCutoffAt: cutoff, MaxClaims: 250, Enabled: true}
			if err := b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				id       string
				created  time.Time
				eligible bool
			}{{"old", cutoff.Add(-48 * time.Hour), true}, {"last_today", cutoff.Add(-time.Microsecond), true}, {"tomorrow", cutoff, false}} {
				if err := s.CreateUser(&User{AccountID: tc.id, PrivyUserID: "did:privy:" + tc.id}); err != nil {
					t.Fatal(err)
				}
				switch backend := s.(type) {
				case *MemoryStore:
					backend.mu.Lock()
					backend.usersByAccountID[tc.id].CreatedAt = tc.created
					backend.mu.Unlock()
				case *PostgresStore:
					if _, err := backend.pool.Exec(context.Background(), `UPDATE users SET created_at=$2 WHERE account_id=$1`, tc.id, tc.created); err != nil {
						t.Fatal(err)
					}
				}
				_, err := b.ClaimModelTokenPromotion(tc.id, p.ModelID, now)
				if tc.eligible && err != nil {
					t.Fatal(tc.id, err)
				}
				if !tc.eligible && !errors.Is(err, ErrPromotionIneligible) {
					t.Fatalf("%s eligibility error %v", tc.id, err)
				}
			}
			promotions, _ := b.ListModelTokenPromotions()
			if promotions[0].ClaimedCount != 2 {
				t.Fatal("ineligible claim consumed slot")
			}
		})
	}
}
