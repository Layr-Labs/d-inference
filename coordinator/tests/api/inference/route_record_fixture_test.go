package inference_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// findRouteRecord returns the stored route record for requestID, or nil.
func findRouteRecord(st *memory.MemoryStore, requestID string) *store.InferenceRouteRecord {
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == requestID {
			rec := r
			return &rec
		}
	}
	return nil
}
