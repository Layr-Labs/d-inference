package trust

import (
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	enrollment "github.com/eigeninference/d-inference/coordinator/internal/provider/enrollment"
)

const maxControlPlaneBodyBytes = 64 << 10

// HandleEnroll generates a generic .mobileconfig containing MDM enrollment
// (SCEP + MDM payloads).
//
// The request body is intentionally empty. Older providers may still send a
// serial_number field during rollout; Go's JSON decoder ignores it and the
// coordinator never stores, logs, or embeds it. MicroMDM learns the device
// identity from the authenticated MDM check-in, and trust comes from subsequent
// SecurityInfo/MDA verification rather than possession of this generic profile.
func (s *Owner) HandleEnroll(w http.ResponseWriter, r *http.Request) {
	var req struct{}
	if !httpx.DecodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}

	s.logger.Info("generating enrollment + attestation profile")

	// Use the configured canonical base URL (EIGENINFERENCE_BASE_URL) for the
	// SCEP/MDM enrollment endpoints. Critically, since the profile is now
	// CMS-signed, deriving these from a client-controlled Host header would let an
	// attacker obtain a Darkbloom-signed .mobileconfig that points enrollment at
	// their own host — the signature would launder a malicious enrollment profile.
	// resolveBaseURL pins the configured URL and only falls back to the request
	// Host when no canonical URL is set (local/dev).
	baseURL := s.hooks.ResolveBaseURL(r)

	body := []byte(enrollment.Profile(baseURL))

	// CMS-sign the profile so macOS shows it as signed at install time. Signing is
	// install-time trust only (does not affect the SCEP/MDM chain inside). If
	// no signer is configured or signing fails, serve unsigned so enrollment is
	// never blocked — but make the failure loud (error log + metric).
	switch {
	case s.profileSigner == nil:
		s.observation.Incr("enroll.profile_unsigned", nil)
	default:
		signed, err := s.profileSigner.Sign(body)
		if err != nil {
			s.logger.Error("profile signing failed — serving unsigned profile",
				"error", err)
			s.observation.Incr("enroll.profile_sign_error", nil)
		} else {
			body = signed
			s.observation.Incr("enroll.profile_signed", nil)
		}
	}

	// A signed .mobileconfig keeps the same MIME type as an unsigned one.
	w.Header().Set("Content-Type", "application/x-apple-aspen-config")
	w.Header().Set("Content-Disposition", `attachment; filename="Darkbloom-Enroll.mobileconfig"`)
	w.WriteHeader(http.StatusOK)
	w.Write(body)
}
