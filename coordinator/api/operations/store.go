package operations

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the complete read surface for operational record queries.
type Store interface {
	InferenceRouteRecordsSince(time.Time) []store.InferenceRouteRecord
	RejectionRecordsSince(time.Time) []store.RejectionRecord
	RequestProfilesSinceFiltered(time.Time, store.RequestProfileFilter) []store.RequestProfileRecord
	FleetSnapshotsSince(time.Time) []store.FleetSnapshotRow
	RequestOutcomes(context.Context, time.Time, time.Time, int) ([]store.RequestOutcomeRecord, error)
}
