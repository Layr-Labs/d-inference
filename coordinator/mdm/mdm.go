// Package mdm provides integration with MicroMDM to independently verify
// provider device security posture.
//
// When a provider registers, the coordinator:
//  1. Looks up the device by serial number in MicroMDM
//  2. Verifies the device is enrolled (MDM profile installed)
//  3. Sends a SecurityInfo command to get hardware-verified SIP/SecureBoot status
//  4. Cross-checks the MDM response against the provider's self-reported attestation
//  5. Assigns trust level based on both
//
// This prevents providers from faking their attestation — the MDM SecurityInfo
// comes directly from Apple's MDM framework on the device, not from the
// provider's software.
package mdm

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// commandUUIDRe extracts the CommandUUID from a MicroMDM device response plist
// (<key>CommandUUID</key><string>…</string>), tolerating whitespace/newlines.
var commandUUIDRe = regexp.MustCompile(`<key>CommandUUID</key>\s*<string>([^<]+)</string>`)

// parseCommandUUID returns the CommandUUID embedded in a device response plist,
// or "" if absent.
func parseCommandUUID(plistData []byte) string {
	m := commandUUIDRe.FindSubmatch(plistData)
	if len(m) < 2 {
		return ""
	}
	return string(bytes.TrimSpace(m[1]))
}

// DeviceAttestationResponse contains the DER-encoded certificate chain
// from Apple's DevicePropertiesAttestation response.
type DeviceAttestationResponse struct {
	UDID      string
	CertChain [][]byte // DER-encoded certificates, leaf first
}

// OnMDACallback is called when a DevicePropertiesAttestation response arrives.
// The UDID identifies the device; certChain is the DER-encoded Apple cert chain.
type OnMDACallback func(udid string, certChain [][]byte)

// OnLateSecurityInfoCallback is called when a SecurityInfo response arrives
// for a UDID with no active waiter (the original verification timed out).
// This allows the coordinator to retroactively upgrade a self_signed provider
// to hardware trust when APN delivery was slow.
type OnLateSecurityInfoCallback func(udid string, info *SecurityInfoResponse)

// Client talks to the MicroMDM API.
type Client struct {
	baseURL string
	apiKey  string
	client  *http.Client
	logger  *slog.Logger
	// Per-UDID one-shot channels for webhook response dispatch.
	// A goroutine calling WaitForSecurityInfo or WaitForDeviceAttestation
	// registers a channel here; HandleWebhook delivers to it or drops if
	// nobody is waiting — no shared buffer, no saturation, no busy-spin.
	waitMu         sync.Mutex
	secInfoWaiters map[string]chan *SecurityInfoResponse
	attestWaiters  map[string]chan *DeviceAttestationResponse
	// Callback for MDA certs that arrive after the initial wait times out.
	onMDA OnMDACallback
	// Callback for SecurityInfo responses that arrive after the waiter timed out.
	onLateSecInfo OnLateSecurityInfoCallback

	// outstanding tracks command UUIDs the coordinator has issued but not yet
	// matched to a response. The webhook only honors a response whose
	// CommandUUID is here — this is what makes the (unauthenticated) MicroMDM
	// callback safe: a caller can only ANSWER a command we actually issued, it
	// can never volunteer an unsolicited "SIP=true" to forge a trust upgrade.
	// Keyed by command UUID (a random, non-public identifier).
	outstandingMu sync.Mutex
	outstanding   map[string]outstandingCommand
}

// outstandingCommand records a command UUID the coordinator issued, so the
// webhook can verify an inbound response was solicited.
type outstandingCommand struct {
	udid     string
	issuedAt time.Time
}

// outstandingCommandTTL bounds how long an issued command UUID stays valid for
// matching a webhook response. It must comfortably exceed the worst-case APN /
// Power Nap delivery delay (a sleeping Mac wakes on roughly a ~15-minute Power
// Nap cadence — see the late-SecurityInfo callback in cmd/coordinator/main.go),
// otherwise the UUID expires before a genuine SecurityInfo response arrives,
// consumeCommand drops it as stale, and the self_signed→hardware recovery path
// never fires. 30 minutes covers that delay while still bounding the forge
// window if a (random, localhost-only) UUID ever leaked.
const outstandingCommandTTL = 30 * time.Minute

