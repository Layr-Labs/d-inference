package api

import (
	"os"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/trial"
)

// readBonsaiTrialConfig does not read or mutate catalog prices. Rates are an
// explicit launch snapshot derived from the verified Qwen reference prices.
func readBonsaiTrialConfig() trial.Config {
	c := trial.DefaultConfig()
	c.Enabled = env.EnvBool(env.EnvPrefix+"_BONSAI_TRIAL_ENABLED", false)
	c.ModelIDs = ParseCommaList(env.EnvOr(env.EnvPrefix+"_BONSAI_TRIAL_MODELS", trial.BonsaiBuildID))
	c.Rates.InputMicroUSDPerMillion = trialPriceEnv("INPUT")
	c.Rates.OutputMicroUSDPerMillion = trialPriceEnv("OUTPUT")
	return c
}

func trialPriceEnv(direction string) int64 {
	v, err := strconv.ParseInt(strings.TrimSpace(os.Getenv(env.EnvPrefix+"_BONSAI_TRIAL_"+direction+"_PRICE")), 10, 64)
	if err != nil {
		return 0
	}
	return v
}

func normalizedTrialConfig(c trial.Config) trial.Config {
	if c.CampaignID == "" {
		c.CampaignID = trial.DefaultCampaignID
	}
	if c.TokenLimit == 0 {
		c.TokenLimit = trial.DefaultTokenLimit
	}
	if len(c.ModelIDs) == 0 {
		c.ModelIDs = []string{trial.BonsaiBuildID}
	}
	c.ModelIDs = append([]string(nil), c.ModelIDs...)
	return c
}
