package verification

import "time"

const (
	// RegistrationMaxAge is also the positive skew accepted by CheckTimestamp.
	RegistrationMaxAge = 2 * time.Minute
	// ReconnectFreshnessVersion first re-signs registration on every reconnect;
	// older registrations cannot carry effective protected-runtime claims.
	ReconnectFreshnessVersion = "0.8.15"

	restoreTimeout = 5 * time.Second
	// RestoreAttempts bounds inline reconnect reads before registration ends.
	RestoreAttempts = 3
	restoreBackoff  = 100 * time.Millisecond
)

// Outcome classifies one scheduler-owned SecurityInfo attempt.
type Outcome int

const (
	Granted   Outcome = iota // hardware trust granted — stop
	Transient                // transport/enrollment incomplete — retry
	Terminal                 // proven posture mismatch — stop
)
