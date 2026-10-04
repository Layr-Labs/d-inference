package mdm

import "testing"

func TestReadConfigDefaultsTheAPIKey(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MDM_URL", "")
	t.Setenv("EIGENINFERENCE_MDM_API_KEY", "")
	cfg := ReadConfig()
	if cfg.URL != "" || cfg.APIKey != defaultMDMApiKey {
		t.Fatalf("defaults = %+v", cfg)
	}
	if err := cfg.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}

	t.Setenv("EIGENINFERENCE_MDM_URL", "http://127.0.0.1:9000")
	t.Setenv("EIGENINFERENCE_MDM_API_KEY", "configured-key")
	cfg = ReadConfig()
	if cfg.URL != "http://127.0.0.1:9000" || cfg.APIKey != "configured-key" {
		t.Fatalf("overrides = %+v", cfg)
	}
}
