package main

import (
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func configureReleasePolicy(srv *api.Server, reg *registry.Registry, logger *slog.Logger) {
	// Sync the model catalog to the registry.
	srv.SyncModelCatalog()

	// Server configuration applied from config.ServerConfig during NewServer().

	// Sync known-good provider hashes from active releases in the store. Release
	// inventory is a routing authority; an unreadable inventory must fail startup.
	if err := srv.SyncBinaryHashes(); err != nil {
		logger.Error("refusing to start: release policy inventory is unavailable", "error", err)
		os.Exit(1)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		logger.Error("refusing to start: runtime release inventory is unavailable", "error", err)
		os.Exit(1)
	}
	if hashList := os.Getenv("EIGENINFERENCE_KNOWN_BINARY_HASHES"); hashList != "" {
		hashes := strings.Split(hashList, ",")
		srv.AddKnownBinaryHashes(hashes)
		logger.Info("additional binary hashes from env var", "count", len(hashes))
	}
	// Release-policy routing gate mode. SHADOW (default): application evidence
	// is derived, granted, swept, and counted (release_evidence.outcome metrics
	// + /v1/stats application_evidence_providers) but NEVER blocks routing —
	// identical routing behavior to the pre-release-policy coordinator. ENFORCE:
	// the routing chokepoint requires generation-current evidence. Enforcement
	// must only be enabled after a shadow deployment shows evidence coverage
	// near the connected fleet size (2026-08-31: enforcing an unproven evidence
	// predicate zeroed network capacity twice).
	switch mode := os.Getenv("EIGENINFERENCE_RELEASE_POLICY_MODE"); mode {
	case "enforce":
		// A restarted coordinator boots with an EMPTY provider registry: zero
		// evidence exists until reconnected providers complete their first
		// challenge. Enforcing from the first request would 429 the whole
		// fleet for minutes — so enforcement always waits out a boot grace
		// (default 20m ≈ four challenge cycles) during which routing behaves
		// exactly like shadow while evidence coverage rebuilds.
		// The override is RAISE-ONLY, mirroring DARKBLOOM_ACTIVATION_RESERVE_GB:
		// a shorter grace recreates the empty-registry 429 interval the grace
		// exists to prevent, so values below the default clamp up to it.
		const minEnforceGrace = 20 * time.Minute
		grace := minEnforceGrace
		if v := os.Getenv("EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE"); v != "" {
			if d, err := time.ParseDuration(v); err == nil && d >= minEnforceGrace {
				grace = d
			} else if err == nil {
				logger.Warn("EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE below the 20m minimum; clamping up", "value", v)
			} else {
				logger.Warn("invalid EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE; keeping default 20m", "value", v)
			}
		}
		reg.SetReleasePolicyEnforcement(true)
		reg.SetReleasePolicyEnforceAfter(time.Now().Add(grace))
		logger.Warn("release-policy routing gate ENFORCED via EIGENINFERENCE_RELEASE_POLICY_MODE — providers without current application evidence will not route after the boot grace",
			"boot_grace", grace.String())
	case "", "shadow":
		logger.Info("release-policy routing gate in SHADOW mode (default): evidence tracked and counted, never blocks routing; set EIGENINFERENCE_RELEASE_POLICY_MODE=enforce after coverage is proven")
	default:
		logger.Warn("invalid EIGENINFERENCE_RELEASE_POLICY_MODE; staying in SHADOW mode", "value", mode)
	}
	// v0.6.0: self-reported binaryHash is demoted to drift telemetry by default
	// (APNs code-identity attestation is the real signal). Set this to re-enable
	// the legacy derouting-on-mismatch behavior (rollback only).
	if os.Getenv("EIGENINFERENCE_BINARYHASH_ENFORCE") == "true" {
		srv.SetBinaryHashEnforcement(true)
		logger.Warn("binaryHash enforcement ENABLED via EIGENINFERENCE_BINARYHASH_ENFORCE (legacy; APNs code-identity is the real signal)")
	}
}

func configureRuntimeManifest(srv *api.Server, logger *slog.Logger) {
	// Load runtime template manifest from environment variable (optional override).
	// When configured, providers whose template hashes don't match are excluded from
	// routing (but not disconnected) and receive feedback about mismatches.
	// Python/runtime hashes are deprecated — only template hashes (e.g. mlx_metallib) are checked.
	if templateHashes := os.Getenv("EIGENINFERENCE_KNOWN_TEMPLATE_HASHES"); templateHashes != "" {
		// The manifest is a set per template name: repeating a name
		// (mlx_metallib=<a>,mlx_metallib=<b>) accepts every listed hash.
		manifest := api.NewRuntimeManifest()
		for _, pair := range strings.Split(templateHashes, ",") {
			parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
			if len(parts) == 2 {
				manifest.AddTemplateHash(parts[0], parts[1])
			}
		}
		srv.SetRuntimeManifest(manifest)
		logger.Info("runtime manifest configured from env",
			"template_hashes", len(manifest.TemplateHashes),
		)
	}
}
