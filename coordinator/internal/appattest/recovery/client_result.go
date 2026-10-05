package recovery

func ClientResult(value string) string {
	switch value {
	case "unsupported", "not_configured", "environment_mismatch", "keychain_error", "apple_unavailable", "apple_invalid_key", "apple_error", "key_unregistered", "busy", "cancelled", "decryption_failed", "invalid_request", "operation_timeout":
		return value
	}
	return "client_error"
}
