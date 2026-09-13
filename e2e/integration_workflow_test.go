package e2e

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
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
	var selected *regexp.Regexp
	for _, step := range job.Steps {
		if strings.Contains(step.Run, "go test -race ./e2e/testbed/...") {
			testbedChecks++
			require.False(t, step.ContinueOnError)
			require.NotContains(t, step.Run, "-run", "the full testbed package must run, including relay regressions")
		}
		if strings.Contains(step.Run, "go test -race ./e2e/ ") {
			policyChecks++
			require.False(t, step.ContinueOnError)
			filter := regexp.MustCompile(`(?:^|\s)-run\s+'([^']+)'`).FindStringSubmatch(step.Run)
			require.Len(t, filter, 2, "the CPU step must supply a quoted test filter")
			selected, err = regexp.Compile(filter[1])
			require.NoError(t, err)
		}
	}
	require.Equal(t, 1, testbedChecks, "root ./e2e/ commands never execute the testbed package")
	require.Equal(t, 1, policyChecks, "CPU CI must execute the integration fixture-policy checks")

	// Check the actual declared tests so additions within a policy family cannot
	// be silently omitted by a narrower CI expression.
	required := regexp.MustCompile(`^Test(Qwen38|IntegrationWorkflow|ExactCacheRoutingFixture|ReleaseDefault|ReleaseCapability)`)
	files, err := filepath.Glob("*_test.go")
	require.NoError(t, err)
	var checked int
	for _, name := range files {
		file, err := parser.ParseFile(token.NewFileSet(), name, nil, parser.SkipObjectResolution)
		require.NoError(t, err)
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil || !required.MatchString(fn.Name.Name) {
				continue
			}
			checked++
			require.True(t, selected.MatchString(fn.Name.Name), "CPU CI omits %s from %s", fn.Name.Name, name)
		}
	}
	require.Positive(t, checked, "fixture-policy test declarations must be present")
}