// NewClient creates an MDM client.
func NewClient(baseURL, apiKey string, logger *slog.Logger) *Client {
	httpClient := &http.Client{
		Timeout: 10 * time.Second,
	}
	// When talking to localhost MDM, skip TLS verification since the cert
	// is issued for the public domain, not localhost/127.0.0.1.
	if strings.Contains(baseURL, "localhost") || strings.Contains(baseURL, "127.0.0.1") {
		httpClient.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}
	return &Client{
		baseURL:        baseURL,
		apiKey:         apiKey,
		client:         httpClient,
		logger:         logger,
		secInfoWaiters: make(map[string]chan *SecurityInfoResponse),
		attestWaiters:  make(map[string]chan *DeviceAttestationResponse),
		outstanding:    make(map[string]outstandingCommand),
	}
}

// readOnlyMDMRequestTypes is the EXHAUSTIVE allowlist of MDM command request
// types the coordinator is permitted to send to a provider's Mac. Both are pure
// queries — they read security posture and never mutate the device:
//
//	SecurityInfo      → SIP / Secure Boot / FileVault status
//	DeviceInformation → DevicePropertiesAttestation (Apple-signed cert chain)
//
// Every command that could act ON a provider's machine — DeviceLock,
// EraseDevice, RestartDevice, ShutDownDevice, InstallProfile, RemoveProfile,
// InstallApplication, ClearPasscode, EnableRemoteDesktop, ScheduleOSUpdate, … —
// is intentionally absent. Enrolling a provider grants the coordinator
// read-only visibility into hardware trust, NEVER control. assertReadOnlyCommand
// is the single chokepoint that enforces this: a future code path (or a
// compromised coordinator) that tries to issue a mutating command fails closed
// here instead of reaching the device. To add a command type, it must be a
// read-only query AND added here in review.
var readOnlyMDMRequestTypes = map[string]struct{}{
	"SecurityInfo":      {},
	"DeviceInformation": {},
}

// ErrMutatingCommandBlocked is returned when something attempts to send an MDM
// command that is not on the read-only allowlist.
var ErrMutatingCommandBlocked = fmt.Errorf("mdm: refusing to send non-read-only command (provider machines are read-only)")

// assertReadOnlyCommand fails closed unless requestType is a known read-only
// query. This is the guarantee that the coordinator can never "do something" to
// a provider's Mac via MDM.
func assertReadOnlyCommand(requestType string) error {
	if _, ok := readOnlyMDMRequestTypes[requestType]; !ok {
		return fmt.Errorf("%w: %q", ErrMutatingCommandBlocked, requestType)
	}
	return nil
}

// trackCommand records an issued command UUID so the webhook can confirm a
// later response was solicited. Prunes expired entries opportunistically.
func (c *Client) trackCommand(commandUUID, udid string, now time.Time) {
	if commandUUID == "" {
		return
	}
	c.outstandingMu.Lock()
	defer c.outstandingMu.Unlock()
	for id, cmd := range c.outstanding {
		if now.Sub(cmd.issuedAt) > outstandingCommandTTL {
			delete(c.outstanding, id)
		}
	}
	c.outstanding[commandUUID] = outstandingCommand{udid: udid, issuedAt: now}
}

// consumeCommand checks whether commandUUID corresponds to a command the
// coordinator issued (and has not yet expired), removing it (one-shot). It
// returns the UDID the command was sent to and whether the match succeeded.
func (c *Client) consumeCommand(commandUUID string, now time.Time) (string, bool) {
	if commandUUID == "" {
		return "", false
	}
	c.outstandingMu.Lock()
	defer c.outstandingMu.Unlock()
	cmd, ok := c.outstanding[commandUUID]
	if !ok {
		return "", false
	}
	delete(c.outstanding, commandUUID)
	if now.Sub(cmd.issuedAt) > outstandingCommandTTL {
		return "", false
	}
	return cmd.udid, true
}

// SetOnMDA registers a callback for late-arriving MDA attestation certs.
func (c *Client) SetOnMDA(fn OnMDACallback) {
	c.onMDA = fn
}

