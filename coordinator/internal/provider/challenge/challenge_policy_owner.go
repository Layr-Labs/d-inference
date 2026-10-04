package challenge

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Configuration struct {
	Interval           time.Duration
	Skip               bool
	MinProviderVersion string
}

func (c *Configuration) BelowMinProviderVersion(version string) bool {
	return c.MinProviderVersion != "" && (version == "" || releases.SemverLess(version, c.MinProviderVersion))
}

type PolicyDependencies struct {
	Registry        *registry.Registry
	Releases        *releases.Owner
	Observation     *observation.Owner
	Logger          *slog.Logger
	Configuration   *Configuration
	SendTrustStatus func(*registry.Provider, registry.TrustLevel, string, string)
}

// challengePolicy owns runtime/version gates and challenge failure escalation.
type Policy struct {
	registry          *registry.Registry
	releases          *releases.Owner
	observation       *observation.Owner
	logger            *slog.Logger
	challengeSettings *Configuration
	sendTrustStatus   func(*registry.Provider, registry.TrustLevel, string, string)
}

func NewPolicy(d PolicyDependencies) *Policy {
	return &Policy{
		registry: d.Registry, releases: d.Releases, observation: d.Observation, logger: d.Logger,
		challengeSettings: d.Configuration, sendTrustStatus: d.SendTrustStatus,
	}
}
