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
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/google/uuid"
)

const (
	// webhookResponseBufferSize is the buffered channel capacity for async MDM responses.
	webhookResponseBufferSize = 16
	// plistPreviewBytes bounds the plist payload preview included in debug logs.
	plistPreviewBytes = 2000
	// securityInfoTimeout is how long we wait for a SecurityInfo webhook after sending.
	securityInfoTimeout = 30 * time.Second
	// httpStatusOK is the standard success response code.
	httpStatusOK = 200
	// httpStatusMultipleChoices is the lower bound for redirect/error responses (>=300).
	httpStatusMultipleChoices = 300
)

// ErrDeviceNotFound is returned when an MDM device lookup finds no match.
//
//nolint:gochecknoglobals // sentinel error
var ErrDeviceNotFound = errors.New("mdm: device not found")

// DeviceAttestationResponse contains the DER-encoded certificate chain
// from Apple's DevicePropertiesAttestation response.
type DeviceAttestationResponse struct {
	UDID      string
	CertChain [][]byte // DER-encoded certificates, leaf first
}

// OnMDACallback is called when a DevicePropertiesAttestation response arrives.
// The UDID identifies the device; certChain is the DER-encoded Apple cert chain.
type OnMDACallback func(udid string, certChain [][]byte)

// Client talks to the MicroMDM API.
type Client struct {
	baseURL string
	apiKey  string
	client  *http.Client
	logger  *slog.Logger
	// Webhook responses arrive asynchronously.
	responses       chan *SecurityInfoResponse
	attestResponses chan *DeviceAttestationResponse
	// Callback for MDA certs that arrive after the initial wait times out.
	onMDA OnMDACallback
}

// isLoopbackHost reports whether host is exactly "localhost" or a loopback IP
// literal ("127.0.0.1", "::1", etc.). Unlike substring matching, this rejects
// spoofed hostnames such as "localhost.evil.com".
func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return true
	}
	return false
}

// NewClient creates an MDM client.
func NewClient(baseURL, apiKey string, logger *slog.Logger) *Client {
	httpClient := &http.Client{
		Timeout: 10 * time.Second,
	}
	// When talking to a loopback MDM server, skip TLS verification since the
	// cert is typically issued for the public domain, not localhost/127.0.0.1.
	// Parse the URL and check the hostname explicitly to avoid matching
	// hostile names like "localhost.evil.com".
	if u, err := url.Parse(baseURL); err == nil && isLoopbackHost(u.Hostname()) {
		httpClient.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true, //nolint:gosec // verified loopback host only
				MinVersion:         tls.VersionTLS12,
			},
		}
	}
	return &Client{
		baseURL:         baseURL,
		apiKey:          apiKey,
		client:          httpClient,
		logger:          logger,
		responses:       make(chan *SecurityInfoResponse, webhookResponseBufferSize),
		attestResponses: make(chan *DeviceAttestationResponse, webhookResponseBufferSize),
	}
}

// SetOnMDA registers a callback for late-arriving MDA attestation certs.
func (c *Client) SetOnMDA(fn OnMDACallback) {
	c.onMDA = fn
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
	Error             string
}

// LookupDevice checks if a device with the given serial number is enrolled.
func (c *Client) LookupDevice(serialNumber string) (*DeviceInfo, error) {
	body, _ := json.Marshal(map[string]string{"serial_number": serialNumber})
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, c.baseURL+"/v1/devices", bytes.NewReader(body))
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

	if resp.StatusCode != httpStatusOK {
		return nil, fmt.Errorf("mdm device lookup returned %d", resp.StatusCode)
	}

	var result struct {
		Devices []DeviceInfo `json:"devices"`
	}
	if err = json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("mdm device lookup decode failed: %w", err)
	}

	for _, d := range result.Devices {
		if d.SerialNumber == serialNumber {
			return &d, nil
		}
	}

	return nil, ErrDeviceNotFound
}

// SendSecurityInfoCommand sends a SecurityInfo command to a device by UDID.
// Returns the command UUID for tracking the response.
func (c *Client) SendSecurityInfoCommand(udid string) (string, error) {
	body, _ := json.Marshal(map[string]string{
		"udid":         udid,
		"request_type": "SecurityInfo",
	})
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, c.baseURL+"/v1/commands", bytes.NewReader(body))
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
	if err = json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("mdm command response decode failed: %w", err)
	}

	return result.Payload.CommandUUID, nil
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
func (c *Client) SendDeviceAttestationCommand(udid string, nonce ...string) (string, error) {
	// Always use raw plist to support DeviceAttestationNonce
	nonceStr := ""
	if len(nonce) > 0 {
		nonceStr = nonce[0]
	}
	return c.sendDeviceAttestationWithNonce(udid, nonceStr)
}

// sendDeviceAttestationWithNonce sends a raw plist DeviceInformation command
// with DeviceAttestationNonce. MicroMDM's structured API doesn't support this
// field, so we bypass it with the raw command endpoint: POST /v1/commands/{udid}.
func (c *Client) sendDeviceAttestationWithNonce(udid, nonce string) (string, error) {
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

	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, c.baseURL+"/v1/commands/"+udid, bytes.NewReader([]byte(plist)))
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

	if resp.StatusCode >= httpStatusMultipleChoices {
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("mdm raw command failed (status %d): %s", resp.StatusCode, string(respBody))
	}

	// Push to trigger device check-in
	pushReq, err := http.NewRequestWithContext(context.Background(), http.MethodGet, c.baseURL+"/push/"+udid, nil)
	if err != nil {
		return cmdUUID, nil // command queued, push failed
	}
	pushReq.SetBasicAuth("micromdm", c.apiKey)
	pushResp, err := c.client.Do(pushReq)
	if err != nil {
		c.logger.Debug("mdm push notification failed", "udid", udid, "error", err)
	} else {
		pushResp.Body.Close()
	}

	return cmdUUID, nil
}

