package api

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"os"
)

// Only a shadow toggle is provided. Enforcing App Attest requires a separate change.
type AppAttestShadowConfig struct {
	ReceiptKeyPath string
	ReceiptKeyID   string
	Enabled        bool
	AppID          string
	Environment    string
}

func readAppAttestShadowConfig() AppAttestShadowConfig {
	environment := os.Getenv(env.EnvPrefix + "_APP_ATTEST_ENVIRONMENT")
	if environment == "" {
		environment = "production"
	}
	return AppAttestShadowConfig{
		ReceiptKeyPath: os.Getenv(env.EnvPrefix + "_APP_ATTEST_RECEIPT_KEY_PATH"),
		ReceiptKeyID:   os.Getenv(env.EnvPrefix + "_APP_ATTEST_RECEIPT_KEY_ID"),
		Enabled:        env.EnvBool(env.EnvPrefix+"_APP_ATTEST_SHADOW", true),
		AppID:          env.EnvOr(env.EnvPrefix+"_APP_ATTEST_APP_ID", "SLDQ2GJ6TL.io.darkbloom.provider"),
		Environment:    environment,
	}
}
