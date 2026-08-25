package mdm

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const responseTestCommandUUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

func TestLookupDeviceRejectsHTTPAndSchemaFailures(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
	}{
		{"non-2xx with valid JSON", http.StatusInternalServerError, `{"devices":[]}`},
		{"malformed JSON", http.StatusOK, `{"devices":`},
		{"missing devices", http.StatusOK, `{}`},
		{"null devices", http.StatusOK, `{"devices":null}`},
		{
			"missing enrollment status",
			http.StatusOK,
			`{"devices":[{"serial_number":"SERIAL","udid":"UDID"}]}`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := responseTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tt.status)
				_, _ = io.WriteString(w, tt.body)
			}))

			if _, err := client.LookupDevice(context.Background(), "SERIAL"); err == nil {
				t.Fatal("LookupDevice accepted an invalid response")
			}
		})
	}
}

func TestLookupDeviceDoesNotFollowRedirects(t *testing.T) {
	var followed bool
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/devices", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Location", "/redirect-target")
		w.WriteHeader(http.StatusFound)
	})
	mux.HandleFunc("GET /redirect-target", func(w http.ResponseWriter, _ *http.Request) {
		followed = true
		_, _ = io.WriteString(w, `{"devices":[]}`)
	})
	client := responseTestClient(t, mux)

	_, err := client.LookupDevice(context.Background(), "SERIAL")
	if err == nil || !strings.Contains(err.Error(), "HTTP 302") {
		t.Fatalf("LookupDevice error = %v, want explicit HTTP 302 rejection", err)
	}
	if followed {
		t.Fatal("MDM client followed a redirect")
	}
}

func TestSecurityInfoCommandValidatesStatusAndSchema(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		wantErr bool
	}{
		{"200 accepted", http.StatusOK, commandResponse(responseTestCommandUUID), false},
		{"201 accepted", http.StatusCreated, commandResponse(responseTestCommandUUID), false},
		{"non-2xx valid body", http.StatusInternalServerError, commandResponse(responseTestCommandUUID), true},
		{"malformed JSON", http.StatusCreated, `{"payload":`, true},
		{"missing payload", http.StatusCreated, `{}`, true},
		{"invalid UUID", http.StatusCreated, commandResponse("predictable"), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := responseTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tt.status)
				_, _ = io.WriteString(w, tt.body)
			}))

			got, err := client.SendSecurityInfoCommand(context.Background(), "UDID")
			if tt.wantErr {
				if err == nil {
					t.Fatal("SendSecurityInfoCommand accepted an invalid response")
				}
				if _, tracked := client.consumeCommand(responseTestCommandUUID, time.Now()); tracked {
					t.Fatal("invalid response registered an outstanding command")
				}
				return
			}
			if err != nil {
				t.Fatalf("SendSecurityInfoCommand: %v", err)
			}
			if got != responseTestCommandUUID {
				t.Fatalf("command UUID = %q", got)
			}
		})
	}
}

func TestRawCommandValidatesStatusAndSchema(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
	}{
		{"non-2xx", http.StatusBadGateway, `{}`},
		{"malformed JSON", http.StatusCreated, `{"payload":`},
		{
			"mismatched payload",
			http.StatusCreated,
			`{"payload":{"udid":"OTHER","command_uuid":"wrong","command":{"request_type":"DeviceLock"}}}`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := responseTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tt.status)
				_, _ = io.WriteString(w, tt.body)
			}))

			if _, err := client.SendDeviceAttestationCommand(
				context.Background(),
				"UDID",
				"bm9uY2U=",
			); err == nil {
				t.Fatal("SendDeviceAttestationCommand accepted an invalid response")
			}
		})
	}
}

func TestPushValidatesStatusAndSchema(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		wantErr bool
	}{
		{
			"valid",
			http.StatusOK,
			`{"status":"success","push_notification_id":"push-id"}`,
			false,
		},
		{"non-2xx", http.StatusBadGateway, `{"status":"success","push_notification_id":"push-id"}`, true},
		{"malformed", http.StatusOK, `{"status":`, true},
		{"failure status", http.StatusOK, `{"status":"failure","push_notification_id":"push-id"}`, true},
		{"missing id", http.StatusOK, `{"status":"success"}`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := responseTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tt.status)
				_, _ = io.WriteString(w, tt.body)
			}))

			err := client.pushDevice(context.Background(), "UDID")
			if (err != nil) != tt.wantErr {
				t.Fatalf("pushDevice error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func responseTestClient(t *testing.T, handler http.Handler) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return NewClient(
		server.URL,
		"test-key",
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
}

func commandResponse(commandUUID string) string {
	return `{"payload":{"command_uuid":"` + commandUUID + `"}}`
}
