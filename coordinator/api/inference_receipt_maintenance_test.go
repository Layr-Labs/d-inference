package api

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInferenceReceiptMaintenanceInterruptsStaleAndPrunesExpired(t *testing.T) {
	st := store.NewMemory(store.Config{})
	s := &Server{store: st, logger: slog.Default()}
	now := time.Now().UTC().Truncate(time.Microsecond)

	stale := store.InferenceReceiptRecord{
		JobID: "stale-pending-receipt", Nonce: apiTestReceiptNonceWithByte(1), State: store.InferenceReceiptPending,
		CreatedAt: now.Add(-25 * time.Hour), UpdatedAt: now.Add(-25 * time.Hour), ExpiresAt: now.Add(24 * time.Hour),
	}
	recent := store.InferenceReceiptRecord{
		JobID: "recent-pending-receipt", Nonce: apiTestReceiptNonceWithByte(2), State: store.InferenceReceiptPending,
		CreatedAt: now.Add(-time.Hour), UpdatedAt: now.Add(-time.Hour), ExpiresAt: now.Add(24 * time.Hour),
	}
	expired := store.InferenceReceiptRecord{
		JobID: "expired-receipt", Nonce: apiTestReceiptNonceWithByte(3), ReceiptHash: "expired-hash", State: store.InferenceReceiptCompleted,
		Envelope: []byte(`{"receipt":"expired"}`), CreatedAt: now.Add(-48 * time.Hour), UpdatedAt: now.Add(-48 * time.Hour), ExpiresAt: now.Add(-time.Hour),
	}
	for _, record := range []store.InferenceReceiptRecord{stale, recent, expired} {
		if err := st.CreateInferenceReceipt(context.Background(), record); err != nil {
			t.Fatalf("CreateInferenceReceipt(%s): %v", record.JobID, err)
		}
	}

	s.maintainInferenceReceiptsOnce(context.Background(), now)

	gotStale, err := st.GetInferenceReceiptByJobID(context.Background(), stale.JobID)
	if err != nil || gotStale.State != store.InferenceReceiptInterrupted || !gotStale.UpdatedAt.Equal(now) {
		t.Fatalf("stale receipt = (%+v, %v), want interrupted at maintenance time", gotStale, err)
	}
	gotRecent, err := st.GetInferenceReceiptByJobID(context.Background(), recent.JobID)
	if err != nil || gotRecent.State != store.InferenceReceiptPending {
		t.Fatalf("recent receipt = (%+v, %v), want pending", gotRecent, err)
	}
	if _, err := st.GetInferenceReceiptByJobID(context.Background(), expired.JobID); err != store.ErrNotFound {
		t.Fatalf("expired receipt lookup error = %v, want ErrNotFound", err)
	}
}
