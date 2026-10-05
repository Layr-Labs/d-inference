package mdm_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/mdm"
)

func TestReadConfigDefaultsTheAPIKey(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MDM_URL", "")
	t.Setenv("EIGENINFERENCE_MDM_API_KEY", "")
	cfg := production.ReadConfig()
	if cfg.URL != "" || cfg.APIKey != "eigeninference-micromdm-api" {
		t.Fatalf("defaults = %+v", cfg)
	}
	if err := cfg.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}

	t.Setenv("EIGENINFERENCE_MDM_URL", "http://127.0.0.1:9000")
	t.Setenv("EIGENINFERENCE_MDM_API_KEY", "configured-key")
	cfg = production.ReadConfig()
	if cfg.URL != "http://127.0.0.1:9000" || cfg.APIKey != "configured-key" {
		t.Fatalf("overrides = %+v", cfg)
	}
}
