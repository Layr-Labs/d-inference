package e2e

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

type exactCacheArtifactFixture struct {
	manifest promptcontract.Manifest
	files    map[string][]byte
}

func TestIntegrationExactCacheRouting(t *testing.T) {
	if testing.Short() {
		t.Skip("requires the real Swift provider and local MLX checkpoint")
	}
	model := exactCacheRoutingTestModelID()
	cfg := testbed.SuiteConfig{
		ModelSpecs:                 []testbed.ModelSpec{{ModelID: model, NumProviders: 2}},
		NumUsers:                   2,
		EnableEphemeralPrefixCache: true,
	}

	// Resolve and validate every local input before Suite.Start can allocate a
	// Postgres container or launch a provider. In particular, hashing the exact
	// pinned snapshot here makes a stale/missing HF checkout fail at the
	// prerequisite that caused it rather than after two model loads.
	sidecarBinary := exactCacheSidecarBinary(t)
	snapshot := exactCacheModelSnapshot(t, model)
	fixture := loadExactCacheArtifacts(t, snapshot, model)
	providerBinary, err := testbed.BuildProvider(t.Context(), slog.Default())
	require.NoError(t, err, "exact-cache provider/backend preflight")
	t.Setenv("DARKBLOOM_PROVIDER_BINARY", providerBinary)

	suite := testbed.StartSuite(t, cfg)

	providers := liveProviders(suite.Coordinator.Registry)
	require.Len(t, providers, 2)

	// Exercise the real protocol-v1 cold fallback before either isolated
	// provider has built a cache-capable slot. The request itself warms the
	// non-owner first; loading the other provider below then establishes the
	// shared test host's final on-disk binding before exact-cache donation.
	for _, provider := range providers {
		provider.Mu().Lock()
		protocolVersion := provider.PrefixCacheProtocol
		provider.Mu().Unlock()
		require.Equal(t, 1, protocolVersion,
			"fresh provider %s unexpectedly advertised exact-cache capability", provider.ID)
	}
	v1LifecycleBefore := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	v1Fallback := postExactCacheChat(
		t, suite, suite.Users[0].APIKey, model,
		"Serve this request through the protocol-v1 cold fallback path.")
	require.NotEmpty(t, v1Fallback.content)
	require.Zero(t, v1Fallback.cachedTokens)
	require.NotEmpty(t, v1Fallback.providerID)
	require.Equal(t, v1LifecycleBefore,
		suite.Coordinator.Registry.CacheRoutingLifecycleStatus(),
		"protocol-v1 cold fallback unexpectedly entered the exact-cache lifecycle")

	var nonOwner, owner *registry.Provider
	for _, provider := range providers {
		if provider.ID == v1Fallback.providerID {
			nonOwner = provider
		} else {
			owner = provider
		}
	}
	require.NotNil(t, nonOwner, "v1 fallback returned an unknown provider")
	require.NotNil(t, owner)
	nonOwnerModel := waitForLoadedModel(t, nonOwner, model, 3*time.Minute)
	require.NoError(t, suite.Coordinator.Registry.SendLoadModel(owner.ID, model))
	ownerModel := waitForLoadedModel(t, owner, model, 3*time.Minute)
	require.Equal(t, ownerModel.WeightHash, nonOwnerModel.WeightHash)
	require.Equal(t, fixture.manifest.AggregateSHA256, ownerModel.WeightHash,
		"Go manifest and Swift provider aggregate hashes diverged")

	capabilities := make(map[string]protocol.PrefixCacheV2Capability, len(providers))
	for _, provider := range providers {
		capabilities[provider.ID] = waitForExactCacheReady(
			t, provider, model, 30*time.Second)
	}

	contractArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contractID, err := promptcontract.ContractID(
		contractArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	for _, provider := range providers {
		capability := capabilities[provider.ID]
		require.Equal(t, contractID, capability.PromptContractID)
		require.Equal(t, ownerModel.WeightHash, capability.ModelAggregateHash)
	}

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
	suite.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, WeightHash: ownerModel.WeightHash,
	}})
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(
		registry.CacheRoutingConfig{
			Mode:            registry.CacheRoutingOn,
			ActivationPct:   100,
			TTL:             10 * time.Minute,
			MaxHolders:      4,
			MaxDiscountMs:   1_000,
			MaxCostFraction: .35,
			MasterKey:       "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
		}))

	lifecycleBefore := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	prompt := longExactCachePrompt()
	first := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, first.cachedTokens, "first request must prefill cold before donation")
	require.Eventually(t, func() bool {
		_, attempts := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return attempts > 0
	}, 5*time.Second, 100*time.Millisecond,
		"first request did not enter the provider-confirmed cache protocol")
	require.Eventually(t, func() bool {
		holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return holders > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"durable frozen-full donation did not publish a reusable cache holder")
	require.Eventually(t, func() bool {
		lifecycle := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
		return lifecycle.SSDLookups > lifecycleBefore.SSDLookups &&
			lifecycle.SSDMisses > lifecycleBefore.SSDMisses &&
			lifecycle.SSDDonations > lifecycleBefore.SSDDonations
	}, 2*time.Minute, 250*time.Millisecond,
		"miss and donation lifecycle telemetry did not advance")

	// Provider-confirmed evidence must keep the repeated request on the donor
	// and preserve exact deterministic output through frozen-full adoption.
	second := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, second.cachedTokens)
	require.Equal(t, first.content, second.content)
	require.Eventually(t, func() bool {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().SSDHits >
			lifecycleBefore.SSDHits
	}, 30*time.Second, 100*time.Millisecond,
		"positive cache hit lifecycle telemetry did not advance")

	isolated := postExactCacheChat(t, suite, suite.Users[1].APIKey, model, prompt)
	require.Zero(t, isolated.cachedTokens,
		"a different authenticated account crossed the cache-scope boundary")

	// Sidecar loss is never an inference outage. Stop the real supervised
	// process, serve cold through the closed client, then restore a fresh
	// supervisor over the same verified artifact directory.
	preloader.Close()
	supervisor.Close()
	outage := postExactCacheChat(
		t, suite, suite.Users[0].APIKey, model,
		"Serve this request while exact prompt planning is unavailable.")
	require.NotEmpty(t, outage.content)
	restartedSupervisor := promptcontract.NewSupervisor(supervisorConfig)
	restartedSupervisor.Start(suite.Ctx)
	t.Cleanup(restartedSupervisor.Close)
	waitForSidecarLive(t, restartedSupervisor, 15*time.Second)
	restartedPreloader, err := promptcontract.NewPreloadController(
		provisioner,
		restartedSupervisor,
		promptcontract.PreloadControllerConfig{PollInterval: 50 * time.Millisecond},
	)
	require.NoError(t, err)
	restartedPreloader.Start(suite.Ctx)
	t.Cleanup(restartedPreloader.Close)
	suite.Coordinator.Server.SetPromptContractClient(restartedSupervisor.Client())
	suite.Coordinator.Server.SetPromptPreloadController(restartedPreloader)
	waitForPreloadedContract(t, restartedPreloader, contractID, 30*time.Second)
	restored := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, restored.cachedTokens, "exact-cache routing did not reopen after re-preload")

	// A live holder disconnect still leaves ordinary cold serving available.
	require.NotEmpty(t, second.providerID, "cache hit did not identify its provider")
	suite.Coordinator.Registry.Disconnect(second.providerID)
	require.Eventually(t, func() bool {
		return len(liveProviders(suite.Coordinator.Registry)) >= 2
	}, 20*time.Second, 100*time.Millisecond,
		"a protocol-v2 provider with no currently ready cache model failed to reconnect cold")
	fallback := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt+" diverged")
	require.NotEmpty(t, fallback.content)
}

