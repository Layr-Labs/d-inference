package mdm

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
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

func buildDeviceAttestationWebhook(udid, commandUUID string, cert []byte) []byte {
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict>`+
		`<key>CommandUUID</key><string>%s</string>`+
		`<key>Status</key><string>Acknowledged</string>`+
		`<key>DevicePropertiesAttestation</key><array><data>%s</data></array>`+
		`</dict></plist>`, commandUUID, base64.StdEncoding.EncodeToString(cert))
	body, _ := json.Marshal(map[string]any{
		"topic": "mdm.Connect",
		"acknowledge_event": map[string]any{
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

func TestDeviceAttestationWaitersCorrelateByCommandUUID(t *testing.T) {
	c := testClient()
	oldWaiter, releaseOld := c.registerDeviceAttestationWaiter("mda-old")
	defer releaseOld()
	newWaiter, releaseNew := c.registerDeviceAttestationWaiter("mda-new")
	defer releaseNew()
	c.trackCommand("mda-old", "UDID-SAME", time.Now())
	c.trackCommand("mda-new", "UDID-SAME", time.Now())

	c.HandleWebhook(buildDeviceAttestationWebhook(
		"UDID-SAME", "mda-new", []byte("new-cert")))
	select {
	case response := <-newWaiter:
		if response.CommandUUID != "mda-new" ||
			string(response.CertChain[0]) != "new-cert" {
			t.Fatalf("new response = %+v", response)
		}
	default:
		t.Fatal("new command response did not reach its exact waiter")
	}
	select {
	case response := <-oldWaiter:
		t.Fatalf("old waiter consumed new response: %+v", response)
	default:
	}

	c.HandleWebhook(buildDeviceAttestationWebhook(
		"UDID-SAME", "mda-old", []byte("old-cert")))
	select {
	case response := <-oldWaiter:
		if response.CommandUUID != "mda-old" ||
			string(response.CertChain[0]) != "old-cert" {
			t.Fatalf("old response = %+v", response)
		}
	default:
		t.Fatal("old command response did not reach its exact waiter")
	}
}

func TestLateDeviceAttestationCallbackPreservesCommandUUID(t *testing.T) {
	c := testClient()
	responses := make(chan *DeviceAttestationResponse, 1)
	c.SetOnMDA(func(response *DeviceAttestationResponse) {
		responses <- response
	})
	c.trackCommand("mda-late", "UDID-LATE", time.Now())

	c.HandleWebhook(buildDeviceAttestationWebhook(
		"UDID-LATE", "mda-late", []byte("late-cert")))

	select {
	case response := <-responses:
		if response.CommandUUID != "mda-late" ||
			response.UDID != "UDID-LATE" ||
			string(response.CertChain[0]) != "late-cert" {
			t.Fatalf("late response = %+v", response)
		}
	default:
		t.Fatal("late callback did not preserve command correlation")
	}
}

func TestDeviceAttestationTimeoutIsTyped(t *testing.T) {
	c := testClient()
	ch, abandon := c.registerDeviceAttestationWaiter("mda-timeout")
	_, err := awaitDeviceAttestation(
		context.Background(),
		ch,
		abandon,
		"UDID-TIMEOUT",
		time.Millisecond,
	)
	if !errors.Is(err, ErrDeviceAttestationTimeout) {
		t.Fatalf("timeout error = %v, want ErrDeviceAttestationTimeout", err)
	}
}

func TestDeviceAttestationClaimAtTimeoutBoundaryIsDelivered(t *testing.T) {
	c := testClient()
	ch, abandon := c.registerDeviceAttestationWaiter("mda-boundary")
	expected := &DeviceAttestationResponse{CommandUUID: "mda-boundary"}

	// Model the webhook's atomic claim-and-enqueue transition immediately before
	// the timeout path attempts to abandon the waiter.
	c.waitMu.Lock()
	waiter := c.attestWaiters["mda-boundary"]
	delete(c.attestWaiters, "mda-boundary")
	waiter <- expected
	c.waitMu.Unlock()

	response, err := awaitDeviceAttestation(
		context.Background(), ch, abandon, "UDID-BOUNDARY", 0)
	if err != nil {
		t.Fatal(err)
	}
	if response != expected {
		t.Fatalf("response = %p, want %p", response, expected)
	}
}

func TestDeviceAttestationAfterTimeoutUsesLateCallback(t *testing.T) {
	c := testClient()
	ch, abandon := c.registerDeviceAttestationWaiter("mda-after-timeout")
	c.trackCommand("mda-after-timeout", "UDID-LATE", time.Now())
	_, err := awaitDeviceAttestation(
		context.Background(), ch, abandon, "UDID-LATE", time.Millisecond)
	if !errors.Is(err, ErrDeviceAttestationTimeout) {
		t.Fatalf("timeout error = %v, want ErrDeviceAttestationTimeout", err)
	}
	responses := make(chan *DeviceAttestationResponse, 1)
	c.SetOnMDA(func(response *DeviceAttestationResponse) {
		responses <- response
	})

	c.HandleWebhook(buildDeviceAttestationWebhook(
		"UDID-LATE", "mda-after-timeout", []byte("late-cert")))

	select {
	case response := <-responses:
		if response.CommandUUID != "mda-after-timeout" {
			t.Fatalf("late command UUID = %q", response.CommandUUID)
		}
	default:
		t.Fatal("post-timeout response did not use the late callback")
	}
}

func TestDeviceAttestationSendErrorPreservesSolicitedOwnership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "ambiguous upstream failure", http.StatusBadGateway)
		},
	))
	defer server.Close()
	client := NewClient(server.URL, "test-key",
		slog.New(slog.NewTextHandler(io.Discard, nil)))

	_, err := client.RequestDeviceAttestation(
		context.Background(),
		"UDID-SEND-ERROR",
		"",
		"mda-send-error",
		time.Millisecond,
	)
	if err == nil {
		t.Fatal("send error was not returned")
	}
	udid, owned := client.consumeCommand("mda-send-error", time.Now())
	if !owned || udid != "UDID-SEND-ERROR" {
		t.Fatalf("solicited ownership = (%q,%v), want preserved", udid, owned)
	}
}
