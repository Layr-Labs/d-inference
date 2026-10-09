package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// lateRejection is a rejection record of account a with personal model
// names and parameters.
func lateRejection(a erasurefixture.Account) *store.RejectionRecord {
	return &store.RejectionRecord{
		RequestID: erasurefixture.UniqueID("req-rejected"), Endpoint: "/v1/chat/completions", Stage: "validation", ReasonCode: "model_not_found",
		HTTPStatus: 404, ConsumerKeyHash: store.HashKey(a.AccountID), RequestedModel: "personal-model", ResolvedModel: "personal-resolved",
		Params: json.RawMessage(`{"user":"personal-param"}`),
	}
}

// rejectionsOf returns the rejection records of account a.
func rejectionsOf(s store.Store, a erasurefixture.Account) []store.RejectionRecord {
	var out []store.RejectionRecord
	for _, r := range s.RejectionRecordsSince(time.Time{}) {
		if r.ConsumerKeyHash == store.HashKey(a.AccountID) {
			out = append(out, r)
		}
	}
	return out
}

// A rejection record is written asynchronously, and a pricing request
// authenticates before it reads the body. Both can arrive after the erasure.
// A price write is refused from the confirm on, and a late rejection record
// keeps no model names and no parameters. After a cancel both work again.
func TestErasureFencesLateRejectionAndPricingWrites(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, cancel := range []bool{false, true} {
				name := "scrubbed"
				if cancel {
					name = "canceled"
				}
				t.Run(name, func(t *testing.T) {
					ctx := context.Background()
					a := erasurefixture.SeedAccount(t, s)
					price := store.ModelPrice{AccountID: a.AccountID, Model: "personal-model", InputPrice: 1, OutputPrice: 2}
					if err := s.SetModelPrice(price); err != nil {
						t.Fatal(err)
					}
					if err := s.RecordRejection(lateRejection(a)); err != nil {
						t.Fatal(err)
					}
					now := time.Now().UTC()
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					if err := s.SetModelPrice(price); !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("price write during the grace period: %v; want ErrErasureConflict", err)
					}
					// Written during the grace period: the scrub clears it.
					if err := s.RecordRejection(lateRejection(a)); err != nil {
						t.Fatal(err)
					}
					if cancel {
						if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
							t.Fatal(err)
						}
					} else if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
						t.Fatal(err)
					}

					// The delayed writes.
					priceErr := s.SetModelPrice(price)
					if err := s.RecordRejection(lateRejection(a)); err != nil {
						t.Fatal(err)
					}
					rejections := rejectionsOf(s, a)
					if len(rejections) != 3 {
						t.Fatalf("rejection records = %d; want 3", len(rejections))
					}
					if cancel {
						if priceErr != nil {
							t.Fatalf("price write after cancel: %v", priceErr)
						}
						if r := rejections[0]; r.RequestedModel != "personal-model" || len(r.Params) == 0 {
							t.Fatalf("rejection record after cancel = %+v; want its fields", r)
						}
						return
					}
					if !errors.Is(priceErr, store.ErrErasureConflict) {
						t.Fatalf("price write after the scrub: %v; want ErrErasureConflict", priceErr)
					}
					if prices := s.ListModelPrices(a.AccountID); len(prices) != 0 {
						t.Fatalf("prices after the scrub = %+v; want none", prices)
					}
					for _, r := range rejections {
						if r.RequestedModel != "" || r.ResolvedModel != "" || len(r.Params) != 0 {
							t.Fatalf("rejection record after the scrub = %+v; want no model names and no parameters", r)
						}
					}
				})
			}
		})
	}
}
