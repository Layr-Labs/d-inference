package trust

import "github.com/eigeninference/d-inference/coordinator/internal/provider/challenge"

type ChallengeTracker = challenge.ChallengeTracker

func NewChallengeTracker() *ChallengeTracker { return challenge.NewChallengeTracker() }

func VersionMetricTag(version string) string { return challenge.VersionMetricTag(version) }

const (
	DefaultChallengeInterval                       = challenge.DefaultChallengeInterval
	ChallengeResponseTimeout                       = challenge.ChallengeResponseTimeout
	RegistrationAttestationMaxAge                  = challenge.RegistrationAttestationMaxAge
	RegistrationAttestationMaxFutureSkew           = challenge.RegistrationAttestationMaxFutureSkew
	MaxConsecutiveChallengeTimeoutsBeforeReconnect = challenge.MaxConsecutiveChallengeTimeoutsBeforeReconnect
	CodeAttestResponseTimeout                      = challenge.CodeAttestResponseTimeout
)
