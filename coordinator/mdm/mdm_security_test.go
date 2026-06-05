package mdm

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"
)

func testClient() *Client {
	return NewClient("https://localhost:9002", "test-key",
		slog.New(slog.NewTextHandler(io.Discard, nil)))
}

// TestAssertReadOnlyCommand is the guarantee that the coordinator can only ever
// QUERY a provider's Mac via MDM, never act on it. Read-only queries pass;
// every mutating/destructive command is refused.
func TestAssertReadOnlyCommand(t *testing.T) {
	readOnly := []string{"SecurityInfo", "DeviceInformation"}
	for _, rt := range readOnly {
		if err := assertReadOnlyCommand(rt); err != nil {
			t.Errorf("read-only command %q should be allowed, got %v", rt, err)
		}
	}

	mutating := []string{
		"DeviceLock", "EraseDevice", "RestartDevice", "ShutDownDevice",
		"InstallProfile", "RemoveProfile", "InstallApplication",
		"ClearPasscode", "EnableRemoteDesktop", "ScheduleOSUpdate", "",
	}
	for _, rt := range mutating {
		err := assertReadOnlyCommand(rt)
		if err == nil {
			t.Errorf("mutating command %q MUST be blocked, but was allowed", rt)
		}
		if !errors.Is(err, ErrMutatingCommandBlocked) {
			t.Errorf("command %q: expected ErrMutatingCommandBlocked, got %v", rt, err)
		}
	}
}

func TestParseCommandUUID(t *testing.T) {
	cases := map[string]string{
		`<key>CommandUUID</key><string>abc-123</string>`:     "abc-123",
		"<key>CommandUUID</key>\n\t<string>def-456</string>": "def-456",
		`<dict><key>Other</key><string>x</string></dict>`:    "",
		`<key>CommandUUID</key><string>  spaced  </string>`:  "spaced",
	}
	for plist, want := range cases {
		if got := parseCommandUUID([]byte(plist)); got != want {
			t.Errorf("parseCommandUUID(%q) = %q, want %q", plist, got, want)
		}
	}
}

// TestCommandTrackingLifecycle covers track → consume (one-shot), unknown-UUID
// rejection, and TTL expiry.
func TestCommandTrackingLifecycle(t *testing.T) {
	c := testClient()
	now := time.Now()

	c.trackCommand("uuid-1", "UDID-A", now)

	// Unknown UUID is never solicited.
	if _, ok := c.consumeCommand("nope", now); ok {
		t.Error("unknown command UUID must not be consumable")
	}

	// Known UUID resolves to its UDID, exactly once.
	udid, ok := c.consumeCommand("uuid-1", now)
	if !ok || udid != "UDID-A" {
		t.Fatalf("consumeCommand(uuid-1) = (%q,%v), want (UDID-A,true)", udid, ok)
	}
	if _, ok := c.consumeCommand("uuid-1", now); ok {
		t.Error("command UUID must be one-shot (already consumed)")
	}

	// Expired UUID is rejected.
	c.trackCommand("uuid-2", "UDID-B", now)
	if _, ok := c.consumeCommand("uuid-2", now.Add(outstandingCommandTTL+time.Second)); ok {
		t.Error("expired command UUID must not be consumable")
	}
}

// buildSecurityInfoWebhook builds a MicroMDM acknowledge webhook body carrying a
// SecurityInfo response plist with the given CommandUUID.
func buildSecurityInfoWebhook(udid, commandUUID string) []byte {
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict>`+
		`<key>CommandUUID</key><string>%s</string>`+
		`<key>Status</key><string>Acknowledged</string>`+
		`<key>SecurityInfo</key><dict>`+
		`<key>SystemIntegrityProtectionEnabled</key><true/>`+
		`<key>SecureBootLevel</key><string>full</string>`+
		`</dict></dict></plist>`, commandUUID)
	body, _ := json.Marshal(map[string]any{
		"topic": "mdm.Acknowledge",
		"acknowledge_event": map[string]string{
			"udid":        udid,
			"status":      "Acknowledged",
			"raw_payload": base64.StdEncoding.EncodeToString([]byte(plist)),
		},
	})
	return body
}

// TestWebhookDropsUnsolicitedSecurityInfo is the core anti-forgery guarantee: a
// SecurityInfo webhook whose CommandUUID was never issued by the coordinator is
// dropped before any trust-upgrade callback runs. This is what stops an
// attacker who reaches the (unauthenticated) webhook from forging "SIP=true" to
// elevate a provider to hardware trust.
func TestWebhookDropsUnsolicitedSecurityInfo(t *testing.T) {
	c := testClient()
	var lateFired bool
	c.SetOnLateSecurityInfo(func(udid string, info *SecurityInfoResponse) {
		lateFired = true
	})

	// Forged: no command was ever issued for this UUID.
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-A", "forged-uuid"))
	if lateFired {
		t.Fatal("unsolicited SecurityInfo must NOT trigger the trust-upgrade callback")
	}

	// Solicited: coordinator issued this command UUID for this UDID.
	c.trackCommand("real-uuid", "UDID-A", time.Now())
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-A", "real-uuid"))
	if !lateFired {
		t.Fatal("solicited SecurityInfo response should be honored")
	}
}

// TestWebhookDropsUUIDForDifferentDevice ensures a solicited UUID can't be
// replayed against a different device's webhook event.
func TestWebhookDropsUUIDForDifferentDevice(t *testing.T) {
	c := testClient()
	var fired bool
	c.SetOnLateSecurityInfo(func(udid string, info *SecurityInfoResponse) { fired = true })

	c.trackCommand("uuid-x", "UDID-REAL", time.Now())
	// Same UUID but the webhook claims a different device.
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-EVIL", "uuid-x"))
	if fired {
		t.Fatal("CommandUUID/UDID mismatch must be dropped")
	}
}
