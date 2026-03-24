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
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Client talks to the MicroMDM API.
type Client struct {
	baseURL  string
	apiKey   string
	client   *http.Client
	logger   *slog.Logger
	// Webhook responses arrive asynchronously. This channel receives them.
	responses chan *SecurityInfoResponse
}

// NewClient creates an MDM client.
func NewClient(baseURL, apiKey string, logger *slog.Logger) *Client {
	return &Client{
		baseURL: baseURL,
		apiKey:  apiKey,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
		logger:    logger,
		responses: make(chan *SecurityInfoResponse, 16),
	}
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
	UDID                              string
	SystemIntegrityProtectionEnabled  bool
	SecureBootLevel                   string // "full", "reduced", "permissive"
	AuthenticatedRootVolumeEnabled    bool
	FirewallEnabled                   bool
	FileVaultEnabled                  bool
	IsRecoveryLockEnabled             bool
	RemoteDesktopEnabled              bool
}

// VerificationResult from cross-checking MDM with attestation.
type VerificationResult struct {
	DeviceEnrolled    bool
	UDID              string
	SerialNumber      string
	MDMSIPEnabled     bool
	MDMSecureBootFull bool
	MDMAuthRootVolume bool
	SIPMatch          bool   // MDM SIP matches attestation SIP
	SecureBootMatch   bool   // MDM SecureBoot matches attestation
	Error             string
}

// LookupDevice checks if a device with the given serial number is enrolled.
func (c *Client) LookupDevice(serialNumber string) (*DeviceInfo, error) {
	body, _ := json.Marshal(map[string]string{"serial_number": serialNumber})
	req, err := http.NewRequest("POST", c.baseURL+"/v1/devices", bytes.NewReader(body))
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

	if resp.StatusCode != 200 {
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
func (c *Client) SendSecurityInfoCommand(udid string) (string, error) {
	body, _ := json.Marshal(map[string]string{
		"udid":         udid,
		"request_type": "SecurityInfo",
	})
	req, err := http.NewRequest("POST", c.baseURL+"/v1/commands", bytes.NewReader(body))
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

	return result.Payload.CommandUUID, nil
}

// HandleWebhook processes a MicroMDM webhook payload and extracts
// SecurityInfo responses. Call this from your webhook HTTP handler.
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

	if webhook.Event.Status != "Acknowledged" || webhook.Event.RawPayload == "" {
		return
	}

	// Decode the base64 plist payload
	plistData, err := base64.StdEncoding.DecodeString(webhook.Event.RawPayload)
	if err != nil {
		c.logger.Debug("mdm webhook base64 decode failed", "error", err)
		return
	}

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
func (c *Client) VerifyProvider(serialNumber string, attestationSIP, attestationSecureBoot bool) (*VerificationResult, error) {
	result := &VerificationResult{
		SerialNumber: serialNumber,
	}

	// Step 1: Look up device
	device, err := c.LookupDevice(serialNumber)
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

	// Step 2: Send SecurityInfo command
	_, err = c.SendSecurityInfoCommand(device.UDID)
	if err != nil {
		result.Error = fmt.Sprintf("failed to send SecurityInfo command: %v", err)
		return result, nil
	}

	// Step 3: Wait for response (via webhook)
	secInfo, err := c.WaitForSecurityInfo(device.UDID, 30*time.Second)
	if err != nil {
		result.Error = fmt.Sprintf("SecurityInfo response: %v", err)
		return result, nil
	}

	// Step 4: Populate result
	result.MDMSIPEnabled = secInfo.SystemIntegrityProtectionEnabled
	result.MDMSecureBootFull = secInfo.SecureBootLevel == "full"
	result.MDMAuthRootVolume = secInfo.AuthenticatedRootVolumeEnabled

	// Step 5: Cross-check against attestation
	result.SIPMatch = result.MDMSIPEnabled == attestationSIP
	result.SecureBootMatch = result.MDMSecureBootFull == attestationSecureBoot

	if !result.MDMSIPEnabled {
		result.Error = "MDM reports SIP disabled"
	} else if !result.MDMSecureBootFull {
		result.Error = "MDM reports Secure Boot not full"
	} else if !result.SIPMatch {
		result.Error = "attestation SIP does not match MDM SIP — provider may be lying"
	} else if !result.SecureBootMatch {
		result.Error = "attestation SecureBoot does not match MDM — provider may be lying"
	}

	return result, nil
}

// parseSecurityInfoPlist extracts security fields from the MDM response plist.
func parseSecurityInfoPlist(data []byte) *SecurityInfoResponse {
	// MDM responses are Apple plist XML. Parse the relevant fields.
	type PlistDict struct {
		Keys   []string `xml:"key"`
		Values []string `xml:"string"`
		Bools  []bool   `xml:"true,omitempty"`
	}

	// Simple approach: look for known keys in the XML
	result := &SecurityInfoResponse{}
	found := false

	if bytes.Contains(data, []byte("SecurityInfo")) {
		found = true
	}
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
