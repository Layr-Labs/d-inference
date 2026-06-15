package api

// Apple Managed Device Attestation (MDA) verification — issue #302.
//
// The MDA is the one SIP signal a SIP-off root owner cannot forge: the SEP
// copies SIP / Secure-Boot state from the LocalPolicy into a cert signed by
// Apple's Enterprise Attestation Root CA. This module obtains that cert
// (MDM DeviceInformation → DevicePropertiesAttestation), verifies it, and
// distills it into the per-connection routing verdict (MDASIPVerified):
//
//   - the request carries an epoch-rotating, seed-keyed nonce bound to the
//     provider's SE public key (attestation.MDAEpochNonce) — Apple embeds it
//     verbatim as the cert's FreshnessCode, so a verified cert is provably
//     minted for THIS coordinator, THIS device+key, within the last few epochs;
//   - the SEP-signed SIP and Secure-Boot values must read fully-on
//     ("csr == 0" and "Full Security");
//   - the verdict expires by mint age (attestation.MDAMaxCertAge) at the
//     routing chokepoint, and a periodic re-check (mdaRecheckInterval) keeps a
//     long-lived connection's cert rotating across epochs.
//
// Failure taxonomy: Apple-signed violations (forged chain, serial mismatch,
// SIP-off, non-Full-Security boot) are DEFINITIVE — they untrust the provider
// once enforcement is on (serial mismatch unconditionally, as before). Missing
// or stale responses (MDM hiccup, Apple rate-limit cached certs, timeouts) are
// TRANSIENT — the provider simply lacks a fresh verdict until a later round
// succeeds; under enforcement that means "not routed", never "untrusted".

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// randomMDANonceSeed generates the per-boot fallback seed used when no stable
// seed is configured. Good enough for grace-mode measurement; enforcement
// requires the env-provided stable seed (a per-boot seed would invalidate all
// outstanding nonces on every restart, and Apple's rate limit blocks re-mints
// for up to a week — a fail-closed window).
func randomMDANonceSeed(logger *slog.Logger) []byte {
	seed := make([]byte, 32)
	if _, err := rand.Read(seed); err != nil {
		// Without entropy the process has bigger problems; fail loudly.
		panic(fmt.Sprintf("mda: cannot generate fallback nonce seed: %v", err))
	}
	logger.Info("MDA nonce seed: using a random per-boot seed (set EIGENINFERENCE_MDA_NONCE_SEED for a stable one before enforcement)")
	return seed
}

// mdaRecheckInterval is how often a connected provider's MDA is re-requested.
// Most rounds return Apple's cached cert (cheap: device↔MDM only); a fresh
// mint happens at most once per Apple's ~7-day rate limit, which is exactly
// once per nonce epoch — keeping every connected provider's cert within the
// accepted epoch window.
const mdaRecheckInterval = 12 * time.Hour

// mdaEvaluation is the distilled verdict over a parsed, chain-checked MDA.
type mdaEvaluation struct {
	SIPVerified bool                     // routing gate verdict: fresh + bound + SIP-on + Full-Security
	SEKeyBound  bool                     // FreshnessCode matches a nonce derived from this SE key
	Freshness   attestation.MDAFreshness // fresh epoch nonce / legacy constant / unrecognized
	Definitive  bool                     // an Apple-signed violation (vs a transient/stale response)
	Reason      string                   // stable telemetry tag, "ok" on success
}

