package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDeleteModelPriceBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("acct")
			if err := s.SetModelPrice(store.ModelPrice{AccountID: account, Model: "model-a", InputPrice: 100, OutputPrice: 200}); err != nil {
				t.Fatal(err)
			}
			if err := s.SetModelPrice(store.ModelPrice{AccountID: account, Model: "model-b", InputPrice: 300, OutputPrice: 400}); err != nil {
				t.Fatal(err)
			}
			if err := s.DeleteModelPrice(account, "model-a"); err != nil {
				t.Fatalf("DeleteModelPrice: %v", err)
			}
			if _, ok := s.GetModelPrice(account, "model-a"); ok {
				t.Fatal("deleted price is still returned")
			}
			if p, ok := s.GetModelPrice(account, "model-b"); !ok || p.InputPrice != 300 || p.OutputPrice != 400 {
				t.Fatalf("other price changed: %+v, %v", p, ok)
			}
			if err := s.DeleteModelPrice(account, "model-a"); err == nil {
				t.Fatal("deleting a missing price succeeded")
			}
			if err := s.DeleteModelPrice(uniqueID("other-acct"), "model-b"); err == nil {
				t.Fatal("another account deleted the price")
			}
		})
	}
}