// SetOnLateSecurityInfo registers a callback for SecurityInfo responses that
// arrive after the synchronous waiter has timed out. This enables the
// coordinator to retroactively upgrade providers when APN delivery is slow.
func (c *Client) SetOnLateSecurityInfo(fn OnLateSecurityInfoCallback) {
	c.onLateSecInfo = fn
}

// DeviceInfo from MicroMDM's device list.
type DeviceInfo struct {
	SerialNumber     string `json:"serial_number"`
	UDID             string `json:"udid"`
	EnrollmentStatus bool   `json:"enrollment_status"`
	LastSeen         string `json:"last_seen"`
}

// SecurityInfoResponse parsed from the MDM SecurityInfo command response.
type SecurityInfoResponse struct {
	UDID                             string
	SystemIntegrityProtectionEnabled bool
	SecureBootLevel                  string // "full", "reduced", "permissive"
	AuthenticatedRootVolumeEnabled   bool
	FirewallEnabled                  bool
	FileVaultEnabled                 bool
	IsRecoveryLockEnabled            bool
	RemoteDesktopEnabled             bool
}

// VerificationResult from cross-checking MDM with attestation.
type VerificationResult struct {
	DeviceEnrolled    bool
	UDID              string
	SerialNumber      string
	MDMSIPEnabled     bool
	MDMSecureBootFull bool
	MDMAuthRootVolume bool
	MDMRecoveryLocked bool // Recovery Lock prevents Recovery OS access (blocks rdma_ctl enable)
	SIPMatch          bool // MDM SIP matches attestation SIP
	SecureBootMatch   bool // MDM SecureBoot matches attestation

	// SecurityMismatch is true ONLY for a genuine posture failure proven by a
	// received SecurityInfo response: SIP disabled, Secure Boot not full, or the
	// MDM-reported posture disagreeing with the provider's attestation. It is the
	// single signal callers use to decide a hard (terminal) untrust. It is FALSE
	// for every "could not complete the check" condition (device not found / not
	// enrolled, command send failure, SecurityInfo timeout, context cancellation),
	// so a transient MicroMDM/APNs problem never hard-untrusts an enrolled box.
	SecurityMismatch bool

	Error string
}

// LookupDevice checks if a device with the given serial number is enrolled.
func (c *Client) LookupDevice(ctx context.Context, serialNumber string) (*DeviceInfo, error) {
	body, _ := json.Marshal(map[string]string{"serial_number": serialNumber})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/devices", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth("micromdm", c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("mdm device lookup failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("mdm device lookup returned %d", resp.StatusCode)
	}

	var result struct {
		Devices []DeviceInfo `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("mdm device lookup decode failed: %w", err)
	}

	for _, d := range result.Devices {
		if d.SerialNumber == serialNumber {
			return &d, nil
		}
	}

	return nil, nil // not found
}

// SendSecurityInfoCommand sends a SecurityInfo command to a device by UDID.
// Returns the command UUID for tracking the response.
func (c *Client) SendSecurityInfoCommand(ctx context.Context, udid string) (string, error) {
	const requestType = "SecurityInfo"
	if err := assertReadOnlyCommand(requestType); err != nil {
		return "", err
	}
	body, _ := json.Marshal(map[string]string{
		"udid":         udid,
		"request_type": requestType,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/commands", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.SetBasicAuth("micromdm", c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("mdm send command failed: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Payload struct {
			CommandUUID string `json:"command_uuid"`
		} `json:"payload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("mdm command response decode failed: %w", err)
	}

	c.trackCommand(result.Payload.CommandUUID, udid, time.Now())

	// Do NOT push explicitly here. MicroMDM's structured POST /v1/commands already
	// schedules the command AND sends the APNs push to wake the device, so an extra
	// GET /push/{udid} would be a SECOND push per attempt — wasted MDM/APNs push
	// budget, the pressure this change exists to reduce. (The MDA path uses the raw
	// POST /v1/commands/{udid} endpoint, which does NOT auto-push, so it pushes
	// explicitly — that asymmetry is correct, not a bug.) The fast-device webhook
	// race is handled by registering the SecurityInfo waiter BEFORE this call in
	// VerifyProvider, so the auto-push's response always finds a waiter.
	return result.Payload.CommandUUID, nil
}

