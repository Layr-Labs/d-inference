package payoutrecovery

import (
	"time"
)

const (
	// stripeReconcileInterval is how often the reconciler sweeps.
	StripeReconcileInterval = 1 * time.Hour

	// stripeStuckThreshold is how long a withdrawal may sit in "transferred"
	// before it is considered stuck. The normal happy path is: transfer →
	// (up to 24h availability delay on recipient accounts) → daily sweep →
	// bank rail. 48h covers all of that with margin.
	StripeStuckThreshold = 48 * time.Hour

	// stripeReconcileBatch bounds how many stuck rows one sweep inspects.
	stripeReconcileBatch = 200
)
