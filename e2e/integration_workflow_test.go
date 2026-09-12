package e2e

import (
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

// The public HF fixture is intentionally outside the exact release allowlist.
// Pin that identity with its backend assertion, and keep explicit paged policy
// scoped to its own lanes so it cannot leak into released-provider compatibility.
func TestIntegrationWorkflowBackendLaneIsolation(t *testing.T) {
	var workflow struct {
		Jobs map[string]struct {
			Env   map[string]string `yaml:"env"`
			Steps []struct {
				Name            string            `yaml:"name"`
				Run             string            `yaml:"run"`
				Env             map[string]string `yaml:"env"`
				ContinueOnError bool              `yaml:"continue-on-error"`
			} `yaml:"steps"`
		} `yaml:"jobs"`
	}
	raw, err := os.ReadFile("../.github/workflows/integration.yml")
	require.NoError(t, err)
	require.NoError(t, yaml.Unmarshal(raw, &workflow))
	job, ok := workflow.Jobs["integration-tests"]
	require.True(t, ok)
	for _, key := range []string{"DARKBLOOM_TESTBED_KV_BACKEND", "DARKBLOOM_TESTBED_MAX_CONCURRENT", "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND"} {
		require.NotContains(t, job.Env, key, "posture must not affect released-provider lanes")
	}
	var paged, defaults, exact int
	for _, step := range job.Steps {
		switch {
		case strings.Contains(step.Run, "-run 'TestIntegration|TestProfile'"):
			paged++
			require.False(t, step.ContinueOnError)
			require.Equal(t, testbed.KVBackendPaged, step.Env["DARKBLOOM_TESTBED_KV_BACKEND"])
			require.Equal(t, testbed.KVBackendPaged, step.Env["DARKBLOOM_TESTBED_EXPECT_KV_BACKEND"])
			require.Equal(t, "8", step.Env["DARKBLOOM_TESTBED_MAX_CONCURRENT"])
		case strings.Contains(step.Run, "-run '^TestIntegration_(NonStreaming|Streaming)Inference$'"):
			defaults++
			require.False(t, step.ContinueOnError)
			require.Equal(t, "mlx-community/gpt-oss-20b-MXFP4-Q8", step.Env["DARKBLOOM_TESTBED_MODEL"])
			require.Equal(t, testbed.KVBackendContiguous, step.Env["DARKBLOOM_TESTBED_EXPECT_KV_BACKEND"])
			require.NotContains(t, step.Env, "DARKBLOOM_TESTBED_KV_BACKEND")
			require.NotContains(t, step.Env, "DARKBLOOM_TESTBED_MAX_CONCURRENT")
		case strings.Contains(step.Run, "-run '^TestIntegrationExactCacheRouting$'"):
			exact++
			require.Equal(t, testbed.KVBackendPaged, step.Env["DARKBLOOM_TESTBED_KV_BACKEND"])
			require.NotContains(t, step.Env, "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND", "prewarming perturbs cold/adopted evidence")
		}
	}
	require.Equal(t, 1, paged)
	require.Equal(t, 1, defaults)
	require.Equal(t, 1, exact)
}

func TestIntegrationWorkflowIncludesTestbedCPUChecks(t *testing.T) {
	var workflow struct {
		Jobs map[string]struct {
			Steps []struct {
				Run             string `yaml:"run"`
				ContinueOnError bool   `yaml:"continue-on-error"`
			} `yaml:"steps"`
		} `yaml:"jobs"`
	}
	raw, err := os.ReadFile("../.github/workflows/ci.yml")
	require.NoError(t, err)
	require.NoError(t, yaml.Unmarshal(raw, &workflow))
	job, ok := workflow.Jobs["test-coordinator"]
	require.True(t, ok)
	var testbedChecks, policyChecks int
	for _, step := range job.Steps {
		if strings.Contains(step.Run, "go test -race ./e2e/testbed/...") {
			testbedChecks++
			require.False(t, step.ContinueOnError)
			require.NotContains(t, step.Run, "-run", "the full testbed package must run, including relay regressions")
		}
		if strings.Contains(step.Run, "go test -race ./e2e/ -run '^Test(Qwen38|IntegrationWorkflow)'") {
			policyChecks++
			require.False(t, step.ContinueOnError)
		}
	}
	require.Equal(t, 1, testbedChecks, "root ./e2e/ commands never execute the testbed package")
	require.Equal(t, 1, policyChecks, "CPU CI must execute the Qwen and workflow policy checks")
}
