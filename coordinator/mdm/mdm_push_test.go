package mdm

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeMicroMDM is a minimal stand-in for MicroMDM driven entirely over HTTP. It
// records the explicit APNs push (GET /push/{udid}) so tests can prove the
// SecurityInfo leg now wakes the device, returns a deterministic command_uuid
// from POST /v1/commands, and serves a configurable device record from POST
// /v1/devices. The SecurityInfo response itself is delivered out-of-band by the
// test calling client.HandleWebhook (the webhook path MicroMDM uses in prod).
type fakeMicroMDM struct {
	mu sync.Mutex

	// device returned by LookupDevice. nil → "not found" (empty device list).
	device *DeviceInfo

	// commandUUID returned by POST /v1/commands.
	commandUUID string

	// pushedUDIDs records every EXPLICIT GET /push/{udid} the client issued, in
	// order. The structured POST /v1/commands does NOT count here — MicroMDM
	// auto-pushes on that endpoint, so the coordinator must not add a second push.
	pushedUDIDs []string

	// commandPosts counts POST /v1/commands (SecurityInfo enqueues).
	commandPosts int
}

func (f *fakeMicroMDM) handler() http.Handler {
	mux := http.NewServeMux()

	// LookupDevice
	mux.HandleFunc("POST /v1/devices", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		f.mu.Lock()
		dev := f.device
		f.mu.Unlock()
		resp := map[string]any{"devices": []DeviceInfo{}}
		if dev != nil {
			resp["devices"] = []DeviceInfo{*dev}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	// SendSecurityInfoCommand
	mux.HandleFunc("POST /v1/commands", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		f.mu.Lock()
		uuid := f.commandUUID
		f.commandPosts++
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"payload":{"command_uuid":"` + uuid + `"}}`))
	})

	// Explicit APNs push — record that it fired and for which UDID.
	mux.HandleFunc("GET /push/{udid}", func(w http.ResponseWriter, r *http.Request) {
		udid := r.PathValue("udid")
		f.mu.Lock()
		f.pushedUDIDs = append(f.pushedUDIDs, udid)
		f.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	return mux
}

func (f *fakeMicroMDM) pushes() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.pushedUDIDs))
	copy(out, f.pushedUDIDs)
	return out
}

func (f *fakeMicroMDM) commandPostCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.commandPosts
}

func newFakeMDM(t *testing.T, fake *fakeMicroMDM) (*Client, *httptest.Server) {
	t.Helper()
	ts := httptest.NewServer(fake.handler())
	t.Cleanup(ts.Close)
	c := NewClient(ts.URL, "test-key", slog.New(slog.NewTextHandler(io.Discard, nil)))
	return c, ts
}

// TestSendSecurityInfoCommandDoesNotDoublePush: the structured POST /v1/commands
// already makes MicroMDM send the APNs push, so SendSecurityInfoCommand must NOT
// issue a second explicit GET /push/{udid} — a double push wastes Apple's MDM push
// budget (the pressure this whole change reduces). It enqueues exactly one command
// and returns the command_uuid; zero explicit pushes.
func TestSendSecurityInfoCommandDoesNotDoublePush(t *testing.T) {
	fake := &fakeMicroMDM{commandUUID: "cmd-abc-123"}
	c, _ := newFakeMDM(t, fake)

	gotUUID, err := c.SendSecurityInfoCommand(context.Background(), "UDID-PUSH")
	if err != nil {
		t.Fatalf("SendSecurityInfoCommand: %v", err)
	}
	if gotUUID != "cmd-abc-123" {
		t.Errorf("command_uuid = %q, want %q", gotUUID, "cmd-abc-123")
	}
	if n := fake.commandPostCount(); n != 1 {
		t.Errorf("command posts = %d, want exactly 1", n)
	}
	if pushes := fake.pushes(); len(pushes) != 0 {
		t.Errorf("explicit GET /push count = %d, want 0 (MicroMDM auto-pushes on /v1/commands)", len(pushes))
	}
}

// TestVerifyProviderSuccess walks the full happy path: device enrolled, then a
// solicited SecurityInfo webhook arrives with SIP enabled + Secure Boot full
// matching the provider's attestation. VerifyProvider returns DeviceEnrolled
// with no Error.
func TestVerifyProviderSuccess(t *testing.T) {
	fake := &fakeMicroMDM{
		device: &DeviceInfo{
			SerialNumber:     "SERIAL-OK",
			UDID:             "UDID-OK",
			EnrollmentStatus: true,
		},
		commandUUID: "cmd-ok",
	}
	c, _ := newFakeMDM(t, fake)

	// Deliver the SecurityInfo response shortly after the verifier registers its
	// waiter. buildSecurityInfoWebhook reports SIP=true, SecureBoot=full.
	go func() {
		// Wait until the command has been POSTed (uuid tracked + waiter registered),
		// then deliver the webhook. (SecurityInfo no longer issues an explicit push,
		// so gate on the command post, not a push.)
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if fake.commandPostCount() > 0 {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		time.Sleep(20 * time.Millisecond)
		c.HandleWebhook(buildSecurityInfoWebhook("UDID-OK", "cmd-ok"))
	}()

	res, err := c.VerifyProvider(context.Background(), "SERIAL-OK", true /*sip*/, true /*secureboot*/)
	if err != nil {
		t.Fatalf("VerifyProvider returned transport error: %v", err)
	}
	if !res.DeviceEnrolled {
		t.Errorf("DeviceEnrolled = false, want true")
	}
	if res.Error != "" {
		t.Errorf("Error = %q, want empty on success", res.Error)
	}
	if !res.MDMSIPEnabled || !res.MDMSecureBootFull {
		t.Errorf("SIP=%v SecureBootFull=%v, want both true", res.MDMSIPEnabled, res.MDMSecureBootFull)
	}
	if !res.SIPMatch || !res.SecureBootMatch {
		t.Errorf("SIPMatch=%v SecureBootMatch=%v, want both true", res.SIPMatch, res.SecureBootMatch)
	}
}

// TestVerifyProviderTimeout: device is enrolled but no SecurityInfo webhook ever
// arrives, so the 90s waiter times out. We shrink the wait by NOT delivering a
// webhook and overriding the client to a short timeout is not possible (the
// 90s is hardcoded), so instead we assert the timeout-error semantics via the
// lower-level WaitForSecurityInfo with a short timeout — the same error string
// ("timeout") that VerifyProvider surfaces into result.Error and that
// verifyProviderViaMDM buckets as securityinfo-timeout.
func TestVerifyProviderTimeoutErrorString(t *testing.T) {
	c := testClient()
	_, err := c.WaitForSecurityInfo(context.Background(), "UDID-NO-REPLY", 50*time.Millisecond)
	if err == nil {
		t.Fatal("expected a timeout error when no webhook arrives")
	}
	if !strings.Contains(err.Error(), "timeout") {
		t.Errorf("error = %q, want it to contain %q", err.Error(), "timeout")
	}
}

// TestVerifyProviderDeviceNotFound: LookupDevice returns no matching device, so
// VerifyProvider reports DeviceEnrolled=false and an Error mentioning "not
// found" — the signal verifyProviderViaMDM buckets as device-not-found.
func TestVerifyProviderDeviceNotFound(t *testing.T) {
	fake := &fakeMicroMDM{device: nil, commandUUID: "unused"}
	c, _ := newFakeMDM(t, fake)

	res, err := c.VerifyProvider(context.Background(), "SERIAL-MISSING", true, true)
	if err != nil {
		t.Fatalf("VerifyProvider transport error: %v", err)
	}
	if res.DeviceEnrolled {
		t.Errorf("DeviceEnrolled = true, want false for a missing device")
	}
	if !strings.Contains(res.Error, "not found") {
		t.Errorf("Error = %q, want it to contain %q", res.Error, "not found")
	}
	// A device that was never found must not have triggered any command/push.
	if len(fake.pushes()) != 0 {
		t.Errorf("push count = %d, want 0 (no command for a missing device)", len(fake.pushes()))
	}
}