// WaitForDeviceAttestation waits for a DevicePropertiesAttestation response.
func (c *Client) WaitForDeviceAttestation(udid string, timeout time.Duration) (*DeviceAttestationResponse, error) {
	deadline := time.After(timeout)
	for {
		select {
		case resp := <-c.attestResponses:
			if resp.UDID == udid {
				return resp, nil
			}
			select {
			case c.attestResponses <- resp:
			default:
			}
		case <-deadline:
			return nil, fmt.Errorf("timeout waiting for DevicePropertiesAttestation from %s", udid)
		}
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

	// Log what the plist contains for debugging
	hasSecInfo := bytes.Contains(plistData, []byte("SecurityInfo"))
	hasDeviceAttest := bytes.Contains(plistData, []byte("DevicePropertiesAttestation"))
	c.logger.Info("mdm webhook plist content",
		"size", len(plistData),
		"has_security_info", hasSecInfo,
		"has_device_attestation", hasDeviceAttest,
		"preview", string(plistData[:min(len(plistData), plistPreviewBytes)]),
	)

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
		select {
		case c.responses <- secInfo:
		default:
			c.logger.Warn("mdm response channel full, dropping")
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
		select {
		case c.attestResponses <- resp:
		default:
			// Channel full or nobody waiting — use callback instead
			if c.onMDA != nil {
				c.onMDA(resp.UDID, resp.CertChain)
			} else {
				c.logger.Warn("mdm attestation response dropped (no waiter, no callback)")
			}
		}
	}
}

// WaitForSecurityInfo waits for a SecurityInfo response for the given UDID.
func (c *Client) WaitForSecurityInfo(udid string, timeout time.Duration) (*SecurityInfoResponse, error) {
	deadline := time.After(timeout)
	for {
		select {
		case resp := <-c.responses:
			if resp.UDID == udid {
				return resp, nil
			}
			// Put it back for other waiters
			select {
			case c.responses <- resp:
			default:
			}
		case <-deadline:
			return nil, fmt.Errorf("timeout waiting for SecurityInfo from %s", udid)
		}
	}
}

// VerifyProvider performs the full MDM verification flow for a provider.
//
//  1. Look up device by serial number
//  2. Verify it's enrolled
//  3. Send SecurityInfo command
//  4. Wait for and parse response
//  5. Cross-check against attestation
func (c *Client) VerifyProvider(
	serialNumber string, attestationSIP, attestationSecureBoot bool,
) (*VerificationResult, error) {
	result := &VerificationResult{
		SerialNumber: serialNumber,
	}

	// Step 1: Look up device
	device, err := c.LookupDevice(serialNumber)
	if err != nil {
		if errors.Is(err, ErrDeviceNotFound) {
			result.Error = "device not found in MDM — provider must install enrollment profile"
			return result, nil
		}
		result.Error = fmt.Sprintf("device lookup failed: %v", err)
		return result, nil
	}

	result.DeviceEnrolled = device.EnrollmentStatus
	result.UDID = device.UDID

	if !device.EnrollmentStatus {
		result.Error = "device found but not enrolled in MDM"
		return result, nil
	}

	// Step 2: Send SecurityInfo command
	_, err = c.SendSecurityInfoCommand(device.UDID)
	if err != nil {
		result.Error = fmt.Sprintf("failed to send SecurityInfo command: %v", err)
		return result, nil
	}

	// Step 3: Wait for response (via webhook)
	secInfo, err := c.WaitForSecurityInfo(device.UDID, securityInfoTimeout)
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

	switch {
	case !result.MDMSIPEnabled:
		result.Error = "MDM reports SIP disabled"
	case !result.MDMSecureBootFull:
		result.Error = "MDM reports Secure Boot not full"
	case !result.SIPMatch:
		result.Error = "attestation SIP does not match MDM SIP — provider may be lying"
	case !result.SecureBootMatch:
		result.Error = "attestation SecureBoot does not match MDM — provider may be lying"
	}
	// Recovery Lock is recommended but not enforced yet — log a warning.
	// When enforced, providers without Recovery Lock could enable RDMA via Recovery OS.
	// TODO: enforce once Recovery Lock is deployed to all provider machines.

	return result, nil
}

// parseSecurityInfoPlist extracts security fields from the MDM response plist.
func parseSecurityInfoPlist(data []byte) *SecurityInfoResponse {
	// Simple approach: look for known keys in the XML
	result := &SecurityInfoResponse{}
	found := false

	if bytes.Contains(data, []byte("SecurityInfo")) {
		found = true
	}
	sipKey := "SystemIntegrityProtectionEnabled"
	if bytes.Contains(data, []byte("<key>"+sipKey+"</key>")) {
		result.SystemIntegrityProtectionEnabled =
			bytes.Contains(data, []byte(sipKey+"</key>\n\t\t<true/>")) ||
				bytes.Contains(data, []byte(sipKey+"</key>\r\n\t\t<true/>")) ||
				bytes.Contains(data, []byte(sipKey+"</key>\n\t<true")) ||
				bytes.Contains(data, []byte(sipKey+"</key><true"))
		found = true
	}
	arvKey := "AuthenticatedRootVolumeEnabled"
	if bytes.Contains(data, []byte("<key>"+arvKey+"</key>")) {
		result.AuthenticatedRootVolumeEnabled =
			bytes.Contains(data, []byte(arvKey+"</key>\n\t\t<true")) ||
				bytes.Contains(data, []byte(arvKey+"</key><true"))
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
