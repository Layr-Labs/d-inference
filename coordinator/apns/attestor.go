// Package apns implements the coordinator side of the APNs-based provider
// code-identity attestation (v0.6.0).
//
// The coordinator proves a provider is running our genuine, Apple-provisioned
// binary by pushing an encrypted code-identity challenge — E_K(nonce) — to the
// provider's APNs device token. Only our genuine, team-signed, push-provisioned
// code can RECEIVE that push (Apple's enforcement), and only the genuine
// hardened process can DECRYPT it (the nonce is encrypted to the provider's
// X25519 key K, which lives only in protected process memory). The provider
// returns the decrypted nonce + an SE-key signature over the WebSocket, which
// binds the Apple-gated proof onto that connection. See
// docs/apns-code-attestation-design.md.
//
// This package builds the challenge payload (reusing the existing inference E2E
// encrypt path so the provider's existing decrypt works unchanged) and sends it
// to APNs over HTTP/2 with a token-based (.p8 ES256 JWT) authorization. The
// CodeIdentityAttestor interface is the seam: production uses APNsPushAttestor;
// tests inject a fake that delivers the challenge directly to a simulated
// provider without touching Apple.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// Mode selects the APNs delivery characteristics.
//
//	ModeBackground: apns-push-type=background, apns-priority=5 — silent, subject
//	  to the device's ~2-3/hour background budget (the default; attest once per
//	  connection stays within budget).
//	ModeAlert: apns-push-type=alert, apns-priority=10 — not background-throttled,
//	  reliable & prompt, at the cost of a benign visible notification. The
//	  fallback if background delivery proves unreliable on the fleet.
type Mode string

const (
	ModeBackground Mode = "background"
	ModeAlert      Mode = "alert"

	prodHost = "https://api.push.apple.com"
	devHost  = "https://api.sandbox.push.apple.com"

	// jwtMaxAge bounds JWT reuse. APNs rejects a JWT regenerated <20min apart
	// (TooManyProviderTokenUpdates) and requires refresh <60min; ~50min is the
	// safe middle. One JWT is reused across all hosts/sends.
	jwtMaxAge = 50 * time.Minute

	// challengeExpirySeconds is the apns-expiration window. Short so a stale
	// challenge is discarded rather than delivered late, but long enough to
	// tolerate brief device-side delay.
	challengeExpirySeconds = 60
)

// CodeIdentityAttestor sends a code-identity challenge to a provider's device.
// The implementation builds E_K(nonceB64) (encrypted to providerPubKeyB64) and
// delivers it; the provider answers over the WebSocket (handled elsewhere).
//
// This is the seam the design calls for: routing/key-release depend only on this
// interface, so a future AppAttestAttestor (if Apple ever ships it) drops in, and
// tests inject a fake.
type CodeIdentityAttestor interface {
	SendCodeChallenge(ctx context.Context, deviceToken, environment, providerPubKeyB64, nonceB64 string) error
}

// APNsPushAttestor is the production CodeIdentityAttestor: it pushes E_K(nonce)
// to APNs over HTTP/2 using a .p8 ES256 JWT.
type APNsPushAttestor struct {
	teamID string
	keyID  string
	topic  string
	mode   Mode
	key    *ecdsa.PrivateKey
	client *http.Client

	// hostOverride, when non-empty, replaces both prod and dev hosts (tests).
	hostOverride string

	jwtMu     sync.Mutex
	cachedJWT string
	jwtIssued time.Time

	backoffMu    sync.Mutex
	backoffUntil map[string]time.Time // per device token (honor Retry-After / 429)

	now func() time.Time // injectable clock (tests)
}

// Config configures an APNsPushAttestor.
type Config struct {
	TeamID     string // Apple Developer Team ID (e.g. SLDQ2GJ6TL)
	KeyID      string // APNs auth key (.p8) Key ID
	Topic      string // bundle id / push topic (io.darkbloom.provider)
	AuthKeyPEM []byte // contents of the .p8 (PEM PKCS#8 EC private key)
	Mode       Mode   // ModeBackground (default) or ModeAlert

	// HTTPClient overrides the HTTP/2 client (tests). If nil a default client
	// with HTTP/2 enabled is used.
	HTTPClient *http.Client
	// HostOverride replaces the APNs host for both environments (tests only).
	HostOverride string
}

