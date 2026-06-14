package store

import (
	"net/mail"
	"strings"
	"time"
)

const (
	providerNotificationTargetLimit    = 1000
	providerNotificationTargetLookback = 30 * 24 * time.Hour
)

type providerNotificationKey struct {
	ProviderID string
	ReasonKey  string
}

func providerNotificationStableKey(rec ProviderRecord) string {
	if rec.SerialNumber != "" {
		return "serial:" + rec.SerialNumber
	}
	if rec.SEPublicKey != "" {
		return "sekey:" + rec.SEPublicKey
	}
	return "provider:" + rec.ID
}

func normalizeNotificationEmail(email string) (string, bool) {
	email = strings.TrimSpace(email)
	if email == "" {
		return "", false
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email {
		return "", false
	}
	return addr.Address, true
}

func compactProviderNotificationChecks(checks []ProviderNotificationCheck) []ProviderNotificationCheck {
	out := make([]ProviderNotificationCheck, 0, len(checks))
	seen := make(map[ProviderNotificationCheck]bool, len(checks))
	for _, check := range checks {
		check.ProviderID = strings.TrimSpace(check.ProviderID)
		check.AccountID = strings.TrimSpace(check.AccountID)
		check.ReasonKey = strings.TrimSpace(check.ReasonKey)
		if check.ProviderID == "" || check.AccountID == "" || check.ReasonKey == "" || seen[check] {
			continue
		}
		seen[check] = true
		out = append(out, check)
	}
	return out
}