// evaluateMDA distills a verified MDA result into the routing verdict. Pure —
// all clock and identity inputs are parameters — so the full matrix is unit-
// testable without an MDM round-trip.
func evaluateMDA(mdaResult *attestation.MDAResult, attestSerial, sePublicKey string, nonceSeed []byte, now time.Time) mdaEvaluation {
	eval := mdaEvaluation{
		Freshness: attestation.ClassifyMDAFreshness(mdaResult.FreshnessCode, nonceSeed, now, sePublicKey),
	}
	eval.SEKeyBound = eval.Freshness != attestation.MDAFreshnessNone

	switch {
	case !mdaResult.Valid:
		// The chain does not verify to Apple's Enterprise Attestation Root CA.
		eval.Definitive = true
		eval.Reason = "chain_invalid"
	case mdaResult.DeviceSerial == "":
		// A routable MDA verdict must identify the Apple-attested device. Without
		// the cert serial, the coordinator cannot bind Apple's security properties
		// to the provider's registered hardware identity.
		eval.Definitive = true
		eval.Reason = "serial_missing"
	case mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestSerial:
		// Apple attested a DIFFERENT device than the one this connection claims
		// to be — impersonation, never a transient state.
		eval.Definitive = true
		eval.Reason = "serial_mismatch"
	case !mdaResult.SIPEnabled:
		// SEP-signed proof the device ran with SIP weakened at mint time. Even a
		// cached (stale-nonce) cert is an Apple-signed SIP-off sighting.
		eval.Definitive = true
		eval.Reason = "sip_disabled"
	case !mdaResult.SecureBootEnabled:
		eval.Definitive = true
		eval.Reason = "not_full_security"
	// NOTE: mdaResult.ThirdPartyKexts (.13.3) is parsed but intentionally not a
	// separate gate. On Apple silicon, loading a third-party kext requires
	// lowering the boot policy to Reduced Security; a "Full Security" boot
	// (required just above) cannot have third-party kexts enabled, so the
	// SecureBootEnabled check already excludes the kext-in-kernel memory-read
	// vector. The field is retained for the attestation display + telemetry.
	case eval.Freshness == attestation.MDAFreshnessLegacy:
		// Pre-#302 constant nonce: key-bound but replayable forever — exactly
		// the migration state of certs minted before this deploy. Re-mints with
		// the epoch nonce on a later round (transient).
		eval.Reason = "legacy_nonce"
	case eval.Freshness == attestation.MDAFreshnessNone:
		// Not a nonce we sent in the accepted epochs: a cached cert from before
		// a seed rotation, an out-of-window replay, or another context's cert.
		eval.Reason = "nonce_unrecognized"
	case now.Sub(mdaResult.LeafNotBefore) > attestation.MDAMaxCertAge:
		// Backstop — the nonce window normally expires first.
		eval.Reason = "cert_too_old"
	default:
		eval.SIPVerified = true
		eval.Reason = "ok"
	}
	return eval
}

// verifyAppleDeviceAttestation requests a DevicePropertiesAttestation for the
// device, verifies the Apple-signed chain, and applies the distilled verdict
// to the provider (display fields + the MDASIPVerified routing gate). Runs
// once after MDM verification on every connection and again every
// mdaRecheckInterval via the challenge loop.
func (s *Server) verifyAppleDeviceAttestation(ctx context.Context, providerID string, provider *registry.Provider, serialNumber, sePublicKey, udid string) {
	if udid == "" {
		s.logger.Warn("no UDID for MDA verification", "provider_id", providerID)
		return
	}
	now := time.Now()
	provider.SetMDACheckStarted(udid, now)

	// Epoch nonce: rotates every attestation.MDANonceEpochLength, keyed to the
	// coordinator's secret seed and this device's SE public key. Apple embeds
	// the decoded bytes verbatim as the cert's FreshnessCode. A rate-limited
	// device legitimately answers with its cached cert carrying a previous
	// nonce — ClassifyMDAFreshness accepts the last few epochs for that.
	epoch := attestation.MDANonceEpoch(now)
	nonce := attestation.MDAEpochNonce(s.mdaNonceSeed, epoch, sePublicKey)
	seKeyNonce := base64.StdEncoding.EncodeToString(nonce)
	s.logger.Info("requesting Apple Device Attestation (MDA)",
		"provider_id", providerID,
		"udid", udid,
		"nonce_epoch", epoch,
		"nonce_prefix", hex.EncodeToString(nonce[:8])+"...",
		"se_key_bound", sePublicKey != "",
	)

	// Always send the raw plist command so the nonce reaches the device.
	// The structured MicroMDM API doesn't support DeviceAttestationNonce.
	if _, err := s.mdmClient.SendDeviceAttestationCommand(ctx, udid, seKeyNonce); err != nil {
		s.logger.Warn("failed to send DeviceInformation attestation command",
			"provider_id", providerID, "error", err)
		s.ddIncr("attestation.mda_check", []string{"result:send_failed"})
		return
	}

	// Wait for Apple's response (device contacts Apple's servers — may take longer).
	attestResp, err := s.mdmClient.WaitForDeviceAttestation(ctx, udid, 60*time.Second)
	if err != nil {
		s.logger.Warn("DevicePropertiesAttestation response timeout",
			"provider_id", providerID, "error", err)
		s.ddIncr("attestation.mda_check", []string{"result:timeout"})
		return
	}

	mdaResult, err := attestation.VerifyMDADeviceAttestation(attestResp.CertChain)
	if err != nil {
		// Malformed chain bytes out of the MDM webhook — surfaced via telemetry;
		// the provider keeps lacking a fresh verdict until a clean round.
		s.logger.Error("MDA certificate chain parse error",
			"provider_id", providerID, "error", err)
		s.ddIncr("attestation.mda_check", []string{"result:parse_error"})
		return
	}

	s.applyMDAVerdict(providerID, provider, mdaResult, attestResp.CertChain, serialNumber, sePublicKey)
}

