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
