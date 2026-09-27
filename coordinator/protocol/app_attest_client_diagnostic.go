package protocol

// ValidClientDiagnostics bounds client-reported failure context before it can
// enter durable evidence or telemetry. These labels never establish trust.
func (p AppAttestShadowPayload) ValidClientDiagnostics() bool {
	if p.AvailabilityReason != "" && p.AppleErrorSource != "" {
		return false
	}
	if p.AvailabilityReason != "" {
		if p.Action != "ready" || p.Result == "ok" {
			return false
		}
		switch p.AvailabilityReason {
		case "os_below_27", "is_supported_false":
			return p.Result == "unsupported"
		case "not_app_bundle", "signing_info_unavailable", "opt_in_missing", "environment_entitlement_invalid":
			return p.Result == "not_configured"
		case "environment_mismatch":
			return p.Result == "environment_mismatch"
		default:
			return false
		}
	}
	if p.AppleErrorSource != "" {
		if p.Result != "apple_error" || p.AppleError != nil {
			return false
		}
		switch p.AppleErrorSource {
		case "callback_without_nserror", "proof_oversize":
		default:
			return false
		}
	}
	return true
}
