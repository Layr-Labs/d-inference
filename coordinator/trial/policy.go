// Package trial defines the Bonsai session trial policy without depending on
// HTTP handlers or persistence. Callers must obtain identity from verified auth.
package trial

import (
	"fmt"
	"strings"
)

const (
	DefaultCampaignID       = "bonsai-2-lifetime-v1"
	DefaultTokenLimit int64 = 5_000_000
	BonsaiBuildID           = "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"
	ChatEndpoint            = "/v1/chat/completions"
)

// AuthKind is stamped by authentication middleware only after verification.
// In particular, an absent API key is not evidence of a login session.
type AuthKind string

const (
	AuthSession  AuthKind = "session"
	AuthAPIKey   AuthKind = "api_key"
	AuthAdmin    AuthKind = "admin"
	AuthProvider AuthKind = "provider"
)

// Config describes one persistent allowance campaign. Keep CampaignID stable
// across disable/re-enable and model upgrades to preserve consumed allowances.
// ModelIDs are exact resolved model identities, including approved fallbacks.
// Rates are a launch-time snapshot, not a live ratio linked to Qwen pricing.
type Config struct {
	Enabled    bool
	CampaignID string
	ModelIDs   []string
	TokenLimit int64
	Rates      Rates
}

// DefaultConfig grants nothing until operators verify and configure model IDs
// and actual reference prices. The known raw build is not a public alias.
func DefaultConfig() Config {
	return Config{CampaignID: DefaultCampaignID, TokenLimit: DefaultTokenLimit}
}

// Validate rejects partially configured enabled campaigns. Disabled campaigns
// may retain their identities so matching session traffic can fail unavailable
// instead of accidentally being billed when the campaign is switched off.
func (c Config) Validate() error {
	if !c.Enabled {
		return nil
	}
	if strings.TrimSpace(c.CampaignID) == "" || strings.TrimSpace(c.CampaignID) != c.CampaignID {
		return fmt.Errorf("trial campaign ID must be nonempty without surrounding whitespace")
	}
	if c.TokenLimit <= 0 {
		return fmt.Errorf("trial token limit must be positive")
	}
	if len(c.ModelIDs) == 0 {
		return fmt.Errorf("trial requires an explicit model allowlist")
	}
	seen := make(map[string]bool, len(c.ModelIDs))
	for _, id := range c.ModelIDs {
		if strings.TrimSpace(id) == "" || strings.TrimSpace(id) != id || seen[id] {
			return fmt.Errorf("trial model identities must be nonempty, unique, and exact")
		}
		seen[id] = true
	}
	return c.Rates.Validate()
}

// Matches checks the protected trial scope independently of Enabled. Callers
// must return unavailable for matches when disabled, never fall through to paid
// admission. Recheck this predicate if routing changes the resolved model.
func (c Config) Matches(auth AuthKind, endpoint, resolvedModel string) bool {
	if auth != AuthSession || endpoint != ChatEndpoint || resolvedModel == "" {
		return false
	}
	for _, id := range c.ModelIDs {
		if id == resolvedModel {
			return true
		}
	}
	return false
}
