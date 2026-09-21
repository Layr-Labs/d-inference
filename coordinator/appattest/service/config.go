package service

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"os"
)

// Serving and migration are independent opt-ins; shadow alone grants no trust.
type Config struct {
	ServingEnabled       bool
	MDMRemovalEnabled    bool
	RolloutPercent       int
	QualifiedBuildHashes string
	QualifiedCodeHashes  string
	ReceiptKeyPath       string
	ReceiptKeyID         string
	Enabled              bool
	AppID                string
	Environment          string
}

func ConfigFromEnvironment() Config {
	environment := os.Getenv(env.EnvPrefix + "_APP_ATTEST_ENVIRONMENT")
	if environment == "" {
		environment = "production"
	}
	return Config{
		ServingEnabled:       env.EnvBool(env.EnvPrefix+"_APP_ATTEST_SERVING", false),
		MDMRemovalEnabled:    env.EnvBool(env.EnvPrefix+"_APP_ATTEST_MDM_REMOVAL", false),
		ReceiptKeyPath:       os.Getenv(env.EnvPrefix + "_APP_ATTEST_RECEIPT_KEY_PATH"),
		ReceiptKeyID:         os.Getenv(env.EnvPrefix + "_APP_ATTEST_RECEIPT_KEY_ID"),
		Enabled:              env.EnvBool(env.EnvPrefix+"_APP_ATTEST_SHADOW", false),
		RolloutPercent:       env.EnvInt(env.EnvPrefix+"_APP_ATTEST_ROLLOUT_PERCENT", 0),
		QualifiedBuildHashes: os.Getenv(env.EnvPrefix + "_APP_ATTEST_QUALIFIED_BUILD_HASHES"),
		QualifiedCodeHashes:  os.Getenv(env.EnvPrefix + "_APP_ATTEST_QUALIFIED_CODE_HASHES"),
		AppID:                env.EnvOr(env.EnvPrefix+"_APP_ATTEST_APP_ID", "SLDQ2GJ6TL.io.darkbloom.provider"),
		Environment:          environment,
	}
}
