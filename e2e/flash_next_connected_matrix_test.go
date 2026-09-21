package e2e

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// Opt-in real Go coordinator + native Qwen4 provider. No M5/NAX or Qwen3.5
// fixture substitution; no hosted/account/attestation certification claim.
func TestIntegration_FlashNextConnectedMatrices(t *testing.T) {
	if os.Getenv("DARKBLOOM_FLASH_NEXT_CONNECTED_MATRIX") != "1" {
		t.Skip("requires an explicitly owned native Qwen4 model/window and matrix runner")
	}
	runFlashNextConnectedSuites(t, []string{"api_matrix", "responses_matrix", "reasoning_on_matrix", "invalid_reasoning_matrix", "multi_tool_matrix"})
}

func TestIntegration_FlashNextExtendedMatrices(t *testing.T) {
	if os.Getenv("DARKBLOOM_FLASH_NEXT_EXTENDED_MATRIX") != "1" {
		t.Skip("requires the original private fidelity/media fixtures and an owned native Qwen4 window")
	}
	runFlashNextConnectedSuites(t, []string{"weather", "fidelity", "heldout", "multimodal"})
}

func runFlashNextConnectedSuites(t *testing.T, suites []string) {
	t.Helper()
	require.Equal(t, flashNextMatrixModel, testbed.DefaultTestModelID())
	mode := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_MTP")
	require.Contains(t, []string{"off", "auto"}, mode)
	modelPath := os.Getenv("DARKBLOOM_QWEN4_MODEL_PATH")
	require.True(t, filepath.IsAbs(modelPath))
	config, err := os.ReadFile(filepath.Join(modelPath, "config.json"))
	require.NoError(t, err)
	configHash := sha256.Sum256(config)
	require.Equal(t, "319b334a1abb705acf06035aa0331bcb7c25976ff93a5035b543548738a10824", hex.EncodeToString(configHash[:]))
	var modelConfig map[string]any
	require.NoError(t, json.Unmarshal(config, &modelConfig))
	require.Equal(t, "qwen4_exp", modelConfig["model_type"])
	require.Equal(t, false, modelConfig["language_model_only"])
	output := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_OUTPUT")
	python := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_PYTHON")
	script := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_SCRIPT")
	for _, path := range []string{output, python, script} {
		require.True(t, filepath.IsAbs(path), "matrix inputs must be explicit absolute paths")
	}
	require.NoError(t, os.Mkdir(output, 0700))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	port := listener.Addr().(*net.TCPAddr).Port
	require.NoError(t, listener.Close())
	relay := &testbed.ProviderWireRelay{}
	s := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{ModelID: flashNextMatrixModel, NumProviders: 1}},
		KVBackend:  "paged", ExpectKVBackend: "paged", MaxConcurrent: 1,
		MTPMode: mode, PrefixCacheMode: "off", LocalEndpointPort: port,
		ProviderRelay: relay,
	})
	require.NoError(t, s.Start(context.Background()))
	t.Cleanup(s.Stop)
	require.Len(t, s.Providers, 1)
	ids := s.Coordinator.Registry.ProviderIDs()
	require.Len(t, ids, 1)
	providerID := ids[0]
	key := filepath.Join(output, "synthetic-coordinator-key")
	require.NoError(t, os.WriteFile(key, []byte("testbed-admin-key"), 0600))
	nativeKey := filepath.Join(s.Providers[0].StateDir, "local", "local_token")
	metricsURL := "http://127.0.0.1:" + strconv.Itoa(port)
	require.NoError(t, flashNextMatrixWrite(filepath.Join(output, "binding.json"), map[string]any{
		"model": flashNextMatrixModel, "model_config_sha256": hex.EncodeToString(configHash[:]),
		"mtp_mode": mode, "coordinator": s.Coordinator.BaseURL(), "native_metrics": metricsURL,
		"provider_count": 1, "kv_backend": "paged", "prefix_cache": "off",
		"suites": suites,
		"scope":  "Real loopback Go coordinator/provider with synthetic auth, TrustNone and mock payments; not hosted or signed trust qualification.",
	}))
	for _, name := range suites {
		before, err := flashNextMatrixIdle(s, providerID, mode)
		require.NoError(t, err)
		require.NoError(t, flashNextMatrixWrite(filepath.Join(output, name+".before.json"), before))
		command := exec.CommandContext(s.Ctx, python, "-B", script, "--suite", name,
			"--output", filepath.Join(output, name))
		command.Env = append(os.Environ(),
			"QWEN38_VALIDATION_BASE_URL="+s.Coordinator.BaseURL(),
			"QWEN38_VALIDATION_API_KEY_FILE="+key,
			"QWEN4_NATIVE_METRICS_URL="+metricsURL,
			"QWEN4_NATIVE_METRICS_KEY_FILE="+nativeKey)
		log, err := os.OpenFile(filepath.Join(output, name+".log"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		require.NoError(t, err)
		command.Stdout, command.Stderr = log, log
		runErr := command.Run()
		require.NoError(t, log.Close())
		if runErr != nil {
			t.Errorf("unchanged %s matrix failed: %v (private receipt retained)", name, runErr)
		}
		after, err := flashNextMatrixIdle(s, providerID, mode)
		require.NoError(t, err)
		require.NoError(t, flashNextMatrixWrite(filepath.Join(output, name+".after.json"), after))
		events, dropped := relay.Snapshot()
		require.Zero(t, dropped, "wire observation overflow is not complete evidence")
		routed := 0
		for _, event := range events {
			if event.Type == "inference_request" && event.Direction == "coordinator_to_provider" {
				var encrypted bool
				require.NoError(t, json.Unmarshal(event.Fields["encrypted_body_present"], &encrypted))
				require.True(t, encrypted, "real routed requests must retain encrypted bodies")
				routed++
			}
		}
		require.Positive(t, routed, "passing API results need witnessed real provider dispatch")
		require.NoError(t, flashNextMatrixWrite(filepath.Join(output, name+".wire.json"), events))
		t.Logf("connected matrix %s completed, passed=%t", name, runErr == nil)
	}
	assertAccounting(t, s)
}
