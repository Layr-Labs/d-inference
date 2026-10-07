package warmplan

import (
	"time"
)

// Service-time (E[S]) clamps for the Little's Law target. A near-zero or absurdly
// large per-request rate must not let the demand-to-concurrency conversion produce
// a runaway or zero target.
const (
	WarmPoolMinServiceTime = 500 * time.Millisecond
	WarmPoolMaxServiceTime = 2 * time.Minute
)
