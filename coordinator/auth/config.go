package auth

import "os"

// ReadConfig reads Privy authentication configuration from environment
// variables. Supports reading the verification key from a file when
// EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE is set.
// The Config type is defined in privy.go.
func ReadConfig() Config {
	verificationKey := os.Getenv("EIGENINFERENCE_PRIVY_VERIFICATION_KEY")
	if keyFile := os.Getenv("EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE"); keyFile != "" {
		if data, err := os.ReadFile(keyFile); err == nil {
			verificationKey = string(data)
		}
	}
	return Config{
		AppID:           os.Getenv("EIGENINFERENCE_PRIVY_APP_ID"),
		AppSecret:       os.Getenv("EIGENINFERENCE_PRIVY_APP_SECRET"),
		VerificationKey: verificationKey,
	}
}
