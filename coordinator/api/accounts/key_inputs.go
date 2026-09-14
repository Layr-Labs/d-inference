package accounts

import (
	"encoding/json"
	"math"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// createAPIKeyRequest is the POST /v1/keys (and rotate inherit) body. Money is
// supplied in USD; the wire never sees the secret after the create response.
type createAPIKeyRequest struct {
	Name          string     `json:"name"`
	LimitUSD      *float64   `json:"limit_usd"`
	LimitReset    string     `json:"limit_reset"`
	RPMLimit      *int64     `json:"rpm_limit"`
	ITPMLimit     *int64     `json:"itpm_limit"`
	OTPMLimit     *int64     `json:"otpm_limit"`
	AllowedModels []string   `json:"allowed_models"`
	SelfRouteOnly bool       `json:"self_route_only"`
	ExpiresAt     *time.Time `json:"expires_at"`
}

// usdToMicro converts a USD dollar amount to micro-USD (rounded).
func usdToMicro(usd float64) int64 { return int64(math.Round(usd * 1_000_000)) }

// microToUSD converts micro-USD to a USD float.
func microToUSD(micro int64) float64 { return float64(micro) / 1_000_000 }

// validateKeyLimitInputs sanity-checks user-supplied limit values. Returns a
// human-readable error string (empty when valid).
func validateKeyLimitInputs(reset string, limitUSD *float64, rpm, itpm, otpm *int64, expiresAt *time.Time) string {
	switch reset {
	case "", store.KeyResetNone, store.KeyResetDaily, store.KeyResetWeekly, store.KeyResetMonthly:
	default:
		return "limit_reset must be one of: none, daily, weekly, monthly"
	}
	if limitUSD != nil && *limitUSD < 0 {
		return "limit_usd must be >= 0"
	}
	if rpm != nil && *rpm < 0 {
		return "rpm_limit must be >= 0"
	}
	if itpm != nil && *itpm < 0 {
		return "itpm_limit must be >= 0"
	}
	if otpm != nil && *otpm < 0 {
		return "otpm_limit must be >= 0"
	}
	if expiresAt != nil && !expiresAt.IsZero() && expiresAt.Before(time.Now()) {
		return "expires_at must be in the future"
	}
	return ""
}

// applyKeyPatch merges a presence-aware PATCH body into an existing key record.
// Returns a human-readable error string on invalid input (empty when ok).
func applyKeyPatch(k *store.APIKey, patch map[string]json.RawMessage) string {
	if raw, ok := patch["name"]; ok {
		var name string
		if err := json.Unmarshal(raw, &name); err != nil {
			return "invalid value for name"
		}
		k.Name = strings.TrimSpace(name)
	}
	if raw, ok := patch["disabled"]; ok {
		var disabled bool
		if err := json.Unmarshal(raw, &disabled); err != nil {
			return "invalid value for disabled"
		}
		k.Disabled = disabled
	}
	if raw, ok := patch["limit_reset"]; ok {
		var reset string
		if err := json.Unmarshal(raw, &reset); err != nil {
			return "invalid value for limit_reset"
		}
		k.LimitReset = store.NormalizeResetWindow(reset)
	}
	if raw, ok := patch["limit_usd"]; ok {
		if string(raw) == "null" {
			k.LimitMicroUSD = nil
		} else {
			var usd float64
			if err := json.Unmarshal(raw, &usd); err != nil {
				return "invalid value for limit_usd"
			}
			if usd < 0 {
				return "limit_usd must be >= 0"
			}
			m := usdToMicro(usd)
			k.LimitMicroUSD = &m
		}
	}
	if raw, ok := patch["allowed_models"]; ok {
		if string(raw) == "null" {
			k.AllowedModels = nil
		} else {
			var models []string
			if err := json.Unmarshal(raw, &models); err != nil {
				return "invalid value for allowed_models"
			}
			k.AllowedModels = models
		}
	}
	if raw, ok := patch["self_route_only"]; ok {
		var v bool
		if err := json.Unmarshal(raw, &v); err != nil {
			return "invalid value for self_route_only"
		}
		k.SelfRouteOnly = v
	}
	for field, dst := range map[string]**int64{
		"rpm_limit":  &k.RPMLimit,
		"itpm_limit": &k.ITPMLimit,
		"otpm_limit": &k.OTPMLimit,
	} {
		if raw, ok := patch[field]; ok {
			if string(raw) == "null" {
				*dst = nil
			} else {
				var v int64
				if err := json.Unmarshal(raw, &v); err != nil {
					return "invalid value for " + field
				}
				*dst = &v
			}
		}
	}
	if raw, ok := patch["expires_at"]; ok {
		if string(raw) == "null" {
			k.ExpiresAt = nil
		} else {
			var t time.Time
			if err := json.Unmarshal(raw, &t); err != nil {
				return "invalid value for expires_at (use RFC 3339)"
			}
			k.ExpiresAt = &t
		}
	}
	return ""
}
