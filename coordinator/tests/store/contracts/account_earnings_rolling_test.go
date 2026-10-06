package store_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestGetReputationsBatch: one lookup returns every known ID and skips the
// unknown ones; an empty ID list makes no query.
func TestGetReputationsBatch(t *testing.T) {
	ctx := context.Background()
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ids := make([]string, 0, 21)
			for i := range 20 {
				id := uniqueID(fmt.Sprintf("rep-%02d", i))
				ids = append(ids, id)
				// provider_reputation references providers(id).
				if err := st.UpsertProvider(ctx, store.ProviderRecord{
					ID: id, Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "mlx-swift",
				}); err != nil {
					t.Fatalf("upsert provider: %v", err)
				}
				if err := st.UpsertReputation(ctx, id, store.ReputationRecord{
					TotalJobs: 10 + i, SuccessfulJobs: 9 + i, FailedJobs: 1,
					TotalUptimeSeconds: int64(100 * i), AvgResponseTimeMs: int64(50 + i),
					ChallengesPassed: i, ChallengesFailed: 0,
				}); err != nil {
					t.Fatalf("upsert reputation: %v", err)
				}
			}
			ids = append(ids, uniqueID("rep-unknown"))

			reps, err := st.GetReputations(ctx, ids)
			if err != nil {
				t.Fatalf("GetReputations: %v", err)
			}
			if len(reps) != 20 {
				t.Fatalf("reputations = %d, want 20 (unknown id absent)", len(reps))
			}
			for i, id := range ids[:20] {
				rep := reps[id]
				if rep == nil {
					t.Fatalf("missing reputation for %s", id)
				}
				single, err := st.GetReputation(ctx, id)
				if err != nil {
					t.Fatalf("GetReputation: %v", err)
				}
				if *rep != *single || rep.TotalJobs != 10+i {
					t.Fatalf("batch %+v != single %+v for %s", *rep, *single, id)
				}
			}
			if _, ok := reps[ids[20]]; ok {
				t.Fatal("unknown id returned a reputation")
			}

			empty, err := st.GetReputations(ctx, nil)
			if err != nil || len(empty) != 0 {
				t.Fatalf("empty lookup = %v, %v; want empty map, nil", empty, err)
			}
		})
	}
}
