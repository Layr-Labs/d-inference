package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
)

func configureProviderTrust(ctx context.Context, srv *api.Server, cfg mdm.Config, logger *slog.Logger) {
	// Configure MDM client for provider security verification.
	mdmCfg := cfg
	if mdmCfg.URL != "" {
		mdmClient := mdm.NewClient(mdmCfg.URL, mdmCfg.APIKey, logger)

		mdmClient.SetOnMDA(srv.ApplyLateMDA)

		// Register callbacks for responses that arrive after the synchronous wait.
		// The server accepts them only for the exact current scheduler command
		// binding after the connection's phase-1 challenge has settled.
		mdmClient.SetOnLateSecurityInfo(srv.ApplyLateSecurityInfo)

		srv.SetMDMClient(mdmClient)
		srv.StartMDMScheduler()
		// Optional shared secret for the MicroMDM webhook. Defense-in-depth on
		// top of the mandatory solicited-command (CommandUUID) gate: configure
		// MicroMDM's command-webhook-url with ?token=<secret> and set this to
		// the same value to reject any caller that lacks it.
		if webhookSecret := os.Getenv("EIGENINFERENCE_MDM_WEBHOOK_SECRET"); webhookSecret != "" {
			srv.SetMDMWebhookSecret(webhookSecret)
			logger.Info("MDM webhook shared-secret auth enabled")
		} else {
			// The solicited-command (CommandUUID) gate still protects the
			// webhook, but the shared secret is the recommended extra layer.
			// Warn so a misconfigured deployment is visible at startup.
			logger.Warn("EIGENINFERENCE_MDM_WEBHOOK_SECRET not set — MDM webhook relies solely on the CommandUUID gate; set it + keep MicroMDM bound to localhost for defense in depth")
		}
		logger.Info("MDM verification enabled", "url", mdmCfg.URL)
	}

	// Optional profile signing: when a code-signing identity (e.g. Developer ID
	// Application .p12) is supplied via PROFILE_SIGNING_P12_B64/_PATH (+ _PASSWORD),
	// CMS-sign the /v1/enroll .mobileconfig. Misconfig degrades to unsigned.
	if signer := profilesign.LoadFromEnv(logger); signer != nil {
		srv.SetProfileSigner(signer)
	} else {
		logger.Info("configuration-profile signing not configured — serving unsigned enrollment profiles")
	}

	// Optional APNs code-identity attestation (v0.6.0). When the APNs auth key
	// (.p8) + key/team IDs are supplied, the coordinator pushes an encrypted
	// code-identity challenge to each provider over its WebSocket. Configuring the
	// attestor is SAFE on its own: enforcement (derouting un-attested providers)
	// only begins once APNS_ENFORCE_AFTER (RFC3339) has passed, so the fleet has a
	// grace window to update to 0.6.0 and attest. Absent config leaves it disabled.
	if attestor := loadAPNsAttestor(logger); attestor != nil {
		srv.SetCodeAttestor(attestor)
		// W5 Fix 2 (2b): seed the code-identity reuse cache from the store (and
		// wire write-through) so a blue-green deploy / restart doesn't wipe it and
		// re-push the whole fleet against Apple's ~3/hour/device budget. Durable in
		// prod (Postgres store; see the store selection above); a no-op only under
		// the in-memory store fallback.
		srv.SeedCodeAttestCache(ctx)
		deadline, err := parseAPNsEnforceAfter()
		if err != nil {
			// A non-empty but malformed APNS_ENFORCE_AFTER is an operator error on a
			// security-critical knob; falling back to grace would silently keep
			// un-attested providers routable forever. Fail startup so a typo'd
			// deadline is caught at deploy, not discovered after a security gap.
			logger.Error("refusing to start: APNS_ENFORCE_AFTER is set but invalid (fix it, or unset it for grace mode)",
				"value", os.Getenv("APNS_ENFORCE_AFTER"), "error", err)
			os.Exit(1)
		}
		srv.SetCodeAttestationDeadline(deadline)
		switch {
		case deadline.IsZero():
			logger.Info("APNs code-identity attestation configured in GRACE mode — providers are challenged and measured, but un-attested providers still route (set APNS_ENFORCE_AFTER to begin enforcement)")
		case time.Now().Before(deadline):
			logger.Info("APNs code-identity attestation configured — GRACE until the enforcement deadline, then mandatory",
				"enforce_after", deadline.Format(time.RFC3339))
		default:
			logger.Info("APNs code-identity attestation ENFORCED — un-attested providers are not routed",
				"enforce_after", deadline.Format(time.RFC3339))
		}
	} else {
		logger.Info("APNs code-identity attestation not configured — providers route without code-identity proof")
	}

	// Seed durable trust reuse only after the fsync-backed hard-untrust journal is
	// available and replayed. A pending or malformed journal must block startup;
	// accepting providers before replay could resurrect a stale hardware row.
	if err := srv.SeedTrustReuseCache(ctx); err != nil {
		logger.Error("refusing to start: trust-reuse revocation journal is not safe",
			"health_reason", "trust_reuse_revocation_journal_unavailable",
			"error", err,
		)
		os.Exit(1)
	}
}