// pushDevice sends a best-effort APNs push to a device via MicroMDM to trigger
// an immediate check-in so a freshly-queued command is pulled promptly rather
// than at the next idle wake. Errors are intentionally ignored: the command is
// already enqueued, and the push is only a latency optimization.
func (c *Client) pushDevice(ctx context.Context, udid string) {
	pushReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/push/"+udid, nil)
	if err != nil {
		return
	}
	pushReq.SetBasicAuth("micromdm", c.apiKey)
	if resp, err := c.client.Do(pushReq); err == nil {
		_ = resp.Body.Close()
	}
}

// SendDeviceAttestationCommand sends a DeviceInformation command requesting
// DevicePropertiesAttestation from Apple. The device contacts Apple's servers,
// which return a DER-encoded certificate chain signed by Apple's Enterprise
// Attestation Root CA. This is the real MDA — Apple vouches for the device.
//
// If nonce is non-empty, it is included as DeviceAttestationNonce. Apple hashes
// the nonce and embeds the hash as FreshnessCode (OID 1.2.840.113635.100.8.11.1)
// in the leaf certificate. This binds arbitrary data (e.g. a SE key hash) to
// Apple's attestation signature.
//
// When a nonce is provided, we send a raw plist command because MicroMDM's
// DeviceInformation struct doesn't support DeviceAttestationNonce.
func (c *Client) SendDeviceAttestationCommand(ctx context.Context, udid string, nonce ...string) (string, error) {
	// Always use raw plist to support DeviceAttestationNonce
	nonceStr := ""
	if len(nonce) > 0 {
		nonceStr = nonce[0]
	}
	return c.sendDeviceAttestationWithNonce(ctx, udid, nonceStr)
}

