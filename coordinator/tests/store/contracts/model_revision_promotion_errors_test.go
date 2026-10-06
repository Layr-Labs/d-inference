package store_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestModelRevisionPromotionMissingModel(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := st.PromoteModelVersion(uniqueID("missing-model"), "v1")
			if err == nil || !strings.Contains(err.Error(), "not found") {
				t.Fatalf("missing model promotion must report not found, got %v", err)
			}
			if name == "postgres" && !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("parent-row miss lost the store not-found identity: %v", err)
			}
		})
	}
}
