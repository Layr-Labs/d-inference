package api

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"io"
	"net/http"
	"strings"
	"sync"
)

// fakeMDMServer is a minimal MicroMDM stand-in for exercising
// verifyProviderViaMDM against a real *mdm.Client over HTTP. The test drives the
// SecurityInfo response itself by calling mdmClient.HandleWebhook with a webhook
// body whose CommandUUID matches the one this server hands out.
type fakeMDMServer struct {
	mu sync.Mutex

	device      *mdm.DeviceInfo // nil → device-not-found
	commandUUID string          // returned by POST /v1/commands

	// failMDARawCommand makes POST /v1/commands/{udid} (the raw-plist MDA path)
	// return 500 so verifyAppleDeviceAttestation aborts immediately instead of
	// blocking 60s waiting for an Apple attestation webhook in the success test.
	failMDARawCommand bool

	mdaCommandUUID string

	// failSecurityInfoCommand makes POST /v1/commands (the SecurityInfo enqueue)
	// return a 500 so mdm.SendSecurityInfoCommand errors — simulating a transient
	// MicroMDM transport failure. This must NOT hard-untrust an enrolled provider.
	failSecurityInfoCommand bool

	// failDeviceLookup makes POST /v1/devices return 500 so mdm.LookupDevice errors
	// ("device lookup failed: ...") — simulating a MicroMDM outage. The device may
	// be enrolled; this must bucket as "error", not an enrollment failure.
	failDeviceLookup bool

	pushedUDIDs []string
}

func (f *fakeMDMServer) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /v1/devices", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		f.mu.Lock()
		dev := f.device
		failLookup := f.failDeviceLookup
		f.mu.Unlock()
		if failLookup {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("micromdm device lookup unavailable"))
			return
		}
		resp := map[string]any{"devices": []mdm.DeviceInfo{}}
		if dev != nil {
			resp["devices"] = []mdm.DeviceInfo{*dev}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	// SecurityInfo command (structured endpoint). MicroMDM's POST /v1/commands
	// enqueues AND sends the APNs push itself, so we record a push here to model
	// that auto-push (the coordinator no longer issues a separate GET /push for
	// SecurityInfo). pushCount() rising is how deliverWebhookWhenPushed knows the
	// command went out.
	mux.HandleFunc("POST /v1/commands", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			UDID string `json:"udid"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		uuid := f.commandUUID
		fail := f.failSecurityInfoCommand
		if !fail {
			f.pushedUDIDs = append(f.pushedUDIDs, body.UDID) // MicroMDM auto-push
		}
		f.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("micromdm unavailable"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"payload":{"command_uuid":"` + uuid + `"}}`))
	})

	// MDA raw-plist command (POST /v1/commands/{udid}).
	mux.HandleFunc("POST /v1/commands/{udid}", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		commandUUID := ""
		if marker := strings.Index(string(body), "<key>CommandUUID</key>"); marker >= 0 {
			rest := string(body)[marker:]
			if start := strings.Index(rest, "<string>"); start >= 0 {
				rest = rest[start+len("<string>"):]
				if end := strings.Index(rest, "</string>"); end >= 0 {
					commandUUID = rest[:end]
				}
			}
		}
		f.mu.Lock()
		fail := f.failMDARawCommand
		f.mdaCommandUUID = commandUUID
		f.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("mda unavailable in test"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("GET /push/{udid}", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.pushedUDIDs = append(f.pushedUDIDs, r.PathValue("udid"))
		f.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	return mux
}

func (f *fakeMDMServer) pushCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.pushedUDIDs)
}

func (f *fakeMDMServer) lastMDACommandUUID() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.mdaCommandUUID
}

// securityInfoWebhook builds a MicroMDM acknowledge webhook body carrying a
// SecurityInfo plist with the given CommandUUID and SIP/SecureBoot posture.
func securityInfoWebhook(udid, commandUUID string, sipEnabled bool, secureBootFull bool) []byte {
	sip := "<false/>"
	if sipEnabled {
		sip = "<true/>"
	}
	sb := "reduced"
	if secureBootFull {
		sb = "full"
	}
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict>`+
		`<key>CommandUUID</key><string>%s</string>`+
		`<key>Status</key><string>Acknowledged</string>`+
		`<key>SecurityInfo</key><dict>`+
		`<key>SystemIntegrityProtectionEnabled</key>%s`+
		`<key>SecureBootLevel</key><string>%s</string>`+
		`</dict></dict></plist>`, commandUUID, sip, sb)
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

func deviceAttestationWebhook(udid, commandUUID string, certChain ...[]byte) []byte {
	var certs strings.Builder
	for _, cert := range certChain {
		fmt.Fprintf(&certs, "<data>%s</data>", base64.StdEncoding.EncodeToString(cert))
	}
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict>`+
		`<key>CommandUUID</key><string>%s</string>`+
		`<key>Status</key><string>Acknowledged</string>`+
		`<key>DevicePropertiesAttestation</key><array>%s</array>`+
		`</dict></plist>`, commandUUID, certs.String())
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

// mdmReliabilityServer builds a coordinator Server wired to a fake MicroMDM and
// registers one provider holding a valid attestation result (serial + SIP +
// SecureBoot + SE public key), at self_signed trust. It returns the server, the
// fake, and the live *registry.Provider.
