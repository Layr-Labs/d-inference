package api

import (
	"crypto/subtle"
	_ "embed"
	"io"
	"net/http"
)

// maxMDMWebhookBodyBytes caps the MicroMDM webhook body. SecurityInfo /
// DevicePropertiesAttestation responses are a few KB; 1 MiB is generous headroom
// while preventing an unauthenticated caller from exhausting memory via an
// unbounded body.
const maxMDMWebhookBodyBytes = 1 << 20 // 1 MiB

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
//
// Defense layers (the endpoint is reachable but cannot forge trust):
//  1. Body cap — bounds memory for the unauthenticated path.
//  2. Optional shared secret — when configured, rejects callers without it
//     before reading the body.
//  3. Solicited-command gate (in mdm.Client.HandleWebhook) — only responses
//     whose CommandUUID matches a command the coordinator actually issued are
//     acted on, so a forged SecurityInfo can never drive a trust upgrade.
func (s *Server) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	if s.mdmWebhookSecret != "" && !s.mdmWebhookTokenValid(r) {
		s.logger.Warn("mdm webhook rejected: missing/invalid shared secret", "remote_addr", r.RemoteAddr)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMDMWebhookBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.logger.Debug("mdm webhook received", "body_size", len(body), "body_preview", string(body[:min(len(body), 500)]))
	if s.mdmClient != nil {
		s.mdmClient.HandleWebhook(body)
	}
	w.WriteHeader(http.StatusOK)
}

// mdmWebhookTokenValid reports whether the request carries the configured MDM
// webhook secret, via either the X-Webhook-Token header or a ?token= query
// param. Comparison is constant-time. Only called when a secret is configured.
func (s *Server) mdmWebhookTokenValid(r *http.Request) bool {
	token := r.Header.Get("X-Webhook-Token")
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	return token != "" &&
		subtle.ConstantTimeCompare([]byte(token), []byte(s.mdmWebhookSecret)) == 1
}

//go:embed install.sh
var installScript []byte

// installScriptPlaceholder is substituted with the coordinator's public URL at
// serve time. Keep in sync with coordinator/internal/api/install.sh.
//
// The legacy install.sh also substituted __DARKBLOOM_R2_CDN_URL__ and
// __DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__ for the Python runtime download.
// Post-Swift-cutover (v0.5.0+) install.sh no longer touches R2 directly --
// model downloads run inside `darkbloom models download` against the public
// R2 CDN -- so only the coordinator URL needs serve-time templating.
const installScriptPlaceholder = "__DARKBLOOM_COORD_URL__"
