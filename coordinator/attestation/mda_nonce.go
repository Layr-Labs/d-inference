package attestation

// MDA freshness nonces (issue #302, Gap 1 — replayable attestations).
//
// The DeviceAttestationNonce we send with the MDM DeviceInformation command
// comes back verbatim as the cert's FreshnessCode, signed by Apple. Previously
// the nonce was the CONSTANT sha256(SE public key): because the SE key persists
// across reboots, a cert captured on a SIP-on boot stayed "fresh" forever, so a
// reboot-to-SIP-off owner could replay it indefinitely.
//
// A fresh random nonce per connection is NOT viable: Apple rate-limits new
// attestations to ~1 per device per 7 days, and a rate-limited device returns
// its CACHED cert carrying the PREVIOUS nonce (documented DeviceAttestationNonce
// behavior). A per-connection nonce would therefore fail closed for up to a week
// after every mint.
//
// Instead the nonce rotates once per epoch (sized to Apple's rate limit) and is
// derived as HMAC-SHA256(seed, epoch ‖ SE pubkey):
//   - the secret seed makes future-epoch nonces unpredictable, so an attacker
//     who is SIP-on today cannot pre-mint certs to replay in later epochs;
//   - the SE pubkey input binds each nonce — and so the Apple-signed cert — to
//     the device's enrolled Secure Enclave key;
//   - the coordinator accepts the current and two previous epochs' nonces,
//     covering Apple's cached-cert behavior across epoch boundaries.
//
// Combined with the routing-time mint-age bound (MDAMaxCertAge, enforced at the
// chokepoint against the leaf's NotBefore), a captured SIP-on cert is replayable
// for at most MDAMaxCertAge after its mint instead of forever.
//
// The seed MUST be stable across coordinator restarts (env-provided): changing
// it invalidates every outstanding nonce, and rate-limited devices cannot mint
// a replacement for up to 7 days — a fail-closed window under enforcement.

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"time"
)

const (
	// MDANonceEpochLength matches Apple's documented DeviceInformation
	// attestation rate limit (one fresh mint per device per 7 days).
	MDANonceEpochLength = 7 * 24 * time.Hour

	// MDANonceAcceptedEpochs is how many consecutive epochs' nonces the
	// coordinator accepts (current + N-1 previous). Three epochs tolerate the
	// cached-cert race at epoch boundaries (a device that minted late in epoch
	// E is rate-limited deep into E+1 and may not re-mint until early E+2).
	MDANonceAcceptedEpochs = 3

	// MDAMaxCertAge bounds how old a verified attestation's mint time
	// (leaf NotBefore) may be at ROUTING time. Sized to the nonce-acceptance
	// window; an attestation older than this stops routing even if periodic
	// re-attestation has stalled.
	MDAMaxCertAge = MDANonceAcceptedEpochs * MDANonceEpochLength
)

// mdaNonceDomain separates this HMAC use from any other use of the same seed.
const mdaNonceDomain = "darkbloom-mda-nonce-v1"

// mdaNonceLen is the byte length of every MDA nonce (HMAC-SHA256 output). Apple
// caps the DeviceAttestationNonce at 32 bytes, which this exactly matches.
const mdaNonceLen = sha256.Size

// MDAFreshness classifies a cert's FreshnessCode against the nonces we accept.
type MDAFreshness int

const (
	// MDAFreshnessNone — the code matches nothing we ever sent for this SE key
	// (replay from another context, a pre-seed-rotation cert, or one older than
	// the accepted epochs).
	MDAFreshnessNone MDAFreshness = iota
	// MDAFreshnessLegacy — the code is the pre-#302 CONSTANT sha256(SE pubkey).
	// It still binds the SE key (the cert was minted for this device+key) but
	// carries no recency: certs with this code exist from before the epoch
	// scheme and are replayable indefinitely, so it never satisfies the gate.
	MDAFreshnessLegacy
	// MDAFreshnessFresh — the code is one of the accepted epoch nonces.
	MDAFreshnessFresh
)

// MDANonceEpoch returns the epoch number for t.
func MDANonceEpoch(t time.Time) uint64 {
	return uint64(t.Unix()) / uint64(MDANonceEpochLength/time.Second)
}

// MDAEpochNonce derives the 32-byte attestation nonce for (seed, epoch, SE key).
func MDAEpochNonce(seed []byte, epoch uint64, sePublicKey string) []byte {
	mac := hmac.New(sha256.New, seed)
	mac.Write([]byte(mdaNonceDomain))
	var e [8]byte
	binary.BigEndian.PutUint64(e[:], epoch)
	mac.Write(e[:])
	mac.Write([]byte(sePublicKey))
	return mac.Sum(nil)
}

// LegacyMDANonce is the pre-#302 constant nonce: sha256 of the base64 SE public
// key string. Recognized only to classify in-flight certs during migration.
func LegacyMDANonce(sePublicKey string) []byte {
	h := sha256.Sum256([]byte(sePublicKey))
	return h[:]
}

// ClassifyMDAFreshness classifies a cert's FreshnessCode for a provider's SE
// key at time now.
func ClassifyMDAFreshness(code, seed []byte, now time.Time, sePublicKey string) MDAFreshness {
	if len(code) == 0 || sePublicKey == "" {
		return MDAFreshnessNone
	}
	epoch := MDANonceEpoch(now)
	for i := uint64(0); i < MDANonceAcceptedEpochs; i++ {
		if epoch < i {
			break // clock near the unix epoch (tests); no earlier epochs exist
		}
		if subtle.ConstantTimeCompare(code, MDAEpochNonce(seed, epoch-i, sePublicKey)) == 1 {
			return MDAFreshnessFresh
		}
	}
	if subtle.ConstantTimeCompare(code, LegacyMDANonce(sePublicKey)) == 1 {
		return MDAFreshnessLegacy
	}
	return MDAFreshnessNone
}