// NewAPNsPushAttestor parses the .p8 and returns a ready attestor.
func NewAPNsPushAttestor(cfg Config) (*APNsPushAttestor, error) {
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.Topic == "" {
		return nil, fmt.Errorf("apns: TeamID, KeyID and Topic are required")
	}
	key, err := parseP8(cfg.AuthKeyPEM)
	if err != nil {
		return nil, err
	}
	mode := cfg.Mode
	if mode == "" {
		mode = ModeBackground
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{
			Timeout:   15 * time.Second,
			Transport: &http.Transport{ForceAttemptHTTP2: true},
		}
	}
	return &APNsPushAttestor{
		teamID:       cfg.TeamID,
		keyID:        cfg.KeyID,
		topic:        cfg.Topic,
		mode:         mode,
		key:          key,
		client:       client,
		hostOverride: cfg.HostOverride,
		backoffUntil: make(map[string]time.Time),
		now:          time.Now,
	}, nil
}

func parseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	if len(pemBytes) == 0 {
		return nil, fmt.Errorf("apns: empty auth key")
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, fmt.Errorf("apns: auth key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse PKCS#8 key: %w", err)
	}
	ecKey, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("apns: auth key is not an ECDSA P-256 key (got %T)", parsed)
	}
	return ecKey, nil
}

// SendCodeChallenge builds E_K(nonceB64) for the provider's key and pushes it.
func (a *APNsPushAttestor) SendCodeChallenge(ctx context.Context, deviceToken, environment, providerPubKeyB64, nonceB64 string) error {
	if deviceToken == "" {
		return fmt.Errorf("apns: empty device token")
	}
	if blocked, until := a.inBackoff(deviceToken); blocked {
		return fmt.Errorf("apns: device %s in backoff until %s", short(deviceToken), until.Format(time.RFC3339))
	}

	payload, err := BuildCodeChallengePayload(nonceB64, providerPubKeyB64, a.mode)
	if err != nil {
		return fmt.Errorf("apns: build challenge payload: %w", err)
	}

	jwt, err := a.jwt()
	if err != nil {
		return fmt.Errorf("apns: mint jwt: %w", err)
	}

	host := prodHost
	if environment == "development" {
		host = devHost
	}
	if a.hostOverride != "" {
		host = a.hostOverride
	}

	url := host + "/3/device/" + deviceToken
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("apns: build request: %w", err)
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", a.topic)
	req.Header.Set("apns-push-type", string(a.mode))
	req.Header.Set("apns-priority", a.priority())
	req.Header.Set("apns-expiration", strconv.FormatInt(a.now().Unix()+challengeExpirySeconds, 10))
	req.Header.Set("content-type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("apns: send: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch {
	case resp.StatusCode == http.StatusOK:
		return nil
	case resp.StatusCode == http.StatusTooManyRequests:
		a.setBackoff(deviceToken, resp.Header.Get("Retry-After"))
		return fmt.Errorf("apns: 429 too many requests for device %s: %s", short(deviceToken), string(body))
	default:
		return fmt.Errorf("apns: status %d: %s", resp.StatusCode, string(body))
	}
}

func (a *APNsPushAttestor) priority() string {
	if a.mode == ModeAlert {
		return "10"
	}
	return "5"
}

// jwt returns a cached ES256 JWT, minting a fresh one if older than jwtMaxAge.
func (a *APNsPushAttestor) jwt() (string, error) {
	a.jwtMu.Lock()
	defer a.jwtMu.Unlock()
	if a.cachedJWT != "" && a.now().Sub(a.jwtIssued) < jwtMaxAge {
		return a.cachedJWT, nil
	}
	tok, iat, err := a.mintJWT()
	if err != nil {
		return "", err
	}
	a.cachedJWT = tok
	a.jwtIssued = iat
	return tok, nil
}

func (a *APNsPushAttestor) mintJWT() (string, time.Time, error) {
	iat := a.now()
	header := b64url([]byte(fmt.Sprintf(`{"alg":"ES256","kid":%q}`, a.keyID)))
	claims := b64url([]byte(fmt.Sprintf(`{"iss":%q,"iat":%d}`, a.teamID, iat.Unix())))
	signingInput := header + "." + claims

	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", time.Time{}, err
	}
	// JOSE ES256 signature = R || S, each left-padded to 32 bytes (NOT ASN.1).
	sig := append(i2osp(r, 32), i2osp(s, 32)...)
	return signingInput + "." + b64urlRaw(sig), iat, nil
}