// applyMDAVerdict distills a parsed+chain-verified MDA into the routing verdict
// and applies it to the provider. Shared by the synchronous attestation round
// and the late-arriving-cert webhook path so BOTH go through the same
// SIP/Full-Security/freshness gate and the same definitive-violation untrust
// taxonomy — neither may set a verdict the other wouldn't.
func (s *Server) applyMDAVerdict(providerID string, provider *registry.Provider, mdaResult *attestation.MDAResult, certChain [][]byte, serialNumber, sePublicKey string) {
	eval := evaluateMDA(mdaResult, serialNumber, sePublicKey, s.mdaNonceSeed, time.Now())

	// Display fields (MDAVerified, chain, parsed OIDs) track the latest Apple
	// response; MDASIPVerified + MDAMintedAt feed the routing chokepoint. Lock:
	// these fields are read by HTTP handlers and the routing path concurrently.
	provider.Mu().Lock()
	provider.MDAVerified = mdaResult.Valid && eval.Reason != "serial_mismatch"
	provider.MDACertChain = certChain
	provider.MDAResult = mdaResult
	provider.SEKeyBound = eval.SEKeyBound
	provider.MDASIPVerified = eval.SIPVerified
	provider.MDAMintedAt = mdaResult.LeafNotBefore
	provider.Mu().Unlock()

	s.ddIncr("attestation.mda_check", []string{"result:" + eval.Reason, fmt.Sprintf("sip_verified:%t", eval.SIPVerified)})

	if eval.Definitive {
		// Apple-signed violation. Serial mismatch keeps its pre-existing
		// unconditional untrust; the new SIP/boot/chain violations untrust only
		// under enforcement so a decode regression can never brick the fleet
		// during the grace rollout (they still log + count loudly in grace).
		enforced := s.registry.MDAEnforced()
		s.logger.Error("MDA verdict: Apple-signed security violation",
			"provider_id", providerID,
			"reason", eval.Reason,
			"mda_serial", mdaResult.DeviceSerial,
			"boot_state", mdaResult.BootState,
			"enforced", enforced,
		)
		if eval.Reason == "serial_mismatch" || enforced {
			s.registry.MarkUntrusted(providerID)
		}
		return
	}

	if eval.SIPVerified {
		s.logger.Info("MDA verified — Apple-signed SIP-on/Full-Security, SE-key-bound, fresh",
			"provider_id", providerID,
			"mda_serial", mdaResult.DeviceSerial,
			"mda_udid", mdaResult.DeviceUDID,
			"minted_at", mdaResult.LeafNotBefore.Format(time.RFC3339),
		)
		// Newly eligible under the MDA routing gate — drain requests that queued
		// waiting for an MDA-verified provider instead of waiting for the next
		// heartbeat.
		s.registry.DrainQueuedRequestsForProvider(provider)
		return
	}
	// Transient / migration states (legacy nonce, unrecognized nonce, stale
	// cert): no fresh verdict yet — the periodic re-check converges once the
	// device can mint again (≤ one rate-limit window).
	s.logger.Info("MDA response not yet fresh — provider lacks an MDA routing verdict until re-mint",
		"provider_id", providerID,
		"reason", eval.Reason,
		"se_key_bound", eval.SEKeyBound,
		"minted_at", mdaResult.LeafNotBefore.Format(time.RFC3339),
	)
}

