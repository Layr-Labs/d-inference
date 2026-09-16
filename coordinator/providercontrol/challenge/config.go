package challenge

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
)

// These defaults retain the provider protocol's existing challenge cadence.
const (
	DefaultInterval                       = 5 * time.Minute
	ResponseTimeout                       = codeidentity.ChallengeResponseTimeout
	MaxConsecutiveTimeoutsBeforeReconnect = 6
)
