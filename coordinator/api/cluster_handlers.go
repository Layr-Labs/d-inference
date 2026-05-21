package api

import (
	"net/http"
)

// clusterPeerKeyResponse is the payload returned by GET /v1/cluster/peer-key.
type clusterPeerKeyResponse struct {
	Serial      string `json:"serial"`
	SEPublicKey string `json:"se_public_key"`
	TrustLevel  string `json:"trust_level"`
	MDAVerified bool   `json:"mda_verified"`
}

// handleClusterPeerKey returns the SE public key for a registered device
// identified by its hardware serial number.
//
// This is used during `darkbloom cluster setup` so rank 0 can pin rank 1's
// SE key (and vice versa) before the first Thunderbolt connection, replacing
// the TOFU (Trust On First Use) disk-file approach with coordinator-verified
// key distribution.
//
// The SE public key is a P-256 public key — not secret — but the endpoint
// requires a Privy session so that only account holders can initiate cluster
// pairings. The key material itself comes from the device's MDM attestation
// record, which was verified by Apple's Enterprise Attestation Root CA.
func (s *Server) handleClusterPeerKey(w http.ResponseWriter, r *http.Request) {
	serial := r.URL.Query().Get("serial")
	if serial == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "serial query parameter required"))
		return
	}

	rec, err := s.store.GetProviderBySerial(r.Context(), serial)
	if err != nil || rec == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found",
			"no registered device with that serial number — ensure the device has run 'darkbloom serve' at least once"))
		return
	}

	if rec.SEPublicKey == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found",
			"device has not completed SE attestation — ensure it has run 'darkbloom serve' and passed the attestation challenge"))
		return
	}

	writeJSON(w, http.StatusOK, clusterPeerKeyResponse{
		Serial:      rec.SerialNumber,
		SEPublicKey: rec.SEPublicKey,
		TrustLevel:  rec.TrustLevel,
		MDAVerified: rec.MDAVerified,
	})
}

// rdmaPeersResponse is the payload returned by GET /v1/cluster/rdma-peers.
type rdmaPeersResponse struct {
	Peers []rdmaPeerInfo `json:"peers"`
}

type rdmaPeerInfo struct {
	Serial      string `json:"serial"`
	SEPublicKey string `json:"se_public_key"`
	TrustLevel  string `json:"trust_level"`
	MDAVerified bool   `json:"mda_verified"`
}

// handleClusterRDMAPeers returns the list of currently-connected providers
// that registered with --rdma-enabled and have completed SE attestation.
//
// Access is symmetric: only callers who themselves own a currently-connected
// RDMA-enabled provider can enumerate the list. Consumers and Privy users
// without an RDMA-enabled provider receive 403. This prevents arbitrary
// authenticated users from scraping hardware serial numbers + SE public keys
// of the RDMA-capable fleet.
//
// The caller's own providers are filtered out of the response — callers see
// only other devices.
//
// Only providers with a completed SE attestation are included — the serial
// and SE public key are required for Keychain key pinning and handshake
// verification. Providers that registered very recently (attestation pending)
// are excluded; retry after a few seconds.
func (s *Server) handleClusterRDMAPeers(w http.ResponseWriter, r *http.Request) {
	callerAccountID := consumerKeyFromContext(r.Context())
	raw, allowed := s.registry.ListRDMAEnabledPeersForCaller(callerAccountID)
	if !allowed {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden",
			"this endpoint is restricted to accounts with a currently-connected --rdma-enabled provider"))
		return
	}

	peers := make([]rdmaPeerInfo, 0, len(raw))
	for _, p := range raw {
		peers = append(peers, rdmaPeerInfo{
			Serial:      p.Serial,
			SEPublicKey: p.SEPublicKey,
			TrustLevel:  string(p.TrustLevel),
			MDAVerified: p.MDAVerified,
		})
	}

	writeJSON(w, http.StatusOK, rdmaPeersResponse{Peers: peers})
}
