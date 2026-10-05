package store_test

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestModelTokenPromotionFirst250ClaimsAreAtomic(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := store.As[store.ModelTokenPromotionStore](s)
			now := time.Now().UTC().Truncate(time.Second)
			p := store.ModelTokenPromotion{ModelID: "launch", Tokens: 150_000_000, ClaimStartsAt: now.Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(now.Add(time.Hour)), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 250, Enabled: true}
			if err := b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 270; i++ {
				id := fmt.Sprintf("claimant-%d", i)
				if err := s.CreateUser(&store.User{AccountID: id, PrivyUserID: "did:privy:" + id}); err != nil {
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
					} else if errors.Is(err, store.ErrPromotionFull) {
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
