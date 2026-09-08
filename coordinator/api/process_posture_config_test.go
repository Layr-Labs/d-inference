package api

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProcessPostureConfigDefaultExplicitAndInvalid(t *testing.T) {
	for _, tc := range []struct {
		value          string
		enforce, valid bool
	}{
		{"", true, true}, {"enforce", true, true}, {"shadow", false, true},
		{"off", false, false}, {"SHADOW", false, false}, {" shadow ", false, false}, {"enforc", false, false},
	} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv(ProcessPostureModeEnv, tc.value)
			cfg := ReadServerConfig()
			if err := cfg.ProcessPostureMode.Check(); (err == nil) != tc.valid {
				t.Fatalf("validation: %v", err)
			}
			if !tc.valid {
				defer func() {
					if recover() == nil {
						t.Fatal("invalid programmatic config did not fail construction")
					}
				}()
				NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), cfg, quietLogger())
				return
			}
			s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), cfg, quietLogger())
			t.Cleanup(s.Close)
			if s.processPostureEnforced() != tc.enforce || s.codeAttestThrottle.legacyReuse == tc.enforce {
				t.Fatal("wrong effective mode")
			}
			if !strings.Contains(s.metrics.Snapshot().RenderProm(), `process_posture_policy_mode{mode="`+string(cfg.ProcessPostureMode.normalized())+`"} 1`) {
				t.Fatal("missing effective-mode gauge")
			}
			t.Setenv(ProcessPostureModeEnv, "invalid-later")
			if s.processPostureEnforced() != tc.enforce {
				t.Fatal("running server mode changed with environment")
			}
		})
	}
	t.Run("unset", func(t *testing.T) {
		t.Setenv(ProcessPostureModeEnv, "")
		if err := os.Unsetenv(ProcessPostureModeEnv); err != nil {
			t.Fatal(err)
		}
		if ReadServerConfig().ProcessPostureMode.normalized() != ProcessPostureEnforce {
			t.Fatal("unset must enforce")
		}
	})
}

func TestProcessPostureShadowRetainsLegacyCodeCacheTTLAcrossRestart(t *testing.T) {
	for _, mode := range []ProcessPostureMode{ProcessPostureShadow, ProcessPostureEnforce} {
		t.Run(string(mode), func(t *testing.T) {
			s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{ProcessPostureMode: mode}, quietLogger())
			t.Cleanup(s.Close)
			old := store.CodeAttestation{SEPubKey: "se", Version: "v", APNsToken: "token", NodePublicKey: "process", AttestedAt: time.Now().Add(-24 * time.Hour)}
			s.codeAttestThrottle.seed([]store.CodeAttestation{old})
			if got := s.codeAttestThrottle.reuseAttestation("se", "v", "token", "process"); got != (mode == ProcessPostureEnforce) {
				t.Fatalf("old exact-key cache reuse=%v", got)
			}
		})
	}
}
