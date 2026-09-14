package registry

import "time"

// These integration-fixture constants retain the original policy values.
// Production policy and private-state unit tests live in faultstate.
const (
	envBudgetClamp = "EIGENINFERENCE_BUDGET_CLAMP"
)

const (
	defaultBudgetClampTTL = 5 * time.Minute
)

const (
	defaultCapacityCooldownThreshold = 5
	defaultCapacityCooldownWindow    = 60 * time.Second
	defaultCapacityCooldownTTL       = 120 * time.Second
	defaultCapacityCooldownMaxTTL    = 10 * time.Minute
)

const (
	envCapacityRatePenaltyMs = "EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS"
)

const (
	defaultCapacityRatePenaltyMs = 15_000.0

	capacityRateThreshold = 0.25

	capacityRateMinSample = 8
)

const dispatchLoadCooldownTTL = 2 * time.Minute

const (
	inferenceErrorThreshold = 2

	inferenceErrorCooldownTTL = 5 * time.Minute
)

const gateRelockMaxRetries = 4

const gateIdleGrace = 10 * time.Minute

const (
	healthEjectionConsecTrip = 8

	healthEjectionMinSample = 15

	healthEjectionCapacityConsecTrip = 10

	healthEjectionBaseCooldown = 60 * time.Second
	healthEjectionMaxCooldown  = 10 * time.Minute
)

const (
	providerBreakerConsecTrip = 5

	providerBreakerWindow = 120 * time.Second

	providerBreakerBaseCooldown = 60 * time.Second

	providerBreakerMaxCooldown = 5 * time.Minute
)

const identityVersionResetMinInterval = 10 * time.Minute
