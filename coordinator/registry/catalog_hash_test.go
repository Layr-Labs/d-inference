package registry

// Regression test for the catalog weight-hash filter: an empty provider-reported
// weight hash must not bypass a pinned catalog entry. An honest provider hashes
// every servable model from disk, so an empty hash is never a valid "cold model"
// signal — it's a missing model or a swap-detection dodge. Fails without the fix
// (which previously short-circuited on `model.WeightHash == ""`), passes with it.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestModelAllowedByCatalog_EmptyHashRejectedWhenPinned(t *testing.T) {
	reg := New(testLogger())

	const pinned = "mlx-community/pinned-model"
	const unpinned = "mlx-community/unpinned-model"
	reg.SetModelCatalog([]CatalogEntry{
		{ID: pinned, WeightHash: "EXPECTED_HASH"},
		{ID: unpinned}, // no expected hash → not enforced
	})

	reg.mu.RLock()
	defer reg.mu.RUnlock()

	cases := []struct {
		name  string
		model protocol.ModelInfo
		want  bool
	}{
		{"empty hash on a pinned model is rejected", protocol.ModelInfo{ID: pinned, WeightHash: ""}, false},
		{"matching hash on a pinned model is allowed", protocol.ModelInfo{ID: pinned, WeightHash: "EXPECTED_HASH"}, true},
		{"mismatched hash on a pinned model is rejected", protocol.ModelInfo{ID: pinned, WeightHash: "WRONG"}, false},
		{"unpinned model allows any (incl. empty) hash", protocol.ModelInfo{ID: unpinned, WeightHash: ""}, true},
		{"model not in catalog is denied", protocol.ModelInfo{ID: "not-in-catalog", WeightHash: "x"}, false},
	}
	for _, tc := range cases {
		if got := reg.modelAllowedByCatalogLocked(tc.model); got != tc.want {
			t.Errorf("%s: allowed=%v, want %v", tc.name, got, tc.want)
		}
	}
}