func (a *APNsPushAttestor) inBackoff(deviceToken string) (bool, time.Time) {
	a.backoffMu.Lock()
	defer a.backoffMu.Unlock()
	until, ok := a.backoffUntil[deviceToken]
	if ok && a.now().Before(until) {
		return true, until
	}
	return false, time.Time{}
}

func (a *APNsPushAttestor) setBackoff(deviceToken, retryAfter string) {
	d := 30 * time.Second
	if retryAfter != "" {
		if secs, err := strconv.Atoi(retryAfter); err == nil && secs > 0 {
			d = time.Duration(secs) * time.Second
		}
	}
	a.backoffMu.Lock()
	a.backoffUntil[deviceToken] = a.now().Add(d)
	a.backoffMu.Unlock()
}

// BuildCodeChallengePayload returns the APNs JSON body carrying E_K(nonceB64),
// where the nonce (a base64 string) is encrypted to the provider's X25519 key
// using the SAME E2E path used for inference request bodies. The "code_challenge"
// object is an e2e.EncryptedPayload; the provider decrypts it with its NodeKeyPair
// exactly as it decrypts an inference body. content-available:1 keeps the silent
// delivery path active in both modes.
func BuildCodeChallengePayload(nonceB64, providerPubKeyB64 string, mode Mode) ([]byte, error) {
	if nonceB64 == "" {
		return nil, fmt.Errorf("apns: empty nonce")
	}
	recipient, err := e2e.ParsePublicKey(providerPubKeyB64)
	if err != nil {
		return nil, fmt.Errorf("apns: provider public key: %w", err)
	}
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		return nil, err
	}
	enc, err := e2e.Encrypt([]byte(nonceB64), recipient, session)
	if err != nil {
		return nil, err
	}
	aps := map[string]any{"content-available": 1}
	if mode == ModeAlert {
		// Alert mode improves delivery reliability (priority 10, not background-
		// throttled). It is safe ONLY because the provider does NOT request
		// user-notification authorization: without it, the alert is never
		// presented or persisted to the root-readable Notification Center DB, so
		// the encrypted code_challenge leaves no on-disk cleartext copy. If the
		// provider ever adds UNUserNotificationCenter authorization, this dict
		// must be dropped for the attestation push (keep it background-only).
		// See the INVARIANT in provider-swift ProviderAppKitHost.swift.
		aps["alert"] = map[string]any{"title": "Darkbloom", "body": "attestation"}
	}
	return json.Marshal(map[string]any{
		"aps":            aps,
		"code_challenge": enc,
	})
}

// --- small helpers ---

func b64url(b []byte) string    { return base64.RawURLEncoding.EncodeToString(b) }
func b64urlRaw(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// i2osp converts a big.Int to a fixed-size big-endian byte slice (left-padded).
func i2osp(n *big.Int, size int) []byte {
	b := n.Bytes()
	if len(b) >= size {
		return b[len(b)-size:]
	}
	out := make([]byte, size)
	copy(out[size-len(b):], b)
	return out
}

func short(s string) string {
	if len(s) <= 12 {
		return s
	}
	return s[:12] + "…"
}