// parseAPNsEnforceAfter reads APNS_ENFORCE_AFTER (RFC3339) — the instant at which
// code-identity attestation becomes mandatory for routing. Empty/unset returns the
// zero time, which keeps the coordinator in grace/observe mode indefinitely (the
// safe default: configuring APNs secrets never deroutes the fleet). A NON-EMPTY but
// malformed value returns an error so the caller fails startup — silently falling
// back to grace there would be a hidden enforcement downgrade on a typo.
func parseAPNsEnforceAfter() (time.Time, error) {
	raw := strings.TrimSpace(os.Getenv("APNS_ENFORCE_AFTER"))
	if raw == "" {
		// Unset is intentional: grace/observe is the safe default. Only a
		// non-empty-but-malformed value is an error (handled below).
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("APNS_ENFORCE_AFTER %q is not valid RFC3339: %w", raw, err)
	}
	return t, nil
}

// loadAPNsAttestor builds the production APNs code-identity attestor from the
// environment, or returns nil (feature disabled) when unconfigured. Required:
// APNS_KEY_ID, APNS_TEAM_ID, and the .p8 auth key via APNS_AUTH_KEY_P8_B64
// (base64 of the PEM) or APNS_AUTH_KEY_P8_PATH. Optional: APNS_TOPIC
// (default io.darkbloom.provider), APNS_MODE ("background" default | "alert").
// The .p8 is a secret — inject via KMS, never commit it.
func loadAPNsAttestor(logger *slog.Logger) *apns.APNsPushAttestor {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	if keyID == "" || teamID == "" {
		return nil
	}

	var pemBytes []byte
	if b64 := os.Getenv("APNS_AUTH_KEY_P8_B64"); b64 != "" {
		dec, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			logger.Error("APNS_AUTH_KEY_P8_B64 is not valid base64 — APNs attestation disabled", "error", err)
			return nil
		}
		pemBytes = dec
	} else if path := os.Getenv("APNS_AUTH_KEY_P8_PATH"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			logger.Error("failed to read APNS_AUTH_KEY_P8_PATH — APNs attestation disabled", "path", path, "error", err)
			return nil
		}
		pemBytes = b
	} else {
		logger.Warn("APNS_KEY_ID/APNS_TEAM_ID set but no .p8 (APNS_AUTH_KEY_P8_B64 or _PATH) — APNs attestation disabled")
		return nil
	}

	topic := os.Getenv("APNS_TOPIC")
	if topic == "" {
		topic = "io.darkbloom.provider"
	}
	mode := apns.ModeBackground
	if os.Getenv("APNS_MODE") == "alert" {
		mode = apns.ModeAlert
	}

	attestor, err := apns.NewAPNsPushAttestor(apns.Config{
		TeamID:     teamID,
		KeyID:      keyID,
		Topic:      topic,
		AuthKeyPEM: pemBytes,
		Mode:       mode,
	})
	if err != nil {
		logger.Error("failed to construct APNs attestor — attestation disabled", "error", err)
		return nil
	}
	return attestor
}
