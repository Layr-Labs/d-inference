package challenge

import (
	"time"
)

const (
	// DefaultChallengeInterval is how often the coordinator challenges providers.
	DefaultChallengeInterval = 5 * time.Minute

	// ChallengeResponseTimeout is how long to wait for a challenge response.
	ChallengeResponseTimeout = 30 * time.Second
	// RegistrationAttestationMaxAge bounds replay of a previously valid signed
	// registration claim. Challenge nonces provide ongoing liveness afterward.
	RegistrationAttestationMaxAge = 2 * time.Minute
	// RegistrationAttestationMaxFutureSkew is the corresponding positive clock
	// skew accepted by attestation.CheckTimestamp. Keep the age and future-skew
	// windows equal while that shared validator uses a symmetric bound.
	RegistrationAttestationMaxFutureSkew = RegistrationAttestationMaxAge

	// MaxConsecutiveChallengeTimeoutsBeforeReconnect is the number of consecutive
	// transient challenge timeouts (no response within ChallengeResponseTimeout)
	// after which the coordinator force-closes the provider's WebSocket so it must
	// reconnect and re-register.
	//
	// MarkUntrustedTransient keeps challenging a provider in place so it can
	// self-recover via a later passing challenge — but that only helps if the
	// provider can actually send a response. A provider whose outbound path is
	// wedged keeps heartbeating (so it is never evicted by the stale sweeper)
	// while failing every challenge, leaving it pinned hardware/untrusted forever.
	// Cycling the connection forces a clean re-registration, which is the only way
	// back. Must be > MaxFailedChallenges so a brief blip (sleep/network) still
	// self-recovers without a disconnect.
	MaxConsecutiveChallengeTimeoutsBeforeReconnect = 6
)

// CodeAttestResponseTimeout bounds how long the coordinator will accept a
// provider's WebSocket reply to an APNs code-identity challenge after the push.
// It is no longer a blocking wait (Fix 1): verification happens in the read-loop
// delivery path (HandleCodeAttestationResponse), so this is the acceptance window
// for the pushed nonce. Kept consistent with the APNs apns-expiration window
// (apns.challengeExpirySeconds, Fix 5) — a reply is honored for as long as the
// push could still be delivered. It seeds codeAttestThrottle.challengeValidity.
const CodeAttestResponseTimeout = 300 * time.Second