// sendDeviceAttestationWithNonce sends a raw plist DeviceInformation command
// with DeviceAttestationNonce. MicroMDM's structured API doesn't support this
// field, so we bypass it with the raw command endpoint: POST /v1/commands/{udid}.
func (c *Client) sendDeviceAttestationWithNonce(ctx context.Context, udid, nonce string) (string, error) {
	// DevicePropertiesAttestation is requested via a DeviceInformation command.
	if err := assertReadOnlyCommand("DeviceInformation"); err != nil {
		return "", err
	}
	cmdUUID := uuid.New().String()

	// Build nonce XML if provided
	nonceXML := ""
	if nonce != "" {
		nonceXML = fmt.Sprintf(`
		<key>DeviceAttestationNonce</key>
		<data>%s</data>`, nonce)
	}

	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Command</key>
	<dict>
		<key>RequestType</key>
		<string>DeviceInformation</string>
		<key>Queries</key>
		<array>
			<string>DevicePropertiesAttestation</string>
		</array>%s
	</dict>
	<key>CommandUUID</key>
	<string>%s</string>
</dict>
</plist>`, nonceXML, cmdUUID)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/commands/"+udid, bytes.NewReader([]byte(plist)))
	if err != nil {
		return "", err
	}
	req.SetBasicAuth("micromdm", c.apiKey)
	req.Header.Set("Content-Type", "application/xml")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("mdm send DeviceInformation with nonce failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("mdm raw command failed (status %d): %s", resp.StatusCode, string(respBody))
	}

	c.trackCommand(cmdUUID, udid, time.Now())

	// Push to trigger device check-in (best-effort; command is already queued).
	// The raw POST /v1/commands/{udid} endpoint does NOT auto-push (unlike the
	// structured /v1/commands), so the explicit push is required here.
	c.pushDevice(ctx, udid)

	return cmdUUID, nil
}

// WaitForDeviceAttestation waits for a DevicePropertiesAttestation response.
// It returns early if ctx is cancelled (e.g. the provider disconnected), so a
// teardown isn't blocked for the full timeout.
func (c *Client) WaitForDeviceAttestation(ctx context.Context, udid string, timeout time.Duration) (*DeviceAttestationResponse, error) {
	ch := make(chan *DeviceAttestationResponse, 1)

	c.waitMu.Lock()
	c.attestWaiters[udid] = ch
	c.waitMu.Unlock()

	defer func() {
		c.waitMu.Lock()
		// Identity-guarded delete (parity with registerSecurityInfoWaiter): only
		// remove our own channel. With two overlapping connections for the same
		// device (same UDID), an unconditional delete could drop a later waiter's
		// live channel and route its Apple attestation response to the late
		// callback instead.
		if cur, ok := c.attestWaiters[udid]; ok && cur == ch {
			delete(c.attestWaiters, udid)
		}
		c.waitMu.Unlock()
	}()

	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("device attestation wait cancelled for %s: %w", udid, ctx.Err())
	case <-time.After(timeout):
		return nil, fmt.Errorf("timeout waiting for DevicePropertiesAttestation from %s", udid)
	}
}

// HandleWebhook processes a MicroMDM webhook payload and extracts
// SecurityInfo and DevicePropertiesAttestation responses.
func (c *Client) HandleWebhook(body []byte) {
	var webhook struct {
		Topic string `json:"topic"`
		Event struct {
			UDID       string `json:"udid"`
			Status     string `json:"status"`
			RawPayload string `json:"raw_payload"`
		} `json:"acknowledge_event"`
	}

	if err := json.Unmarshal(body, &webhook); err != nil {
		c.logger.Debug("mdm webhook parse failed", "error", err)
		return
	}

	c.logger.Info("mdm webhook parsed",
		"topic", webhook.Topic,
		"udid", webhook.Event.UDID,
		"status", webhook.Event.Status,
		"has_payload", webhook.Event.RawPayload != "",
	)

	if webhook.Event.Status != "Acknowledged" || webhook.Event.RawPayload == "" {
		return
	}

	// Decode the base64 plist payload
	plistData, err := base64.StdEncoding.DecodeString(webhook.Event.RawPayload)
	if err != nil {
		c.logger.Debug("mdm webhook base64 decode failed", "error", err)
		return
	}

	// SOLICITED-RESPONSE GATE. Only honor a response whose CommandUUID matches a
	// command the coordinator actually issued. The webhook endpoint is otherwise
	// unauthenticated; without this, anyone who can reach it could POST a forged
	// "SIP=true" SecurityInfo (or an attestation) and drive a self_signed
	// provider to hardware trust. Because command UUIDs are random and never
	// exposed, an attacker cannot match an in-flight command. Unsolicited or
	// stale responses are dropped here, before any waiter or trust-upgrade
	// callback runs.
	cmdUUID := parseCommandUUID(plistData)
	trackedUDID, solicited := c.consumeCommand(cmdUUID, time.Now())
	if !solicited {
		c.logger.Warn("mdm webhook dropped: unsolicited or unknown CommandUUID",
			"udid", webhook.Event.UDID,
			"command_uuid", cmdUUID,
		)
		return
	}
	// Defense in depth: the response's device must be the one we addressed.
	if trackedUDID != "" && webhook.Event.UDID != "" && trackedUDID != webhook.Event.UDID {
		c.logger.Warn("mdm webhook dropped: CommandUUID/UDID mismatch",
			"command_uuid", cmdUUID,
			"webhook_udid", webhook.Event.UDID,
			"command_udid", trackedUDID,
		)
		return
	}

	// Log what the plist contains. The raw preview is kept at Debug only: it
	// echoes the device response verbatim, which includes the CommandUUID — and
	// UUID secrecy is what the solicited-command gate relies on, so it must not
	// be emitted at Info where it could leak the gate's secret to anyone with
	// log access.
	hasSecInfo := bytes.Contains(plistData, []byte("SecurityInfo"))
	hasDeviceAttest := bytes.Contains(plistData, []byte("DevicePropertiesAttestation"))
	c.logger.Info("mdm webhook plist content",
		"size", len(plistData),
		"has_security_info", hasSecInfo,
		"has_device_attestation", hasDeviceAttest,
	)
	c.logger.Debug("mdm webhook plist preview", "preview", string(plistData[:min(len(plistData), 2000)]))

	// Parse the plist for SecurityInfo
	secInfo := parseSecurityInfoPlist(plistData)
	if secInfo != nil {
		secInfo.UDID = webhook.Event.UDID
		c.logger.Info("mdm SecurityInfo received",
			"udid", secInfo.UDID,
			"sip", secInfo.SystemIntegrityProtectionEnabled,
			"secure_boot", secInfo.SecureBootLevel,
			"auth_root_volume", secInfo.AuthenticatedRootVolumeEnabled,
		)
		c.waitMu.Lock()
		ch, waiting := c.secInfoWaiters[secInfo.UDID]
		if waiting {
			delete(c.secInfoWaiters, secInfo.UDID)
		}
		c.waitMu.Unlock()
		if waiting {
			ch <- secInfo
		} else if c.onLateSecInfo != nil {
			// No active waiter — the synchronous verification timed out.
			// Invoke the late-arrival callback so the coordinator can
			// retroactively upgrade the provider to hardware trust.
			c.logger.Info("mdm SecurityInfo arrived late (no waiter), invoking callback", "udid", secInfo.UDID)
			c.onLateSecInfo(secInfo.UDID, secInfo)
		} else {
			c.logger.Debug("mdm SecurityInfo dropped (no waiter, no callback)", "udid", secInfo.UDID)
		}
	}

	// Parse the plist for DevicePropertiesAttestation
	attestCerts := parseDeviceAttestationPlist(plistData)
	if attestCerts != nil {
		resp := &DeviceAttestationResponse{
			UDID:      webhook.Event.UDID,
			CertChain: attestCerts,
		}
		c.logger.Info("mdm DevicePropertiesAttestation received",
			"udid", resp.UDID,
			"cert_count", len(resp.CertChain),
		)
		c.waitMu.Lock()
		ch, waiting := c.attestWaiters[resp.UDID]
		if waiting {
			delete(c.attestWaiters, resp.UDID)
		}
		c.waitMu.Unlock()
		if waiting {
			ch <- resp
		} else if c.onMDA != nil {
			c.onMDA(resp.UDID, resp.CertChain)
		} else {
			c.logger.Debug("mdm attestation response dropped (no waiter, no callback)", "udid", resp.UDID)
		}
	}
}

// registerSecurityInfoWaiter installs a one-shot waiter for a UDID's SecurityInfo
// response and returns the channel plus a release func to deregister it. Callers
// that send the command themselves MUST register the waiter BEFORE sending /
// pushing — otherwise a fast device can have its webhook arrive (and consume the
// tracked CommandUUID) before the waiter exists, so the response is dropped to the
// late-callback path and the in-flight verifier waits the full timeout.
func (c *Client) registerSecurityInfoWaiter(udid string) (<-chan *SecurityInfoResponse, func()) {
	ch := make(chan *SecurityInfoResponse, 1)
	c.waitMu.Lock()
	c.secInfoWaiters[udid] = ch
	c.waitMu.Unlock()
	return ch, func() {
		c.waitMu.Lock()
		// Only delete our own channel — HandleWebhook may already have delivered
		// and removed it, and a later waiter could have registered a new one.
		if cur, ok := c.secInfoWaiters[udid]; ok && cur == ch {
			delete(c.secInfoWaiters, udid)
		}
		c.waitMu.Unlock()
	}
}

// awaitSecurityInfo blocks on a previously-registered waiter channel until the
// response arrives, ctx is cancelled, or the timeout elapses.
func awaitSecurityInfo(ctx context.Context, ch <-chan *SecurityInfoResponse, udid string, timeout time.Duration) (*SecurityInfoResponse, error) {
	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("SecurityInfo wait cancelled for %s: %w", udid, ctx.Err())
	case <-time.After(timeout):
		return nil, fmt.Errorf("timeout waiting for SecurityInfo from %s", udid)
	}
}

// WaitForSecurityInfo registers a waiter and blocks for the response. Use this
// when the SecurityInfo command was (or will be) sent elsewhere. VerifyProvider
// instead registers the waiter explicitly before sending, to close the
// fast-device webhook race.
func (c *Client) WaitForSecurityInfo(ctx context.Context, udid string, timeout time.Duration) (*SecurityInfoResponse, error) {
	ch, release := c.registerSecurityInfoWaiter(udid)
	defer release()
	return awaitSecurityInfo(ctx, ch, udid, timeout)
}

// VerifyProvider performs the full MDM verification flow for a provider.
//
//  1. Look up device by serial number
//  2. Verify it's enrolled
//  3. Send SecurityInfo command
//  4. Wait for and parse response
//  5. Cross-check against attestation
func (c *Client) VerifyProvider(ctx context.Context, serialNumber string, attestationSIP, attestationSecureBoot bool) (*VerificationResult, error) {
	result := &VerificationResult{
		SerialNumber: serialNumber,
	}

	// Step 1: Look up device
	device, err := c.LookupDevice(ctx, serialNumber)
	if err != nil {
		result.Error = fmt.Sprintf("device lookup failed: %v", err)
		return result, nil
	}

	if device == nil {
		result.Error = "device not found in MDM — provider must install enrollment profile"
		return result, nil
	}

	result.DeviceEnrolled = device.EnrollmentStatus
	result.UDID = device.UDID

	if !device.EnrollmentStatus {
		result.Error = "device found but not enrolled in MDM"
		return result, nil
	}

	// Step 2: Register the response waiter BEFORE sending/pushing. The send path
	// pushes the device synchronously, so an awake device can answer before we'd
	// otherwise install the waiter; registering first guarantees the webhook finds
	// it and the in-flight verifier sees the response (instead of timing out and
	// relying on the late callback).
	ch, release := c.registerSecurityInfoWaiter(device.UDID)
	defer release()

	// Step 3: Send SecurityInfo command (enqueues + pushes the device).
	if _, err = c.SendSecurityInfoCommand(ctx, device.UDID); err != nil {
		result.Error = fmt.Sprintf("failed to send SecurityInfo command: %v", err)
		return result, nil
	}

	// Step 4: Wait for the response (via webhook). 90 seconds allows for APN
	// delivery delays during Power Nap cycles (every ~15 minutes on AC). Returns
	// early if ctx is cancelled (provider disconnected).
	secInfo, err := awaitSecurityInfo(ctx, ch, device.UDID, 90*time.Second)
	if err != nil {
		result.Error = fmt.Sprintf("SecurityInfo response: %v", err)
		return result, nil
	}

	// Step 4: Populate result
	result.MDMSIPEnabled = secInfo.SystemIntegrityProtectionEnabled
	result.MDMSecureBootFull = secInfo.SecureBootLevel == "full"
	result.MDMAuthRootVolume = secInfo.AuthenticatedRootVolumeEnabled
	result.MDMRecoveryLocked = secInfo.IsRecoveryLockEnabled

	// Step 5: Cross-check against attestation
	result.SIPMatch = result.MDMSIPEnabled == attestationSIP
	result.SecureBootMatch = result.MDMSecureBootFull == attestationSecureBoot

	// A non-empty Error set below is a GENUINE posture failure proven by a
	// received SecurityInfo response — mark SecurityMismatch so the caller hard-
	// untrusts. (Transport/timeout/not-enrolled errors return above with
	// SecurityMismatch=false and must NOT untrust.)
	if !result.MDMSIPEnabled {
		result.Error = "MDM reports SIP disabled"
		result.SecurityMismatch = true
	} else if !result.MDMSecureBootFull {
		result.Error = "MDM reports Secure Boot not full"
		result.SecurityMismatch = true
	} else if !result.SIPMatch {
		result.Error = "attestation SIP does not match MDM SIP — provider may be lying"
		result.SecurityMismatch = true
	} else if !result.SecureBootMatch {
		result.Error = "attestation SecureBoot does not match MDM — provider may be lying"
		result.SecurityMismatch = true
	}
	// Recovery Lock is recommended but not enforced yet — log a warning.
	// When enforced, providers without Recovery Lock could enable RDMA via Recovery OS.
	// TODO: enforce once Recovery Lock is deployed to all provider machines.

	return result, nil
}

// parseSecurityInfoPlist extracts security fields from the MDM response plist.
func parseSecurityInfoPlist(data []byte) *SecurityInfoResponse {
	// MDM responses are Apple plist XML. Parse the relevant fields.

	// Simple approach: look for known keys in the XML
	result := &SecurityInfoResponse{}
	found := bytes.Contains(data, []byte("SecurityInfo"))

	if bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>")) {
		result.SystemIntegrityProtectionEnabled = bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>\n\t\t<true/>")) ||
			bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>\r\n\t\t<true/>")) ||
			bytes.Contains(data, []byte("SystemIntegrityProtectionEnabled</key>\n\t<true")) ||
			bytes.Contains(data, []byte("SystemIntegrityProtectionEnabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>AuthenticatedRootVolumeEnabled</key>")) {
		result.AuthenticatedRootVolumeEnabled = bytes.Contains(data, []byte("AuthenticatedRootVolumeEnabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("AuthenticatedRootVolumeEnabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>FDE_Enabled</key>")) {
		result.FileVaultEnabled = bytes.Contains(data, []byte("FDE_Enabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("FDE_Enabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>IsRecoveryLockEnabled</key>")) {
		result.IsRecoveryLockEnabled = bytes.Contains(data, []byte("IsRecoveryLockEnabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("IsRecoveryLockEnabled</key>\n\t<true")) ||
			bytes.Contains(data, []byte("IsRecoveryLockEnabled</key><true"))
		found = true
	}

	// Parse SecureBoot level
	if idx := bytes.Index(data, []byte("<key>SecureBootLevel</key>")); idx >= 0 {
		rest := data[idx:]
		if sIdx := bytes.Index(rest, []byte("<string>")); sIdx >= 0 {
			rest = rest[sIdx+8:]
			if eIdx := bytes.Index(rest, []byte("</string>")); eIdx >= 0 {
				result.SecureBootLevel = string(rest[:eIdx])
				found = true
			}
		}
	}

	// Suppress unused import warning
	_ = xml.Name{}
	_ = io.EOF

	if !found {
		return nil
	}
	return result
}

// parseDeviceAttestationPlist extracts the DER certificate chain from a
// DeviceInformation response containing DevicePropertiesAttestation.
//
// The plist format is:
//
//	<key>DevicePropertiesAttestation</key>
//	<array>
//	  <data>...base64 DER cert...</data>
//	  <data>...base64 DER cert...</data>
//	</array>
func parseDeviceAttestationPlist(data []byte) [][]byte {
	// Find DevicePropertiesAttestation key
	marker := []byte("<key>DevicePropertiesAttestation</key>")
	idx := bytes.Index(data, marker)
	if idx < 0 {
		return nil
	}

	rest := data[idx+len(marker):]

	// Find the <array> element
	arrStart := bytes.Index(rest, []byte("<array>"))
	if arrStart < 0 {
		return nil
	}
	rest = rest[arrStart:]

	arrEnd := bytes.Index(rest, []byte("</array>"))
	if arrEnd < 0 {
		return nil
	}
	arrayContent := rest[:arrEnd]

	// Extract all <data>...</data> elements
	var certs [][]byte
	remaining := arrayContent
	for {
		dataStart := bytes.Index(remaining, []byte("<data>"))
		if dataStart < 0 {
			break
		}
		remaining = remaining[dataStart+6:]

		dataEnd := bytes.Index(remaining, []byte("</data>"))
		if dataEnd < 0 {
			break
		}

		// Strip ALL whitespace (tabs, newlines) from the base64 data —
		// Apple's plist format includes formatting whitespace inside <data> tags.
		raw := bytes.TrimSpace(remaining[:dataEnd])
		var cleaned []byte
		for _, b := range raw {
			if b != '\n' && b != '\r' && b != '\t' && b != ' ' {
				cleaned = append(cleaned, b)
			}
		}
		b64Data := string(cleaned)
		remaining = remaining[dataEnd+7:]

		// Decode base64 to get DER bytes
		derBytes, err := base64.StdEncoding.DecodeString(b64Data)
		if err != nil {
			continue
		}
		certs = append(certs, derBytes)
	}

	if len(certs) == 0 {
		return nil
	}
	return certs
}
