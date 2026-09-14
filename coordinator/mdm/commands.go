package mdm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"
)

func (c *Client) sendSecurityInfoCommand(
	ctx context.Context,
	udid string,
	bindCommand func(string) bool,
) (string, error) {
	const requestType = "SecurityInfo"
	if err := assertReadOnlyCommand(requestType); err != nil {
		return "", err
	}
	body, _ := json.Marshal(map[string]string{
		"udid": udid, "request_type": requestType,
	})
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost, c.baseURL+"/v1/commands", bytes.NewReader(body),
	)
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
	if result.Payload.CommandUUID == "" {
		return "", errors.New("mdm command response missing command UUID")
	}
	c.trackCommand(result.Payload.CommandUUID, udid, time.Now())
	if !bindCommand(result.Payload.CommandUUID) {
		c.consumeCommand(result.Payload.CommandUUID, time.Now())
		return "", errors.New("mdm SecurityInfo waiter ownership changed before command issue")
	}
	// Structured /v1/commands already sends exactly one MicroMDM APNs push.
	return result.Payload.CommandUUID, nil
}

// sendDeviceAttestationWithNonce queues a raw DeviceInformation plist so Apple
// binds DeviceAttestationNonce into the certificate's FreshnessCode. The caller
// must bind its exclusive waiter before the command is published.
func (c *Client) sendDeviceAttestationWithNonce(
	ctx context.Context,
	udid, nonce string,
	bindCommand func(string) bool,
) (string, error) {
	// DevicePropertiesAttestation is requested via a DeviceInformation command.
	if err := assertReadOnlyCommand("DeviceInformation"); err != nil {
		return "", err
	}
	cmdUUID := uuid.New().String()
	if !bindCommand(cmdUUID) {
		return "", errors.New("mdm device attestation waiter ownership changed before command issue")
	}
	c.trackCommand(cmdUUID, udid, time.Now())

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
		c.consumeCommand(cmdUUID, time.Now())
		return "", err
	}
	req.SetBasicAuth("micromdm", c.apiKey)
	req.Header.Set("Content-Type", "application/xml")

	resp, err := c.client.Do(req)
	if err != nil {
		c.consumeCommand(cmdUUID, time.Now())
		return "", fmt.Errorf("mdm send DeviceInformation with nonce failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		c.consumeCommand(cmdUUID, time.Now())
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("mdm raw command failed (status %d): %s", resp.StatusCode, string(respBody))
	}

	// Push to trigger device check-in (best-effort; command is already queued).
	// The raw POST /v1/commands/{udid} endpoint does NOT auto-push (unlike the
	// structured /v1/commands), so the explicit push is required here.
	c.pushDevice(ctx, udid)

	return cmdUUID, nil
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
