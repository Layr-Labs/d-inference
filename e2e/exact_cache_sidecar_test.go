package e2e

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// Shared real-sidecar setup: verified files are provisioned and preloaded by
// the same production components; no tokenizer or plan response is mocked.
func startExactCacheSidecar(t *testing.T, suite *testbed.Suite, fixture exactCacheArtifactFixture, model, contractID string) (promptcontract.SupervisorConfig, *promptcontract.Provisioner, *promptcontract.Supervisor, *promptcontract.PreloadController) {
	t.Helper()
	artifactServer := httptest.NewServer(http.HandlerFunc(func(
		w http.ResponseWriter, request *http.Request,
	) {
		name := strings.TrimPrefix(request.URL.Path, "/artifacts/")
		body, ok := fixture.files[name]
		if !ok || name == request.URL.Path {
			http.NotFound(w, request)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		_, _ = w.Write(body)
	}))
	t.Cleanup(artifactServer.Close)
	baseURL, err := url.Parse(artifactServer.URL)
	require.NoError(t, err)

	root := exactCacheTempRoot(t)
	artifactRoot := filepath.Join(root, "contracts")
	socketPath := filepath.Join(root, "prompt-sidecar.sock")
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root:      artifactRoot,
		BaseURL:   baseURL,
		AllowHTTP: true,
	})
	require.NoError(t, err)
	provisioner, err := promptcontract.NewProvisioner(
		suite.Ctx, cache, promptcontract.ProvisionerConfig{
			MaxConcurrent: 1,
			MaxModels:     1,
		})
	require.NoError(t, err)
	fixture.manifest.R2Prefix = "artifacts"
	require.NoError(t, provisioner.Reconcile([]promptcontract.Manifest{fixture.manifest}))
	waitForProvisionedContract(t, provisioner, model, contractID)

	sidecarBinary := exactCacheSidecarBinary(t)
	supervisorConfig := promptcontract.SupervisorConfig{
		Enabled:            true,
		BinaryPath:         sidecarBinary,
		SocketPath:         socketPath,
		ArtifactRoot:       artifactRoot,
		RequestTimeout:     time.Second,
		HeaderReadTimeout:  time.Second,
		StartupTimeout:     10 * time.Second,
		HealthInterval:     time.Second,
		ShutdownTimeout:    5 * time.Second,
		RestartBackoffMin:  50 * time.Millisecond,
		RestartBackoffMax:  time.Second,
		MaxBodyBytes:       4 << 20,
		MaxConcurrency:     2,
		MaxConnections:     8,
		MaxLoadedContracts: 2,
		MaxTokens:          64 << 10,
		MemoryLimitMiB:     1024,
	}
	supervisor := promptcontract.NewSupervisor(supervisorConfig)
	supervisor.Start(suite.Ctx)
	t.Cleanup(supervisor.Close)
	waitForSidecarLive(t, supervisor, 15*time.Second)
	preloader, err := promptcontract.NewPreloadController(
		provisioner,
		supervisor,
		promptcontract.PreloadControllerConfig{PollInterval: 50 * time.Millisecond},
	)
	require.NoError(t, err)
	preloader.Start(suite.Ctx)
	t.Cleanup(preloader.Close)

	suite.Coordinator.Server.SetPromptArtifactProvisioner(provisioner)
	suite.Coordinator.Server.SetPromptContractClient(supervisor.Client())
	suite.Coordinator.Server.SetPromptPreloadController(preloader)
	waitForPreloadedContract(t, preloader, contractID, 30*time.Second)
	return supervisorConfig, provisioner, supervisor, preloader
}
