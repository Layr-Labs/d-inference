package store

import (
	"net/mail"
	"strings"
	"time"
)

const (
	providerNotificationTargetLimit    = 1000
	providerNotificationTargetLookback = 30 * 24 * time.Hour
	maxProviderNotificationReasonKeys  = 7
)

type providerNotificationKey struct {
	ProviderID string
	ReasonKey  ProviderNotificationReasonKey
}

const (
	ProviderNotificationReasonOffline           ProviderNotificationReasonKey = "offline"
	ProviderNotificationReasonVersionBelowMin   ProviderNotificationReasonKey = "version_below_min"
	ProviderNotificationReasonRuntimeUnverified ProviderNotificationReasonKey = "runtime_unverified"
	ProviderNotificationReasonThermalCritical   ProviderNotificationReasonKey = "thermal_critical"
	ProviderNotificationReasonChallengeStale    ProviderNotificationReasonKey = "challenge_stale"
	ProviderNotificationReasonUntrusted         ProviderNotificationReasonKey = "untrusted"
	ProviderNotificationReasonTrustBelowMinimum ProviderNotificationReasonKey = "trust_below_minimum"
)

func (k ProviderNotificationReasonKey) Valid() bool {
	switch k {
	case ProviderNotificationReasonOffline,
		ProviderNotificationReasonVersionBelowMin,
		ProviderNotificationReasonRuntimeUnverified,
		ProviderNotificationReasonThermalCritical,
		ProviderNotificationReasonChallengeStale,
		ProviderNotificationReasonUntrusted,
		ProviderNotificationReasonTrustBelowMinimum:
		return true
	}
	return false
}

func (k ProviderNotificationReasonKey) DBValue() (string, bool) {
	if !k.Valid() {
		return "", false
	}
	return string(k), true
}

type ProviderNotificationDueSet map[ProviderNotificationCheck]struct{}

func (s ProviderNotificationDueSet) Contains(check ProviderNotificationCheck) bool {
	_, ok := s[check]
	return ok
}

func ProviderNotificationStableKey(rec ProviderRecord) string {
	if rec.SerialNumber != "" {
		return "serial:" + rec.SerialNumber
	}
	if rec.SEPublicKey != "" {
		return "sekey:" + rec.SEPublicKey
	}
	return "provider:" + rec.ID
}

func normalizeNotificationEmail(email string) (string, bool) {
	email, ok := trimmedNonEmpty(email)
	if !ok {
		return "", false
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email {
		return "", false
	}
	return addr.Address, true
}

func (check ProviderNotificationCheck) Normalized() (ProviderNotificationCheck, bool) {
	var ok bool
	check.ProviderID, ok = trimmedNonEmpty(check.ProviderID)
	if !ok {
		return ProviderNotificationCheck{}, false
	}
	check.AccountID, ok = trimmedNonEmpty(check.AccountID)
	if !ok {
		return ProviderNotificationCheck{}, false
	}
	check.ReasonKey = ProviderNotificationReasonKey(strings.TrimSpace(string(check.ReasonKey)))
	if !check.ReasonKey.Valid() {
		return ProviderNotificationCheck{}, false
	}
	return check, true
}

func (check ProviderNotificationCheck) DBValues() (providerID string, accountID string, reasonKey string, ok bool) {
	check, ok = check.Normalized()
	if !ok {
		return "", "", "", false
	}
	reasonKey, ok = check.ReasonKey.DBValue()
	if !ok {
		return "", "", "", false
	}
	return check.ProviderID, check.AccountID, reasonKey, true
}

func trimmedNonEmpty(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", false
	}
	return s, true
}

func compactProviderNotificationChecks(checks []ProviderNotificationCheck) []ProviderNotificationCheck {
	out := make([]ProviderNotificationCheck, 0, len(checks))
	seen := make(map[ProviderNotificationCheck]struct{}, len(checks))
	for _, check := range checks {
		check, ok := check.Normalized()
		if !ok {
			continue
		}
		if _, ok := seen[check]; ok {
			continue
		}
		seen[check] = struct{}{}
		out = append(out, check)
	}
	return out
}
