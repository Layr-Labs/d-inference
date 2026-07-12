//go:build pilotload

package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultPilotFundingMicroUSD int64 = 1_000_000_000_000

type pilotKeySeeder interface {
	SeedKey(string) error
}

func pilotListenAddress(port string) string {
	return "127.0.0.1:" + port
}

func seedPilotLoadState(st store.Store) error {
	if os.Getenv("EIGENINFERENCE_PILOT_LOAD_ENABLED") != "true" {
		return nil
	}
	consumerKey := os.Getenv("EIGENINFERENCE_PILOT_CONSUMER_KEY")
	modelID := os.Getenv("EIGENINFERENCE_PILOT_MODEL_ID")
	aliasID := os.Getenv("EIGENINFERENCE_PILOT_MODEL_ALIAS")
	if consumerKey == "" || modelID == "" || aliasID == "" || aliasID == modelID {
		return fmt.Errorf("pilot consumer key, concrete model, and distinct alias are required")
	}
	keySeeder, ok := st.(pilotKeySeeder)
	if !ok {
		return fmt.Errorf("pilot-load state requires a store that can seed fixed API keys")
	}
	if err := keySeeder.SeedKey(consumerKey); err != nil {
		return fmt.Errorf("seed pilot consumer key: %w", err)
	}

	funding := defaultPilotFundingMicroUSD
	if encoded := os.Getenv("EIGENINFERENCE_PILOT_FUNDING_MICRO_USD"); encoded != "" {
		parsed, err := strconv.ParseInt(encoded, 10, 64)
		if err != nil || parsed <= 0 {
			return fmt.Errorf("EIGENINFERENCE_PILOT_FUNDING_MICRO_USD must be a positive integer")
		}
		funding = parsed
	}
	if _, err := st.CreditWithdrawableOnce(
		store.LegacyAccountID(consumerKey),
		funding,
		store.LedgerAdminReward,
		"objective9:initial-funding",
	); err != nil {
		return fmt.Errorf("fund pilot consumer: %w", err)
	}

	entry := &store.ModelRegistryEntry{
		ID:               modelID,
		DisplayName:      "Objective 9 Pilot",
		Family:           "pilot",
		Architecture:     "synthetic",
		Quantization:     "test",
		MaxContextLength: 131_072,
		MaxOutputLength:  16_384,
		MinRAMGB:         1,
		Capabilities:     []string{"chat"},
		Status:           "active",
		Description:      "Isolated objective-9 synthetic load model",
		CreatedAt:        time.Now().UTC(),
	}
	version := &store.ModelVersion{
		ModelID:        modelID,
		Version:        "objective9-v1",
		R2Prefix:       "pilot/objective9",
		TotalSizeBytes: 1,
		Status:         "ready",
		UploadedBy:     "pilot-load",
	}
	if err := st.SetModelVersion(entry, version, nil); err != nil {
		return fmt.Errorf("seed pilot model: %w", err)
	}
	if err := st.PromoteModelVersion(modelID, version.Version); err != nil {
		return fmt.Errorf("promote pilot model: %w", err)
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID:      aliasID,
		DisplayName:  "Objective 9 Pilot",
		DesiredBuild: modelID,
		Active:       true,
	}); err != nil {
		return fmt.Errorf("seed pilot model alias: %w", err)
	}
	return nil
}