func exactCacheRoutingTestModelID() string {
	if modelID := os.Getenv("DARKBLOOM_EXACT_CACHE_TEST_MODEL"); modelID != "" {
		return modelID
	}
	// The ordinary testbed checkpoint (GPT-OSS) deliberately renders the
	// current date and is therefore cold-only. Exact routing needs a stable,
	// CBv2-supported prompt contract.
	return "mlx-community/gemma-4-e2b-it-4bit"
}

type exactCacheResponse struct {
	content      string
	cachedTokens int
	providerID   string
}

func postExactCacheChat(
	t *testing.T,
	suite *testbed.Suite,
	apiKey, model, prompt string,
) exactCacheResponse {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{{
			"role": "user", "content": prompt,
		}},
		"stream": false, "max_tokens": 32, "temperature": 0,
	})
	require.NoError(t, err)
	request, err := http.NewRequestWithContext(
		suite.Ctx,
		http.MethodPost,
		suite.Coordinator.BaseURL()+"/v1/chat/completions",
		bytes.NewReader(body),
	)
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Minute}).Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	payload, err := io.ReadAll(response.Body)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode, string(payload))
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokensDetails struct {
				CachedTokens int `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(payload, &decoded))
	require.NotEmpty(t, decoded.Choices)
	return exactCacheResponse{
		content:      decoded.Choices[0].Message.Content,
		cachedTokens: decoded.Usage.PromptTokensDetails.CachedTokens,
		providerID:   response.Header.Get("X-Provider-Id"),
	}
}

func liveProviders(r *registry.Registry) []*registry.Provider {
	var providers []*registry.Provider
	r.ForEachProvider(func(provider *registry.Provider) {
		providers = append(providers, provider)
	})
	sort.Slice(providers, func(i, j int) bool {
		return providers[i].ID < providers[j].ID
	})
	return providers
}

func waitForLoadedModel(
	t *testing.T,
	provider *registry.Provider,
	model string,
	timeout time.Duration,
) protocol.ModelInfo {
	t.Helper()
	var modelInfo protocol.ModelInfo
	require.Eventually(t, func() bool {
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		found := false
		for _, candidate := range provider.Models {
			if candidate.ID == model {
				modelInfo = candidate
				found = true
				break
			}
		}
		if !found || provider.BackendCapacity == nil {
			return false
		}
		for _, slot := range provider.BackendCapacity.Slots {
			if slot.Model == model && (slot.State == "running" || slot.State == "idle") {
				return true
			}
		}
		return false
	}, timeout, 500*time.Millisecond)
	return modelInfo
}

func waitForExactCacheReady(
	t *testing.T,
	provider *registry.Provider,
	model string,
	timeout time.Duration,
) protocol.PrefixCacheV2Capability {
	t.Helper()
	var (
		capability protocol.PrefixCacheV2Capability
		status     protocol.PrefixCacheModelStatus
		reported   bool
	)
	require.Eventually(t, func() bool {
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		capability, reported = provider.PrefixCacheV2Models[model]
		if !reported || !provider.PrefixCacheStatusReported {
			return false
		}
		status, reported = provider.PrefixCacheStatuses[model]
		return reported && status.State == "ready"
	}, timeout, 100*time.Millisecond,
		"provider %s did not heartbeat cache-ready status for %s",
		provider.ID, model)
	return capability
}

func waitForProvisionedContract(
	t *testing.T,
	provisioner *promptcontract.Provisioner,
	model, contractID string,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		status, ok := provisioner.Status(model)
		require.False(t, ok && status.LastError != "", status.LastError)
		return ok && status.ArtifactReady && status.PromptContractID == contractID
	}, 30*time.Second, 100*time.Millisecond)
}

func waitForSidecarLive(
	t *testing.T,
	supervisor *promptcontract.Supervisor,
	timeout time.Duration,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		status := supervisor.Status()
		if !status.Running || status.ChildGeneration == 0 {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer cancel()
		return supervisor.Client().Health(ctx) == nil
	}, timeout, 100*time.Millisecond)
}

func waitForPreloadedContract(
	t *testing.T,
	preloader *promptcontract.PreloadController,
	contractID string,
	timeout time.Duration,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		return preloader.ReadyFor(contractID)
	}, timeout, 100*time.Millisecond, "active contract was not preloaded: %+v", preloader.Status())
}

func exactCacheSidecarBinary(t *testing.T) string {
	t.Helper()
	if configured := os.Getenv("DARKBLOOM_PROMPT_SIDECAR_BINARY"); configured != "" {
		info, err := os.Stat(configured)
		require.NoError(t, err,
			"configured promptsidecar binary %q is unavailable", configured)
		require.False(t, info.IsDir(),
			"configured promptsidecar binary %q is a directory", configured)
		require.NotZero(t, info.Mode()&0o111,
			"configured promptsidecar binary %q is not executable", configured)
		return configured
	}
	root := os.Getenv("DARKBLOOM_REPO_ROOT")
	if root == "" {
		cwd, err := os.Getwd()
		require.NoError(t, err)
		root = filepath.Clean(filepath.Join(cwd, ".."))
	}
	for _, profile := range []string{"release", "debug"} {
		candidate := filepath.Join(
			root, "coordinator", "promptsidecar", "target", profile, "promptsidecar")
		if info, err := os.Stat(candidate); err == nil &&
			!info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	t.Skipf("exact-cache prerequisite missing: executable promptsidecar not found under %s; "+
		"build coordinator/promptsidecar first", root)
	return ""
}

func exactCacheModelSnapshot(t *testing.T, model string) string {
	t.Helper()
	hub := os.Getenv("HF_HUB_CACHE")
	if hub == "" {
		hub = os.Getenv("HUGGINGFACE_HUB_CACHE")
	}
	if hub == "" {
		if hfHome := os.Getenv("HF_HOME"); hfHome != "" {
			hub = filepath.Join(hfHome, "hub")
		} else {
			home, err := os.UserHomeDir()
			require.NoError(t, err)
			hub = filepath.Join(home, ".cache", "huggingface", "hub")
		}
	}
	modelRoot := filepath.Join(
		hub, "models--"+strings.ReplaceAll(model, "/", "--"))
	refPath := filepath.Join(modelRoot, "refs", "main")
	ref, err := os.ReadFile(refPath)
	if err != nil {
		t.Skipf("exact-cache prerequisite missing: pinned Hugging Face ref %s: %v",
			refPath, err)
	}
	revision := strings.TrimSpace(string(ref))
	digest, decodeErr := hex.DecodeString(revision)
	require.NoError(t, decodeErr,
		"exact-cache Hugging Face ref %s is not a commit hash: %q", refPath, revision)
	require.Contains(t, []int{20, 32}, len(digest),
		"exact-cache Hugging Face ref %s has unexpected hash length: %q", refPath, revision)
	snapshot := filepath.Join(modelRoot, "snapshots", revision)
	info, err := os.Stat(snapshot)
	if err != nil {
		t.Skipf("exact-cache prerequisite missing: snapshot pinned by %s (%s): %v",
			refPath, snapshot, err)
	}
	require.True(t, info.IsDir(),
		"snapshot pinned by %s is not a directory: %s", refPath, snapshot)
	return snapshot
}

func exactCacheTempRoot(t *testing.T) string {
	t.Helper()
	base, err := filepath.EvalSymlinks("/tmp")
	require.NoError(t, err)
	root, err := os.MkdirTemp(base, "db-exact-")
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if info.IsDir() {
				_ = os.Chmod(path, 0o700)
			} else {
				_ = os.Chmod(path, 0o600)
			}
			return nil
		})
		if removeErr := os.RemoveAll(root); removeErr != nil {
			t.Errorf("remove exact-cache temp root: %v", removeErr)
		}
	})
	return root
}

func loadExactCacheArtifacts(
	t *testing.T,
	snapshot, model string,
) exactCacheArtifactFixture {
	t.Helper()

	files := make(map[string][]byte)
	var artifacts []promptcontract.Artifact
	var modelType string
	err := filepath.Walk(snapshot, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		role := exactCacheArtifactRole(filepath.Base(path))
		if role == "" {
			return nil
		}
		stat, statErr := os.Stat(path)
		if statErr != nil || !stat.Mode().IsRegular() {
			return statErr
		}
		relative, relativeErr := filepath.Rel(snapshot, path)
		if relativeErr != nil {
			return relativeErr
		}
		relative = filepath.ToSlash(relative)
		if stat.Size() == 0 {
			return fmt.Errorf("exact-cache artifact %s is empty", relative)
		}
		file, openErr := os.Open(path)
		if openErr != nil {
			return openErr
		}
		hasher := sha256.New()
		_, hashErr := io.Copy(hasher, file)
		closeErr := file.Close()
		if hashErr != nil {
			return hashErr
		}
		if closeErr != nil {
			return closeErr
		}
		artifacts = append(artifacts, promptcontract.Artifact{
			Path: relative, Role: role, SizeBytes: stat.Size(),
			SHA256: hex.EncodeToString(hasher.Sum(nil)),
		})
		if !promptcontract.IsPromptRole(role) {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		files[relative] = data
		if relative == "config.json" {
			var config struct {
				ModelType string `json:"model_type"`
			}
			if json.Unmarshal(data, &config) == nil {
				modelType = config.ModelType
			}
		}
		return nil
	})
	require.NoError(t, err)
	require.NotEmpty(t, modelType)
	require.NotEmpty(t, artifacts, "pinned snapshot %s contains no recognized artifacts", snapshot)
	hasWeights := false
	for _, artifact := range artifacts {
		if artifact.Role == "weight" {
			hasWeights = true
			break
		}
	}
	require.True(t, hasWeights,
		"pinned snapshot %s contains no supported model weight artifact", snapshot)
	require.Contains(t, files, "config.json")
	require.Contains(t, files, "tokenizer.json")
	require.Contains(t, files, "chat_template.jinja")
	sort.Slice(artifacts, func(i, j int) bool {
		if artifacts[i].Path != artifacts[j].Path {
			return artifacts[i].Path < artifacts[j].Path
		}
		return artifacts[i].SHA256 < artifacts[j].SHA256
	})
	aggregate := sha256.New()
	for _, artifact := range artifacts {
		digest, decodeErr := hex.DecodeString(artifact.SHA256)
		require.NoError(t, decodeErr)
		_, _ = aggregate.Write(digest)
	}
	computedAggregate := hex.EncodeToString(aggregate.Sum(nil))
	return exactCacheArtifactFixture{
		manifest: promptcontract.Manifest{
			ModelID: model, ModelType: modelType,
			AggregateSHA256: computedAggregate, Files: artifacts,
		},
		files: files,
	}
}

func exactCacheArtifactRole(name string) string {
	switch name {
	case "model.safetensors.index.json":
		return "index"
	case "preprocessor_config.json", "processor_config.json":
		return "preprocessor"
	case "tokenizer.json", "tokenizer_config.json", "tokenizer.model",
		"special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt":
		return "tokenizer"
	case "config.json", "generation_config.json", "quantize_config.json":
		return "config"
	case "chat_template.jinja", "chat_template.json":
		return "template"
	default:
		if strings.HasSuffix(name, ".safetensors") ||
			strings.HasSuffix(name, ".npz") ||
			strings.HasSuffix(name, ".bin") ||
			name == "weights.npz" {
			return "weight"
		}
		return ""
	}
}

func longExactCachePrompt() string {
	var builder strings.Builder
	// Gemma 4's hybrid attention requires 25,600 recomputation tokens, and the
	// production SSD policy persists only when at least another 1,024 tokens can
	// be reused. Keep this fixture above that real gate so the E2E exercises
	// durable donation rather than merely proving the cold fallback.
	for i := 0; i < 2_600; i++ {
		builder.WriteString(
			"The observatory records stable stellar spectra for deterministic archival retrieval. ")
	}
	return builder.String()
}