// HandleLateMDA applies a late-arriving DevicePropertiesAttestation cert (one
// whose webhook landed after the synchronous 60s wait already timed out) to the
// provider whose attested serial it matches. Routed through applyMDAVerdict so
// a late SIP-off cert is caught and a late SIP-on cert can grant the routing
// verdict — the same gate the synchronous path applies. Wire as the MDM
// SetOnMDA callback.
func (s *Server) HandleLateMDA(udid string, certChain [][]byte) {
	mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
	if err != nil {
		s.logger.Error("late MDA cert parse error", "udid", udid, "error", err)
		return
	}
	if !mdaResult.Valid || mdaResult.DeviceSerial == "" {
		// Can't safely attribute an unverifiable or serial-less cert to a provider.
		s.logger.Warn("late MDA cert not attributable", "udid", udid, "valid", mdaResult.Valid)
		return
	}
	s.applyLateMDAResult(udid, mdaResult, certChain)
}

// applyLateMDAResult attributes an already verified late MDA response to the
// provider it belongs to.
//
// It deliberately does NOT bind by comparing the cert UDID to the webhook UDID:
// on a Mac the cert's .8.9.2 UDID is the Device Provisioning UDID (e.g.
// 00006041-000C28D61A81401C), a DIFFERENT namespace from the MDM-protocol
// Hardware UUID the webhook carries — they never match, so such a check would
// drop every late cert and silently kill the late-recovery path. The device
// binding is instead:
//  1. the webhook is solicited — mdm.Client gates it on the CommandUUID and
//     requires webhook.UDID == the UDID the command was sent to, so the cert
//     arrived from the device we actually challenged; and
//  2. attributeAndApplyMDA → evaluateMDA binds on the Apple-signed serial plus
//     the SE-key-derived epoch nonce — the same proof the synchronous path
//     trusts. (A replayed cert for another device carries that device's serial
//     and a nonce not derived from this connection's SE key, so it neither
//     attributes nor classifies fresh.)
func (s *Server) applyLateMDAResult(udid string, mdaResult *attestation.MDAResult, certChain [][]byte) {
	if mdaResult == nil || !mdaResult.Valid || mdaResult.DeviceSerial == "" {
		s.logger.Warn("late MDA cert not attributable", "udid", udid, "valid", mdaResult != nil && mdaResult.Valid)
		return
	}
	s.attributeAndApplyMDA(mdaResult, certChain)
}

// mdaTarget is a provider whose attested serial matched a late cert, captured
// under the registry read lock for application afterwards.
type mdaTarget struct {
	p      *registry.Provider
	serial string
	seKey  string
}

// attributeAndApplyMDA applies a verified MDA result to every provider whose
// attested serial it matches. Providers are COLLECTED under ForEachProvider's
// registry read lock, then the verdict is applied AFTER that lock is released:
// applyMDAVerdict calls registry write-lock methods (MDAEnforced,
// MarkUntrusted) which would self-deadlock the RWMutex if invoked inside the
// RLock'd callback. This mirrors the fanOutDesiredModels collect-then-act
// convention (registry/model_alias_handlers.go).
func (s *Server) attributeAndApplyMDA(mdaResult *attestation.MDAResult, certChain [][]byte) {
	var targets []mdaTarget
	s.registry.ForEachProvider(func(p *registry.Provider) {
		var serial, seKey string
		p.Mu().Lock()
		if ar := p.AttestationResult; ar != nil {
			serial, seKey = ar.SerialNumber, ar.PublicKey
		}
		p.Mu().Unlock()
		if serial != "" && serial == mdaResult.DeviceSerial {
			targets = append(targets, mdaTarget{p: p, serial: serial, seKey: seKey})
		}
	})
	for _, t := range targets {
		s.applyMDAVerdict(t.p.ID, t.p, mdaResult, certChain, t.serial, t.seKey)
	}
}

// maybeRecheckMDA re-runs MDA verification for a connected provider when the
// periodic interval has elapsed. Called from the challenge loop ticker; the
// 60s MDM wait runs in its own goroutine so the loop never blocks.
func (s *Server) maybeRecheckMDA(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.mdmClient == nil {
		return
	}
	udid, due := provider.MDARecheckDue(mdaRecheckInterval)
	if !due {
		return
	}
	var serial, seKey string
	provider.Mu().Lock()
	if ar := provider.AttestationResult; ar != nil {
		serial, seKey = ar.SerialNumber, ar.PublicKey
	}
	provider.Mu().Unlock()
	saferun.Go(s.logger, "mdaRecheck", func() {
		s.verifyAppleDeviceAttestation(ctx, providerID, provider, serial, seKey, udid)
	})
}
