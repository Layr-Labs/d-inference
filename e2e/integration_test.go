package e2e

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
	tbprofile "github.com/eigeninference/d-inference/e2e/testbed/profile"
)

var httpTimeout = 300 * time.Second

func startSuite(t *testing.T) *testbed.Suite {
	t.Helper()

	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)
	return s
}

func postChatCompletions(t *testing.T, s *testbed.Suite, prompt string, stream bool, maxTokens int) *http.Response {
	t.Helper()
	return postChatCompletionsWithModel(t, s, s.PrimaryModelID(), prompt, stream, maxTokens)
}

func postChatCompletionsWithModel(t *testing.T, s *testbed.Suite, model, prompt string, stream bool, maxTokens int) *http.Response {
	t.Helper()

	body := map[string]any{
		"model":       model,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
		"stream":      stream,
		"max_tokens":  maxTokens,
		"temperature": 0.0,
	}
	bodyJSON, _ := json.Marshal(body)

	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer testbed-admin-key")
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	return resp
}

func postChatCompletionsWithAuth(t *testing.T, s *testbed.Suite, apiKey, prompt string, stream bool, maxTokens int) *http.Response {
	t.Helper()

	body := map[string]any{
		"model":       s.PrimaryModelID(),
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
		"stream":      stream,
		"max_tokens":  maxTokens,
		"temperature": 0.0,
	}
	bodyJSON, _ := json.Marshal(body)

	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	return resp
}

func assertAccounting(t *testing.T, s *testbed.Suite) {
	t.Helper()

	pool, err := pgxpool.New(s.Ctx, s.Pg.DatabaseURL)
	require.NoError(t, err)
	defer pool.Close()

	pgAsserter := tbassert.NewPostgresAccountingAsserter(pool)
	acctReport := pgAsserter.EvaluateAll(s.Ctx)
	require.True(t, acctReport.Passed, "accounting integrity check failed\n%s", acctReport.SummaryTable())

	storeAsserter := tbassert.NewAccountingAsserter(s.PgStore)
	storeReport := storeAsserter.EvaluateAll(s.Ctx)
	require.True(t, storeReport.Passed, "store-level accounting check failed\n%s", storeReport.SummaryTable())
}

type ledgerEntry struct {
	ID             int64  `json:"id"`
	AccountID      string `json:"account_id"`
	EntryType      string `json:"entry_type"`
	AmountMicroUSD int64  `json:"amount_micro_usd"`
	BalanceAfter   int64  `json:"balance_after"`
	Reference      string `json:"reference"`
}

func queryLedgerEntries(t *testing.T, s *testbed.Suite, accountID, entryType string) []ledgerEntry {
	t.Helper()
	pool, err := pgxpool.New(s.Ctx, s.Pg.DatabaseURL)
	require.NoError(t, err)
	defer pool.Close()

	query := `SELECT id, account_id, entry_type, amount_micro_usd, balance_after, reference
	          FROM ledger_entries WHERE account_id = $1`
	args := []any{accountID}
	if entryType != "" {
		query += ` AND entry_type = $2`
		args = append(args, entryType)
	}
	query += ` ORDER BY id`

	rows, err := pool.Query(s.Ctx, query, args...)
	require.NoError(t, err)
	defer rows.Close()

	var entries []ledgerEntry
	for rows.Next() {
		var e ledgerEntry
		require.NoError(t, rows.Scan(&e.ID, &e.AccountID, &e.EntryType, &e.AmountMicroUSD, &e.BalanceAfter, &e.Reference))
		entries = append(entries, e)
	}
	return entries
}

func getBalance(t *testing.T, s *testbed.Suite, accountID string) int64 {
	t.Helper()
	pool, err := pgxpool.New(s.Ctx, s.Pg.DatabaseURL)
	require.NoError(t, err)
	defer pool.Close()

	var balance int64
	err = pool.QueryRow(s.Ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID).Scan(&balance)
	if err != nil {
		return 0
	}
	return balance
}

func parseErrorResponse(t *testing.T, body []byte) (string, string) {
	t.Helper()
	var errResp struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	require.NoError(t, json.Unmarshal(body, &errResp))
	return errResp.Error.Type, errResp.Error.Message
}

func sumAmounts(entries []ledgerEntry) int64 {
	var total int64
	for _, e := range entries {
		total += e.AmountMicroUSD
	}
	return total
}

func TestIntegration_NonStreamingInference(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	ri := inst.NewRequest()
	timer := ri.StartSegment(testbed.SegmentTotalE2E)

	resp := postChatCompletions(t, s, "What is 2+2? Answer with just the number.", false, 20)
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	timer.Stop()

	require.Equal(t, http.StatusOK, resp.StatusCode, "body: %s", string(respBody[:min(len(respBody), 500)]))
	ri.EndWithDuration(0)
	t.Logf("non-streaming response: %s", string(respBody[:min(len(respBody), 200)]))

	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())

	assertAccounting(t, s)
}

const (
	qwen38ConcreteModel  = registry.Qwen38NAXModelID
	qwen38Alias          = "qwen3.8-27b"
	qwen38TargetRev      = "301e9e2767fd0efcfab7883004720ba3c9a552a1"
	qwen38MTPModel       = "EigenLabs/Qwen3.8-27B-MTP-4bit"
	qwen38MTPRev         = "329261c5e0b3f9c233485e682cb3b67b88c20a55"
	qwen38PrewarmTimeout = 10 * time.Minute
)

type qwen38E2EConfig struct {
	targetPath  string
	mtpPath     string
	manifest    store.ModelManifest
	mtpManifest *store.ModelManifest
}

type qwen38GateOutcome string

const (
	qwen38GateSkip qwen38GateOutcome = "skip"
	qwen38GateFail qwen38GateOutcome = "fail"
	qwen38GateRun  qwen38GateOutcome = "run"
)

func qwen38GatePolicy(
	optedIn, missingRequired, hostIneligible, postStartIneligible bool,
) qwen38GateOutcome {
	if !optedIn {
		return qwen38GateSkip
	}
	if missingRequired || hostIneligible || postStartIneligible {
		return qwen38GateFail
	}
	return qwen38GateRun
}

func TestQwen38GatePolicy(t *testing.T) {
	require.Equal(t, qwen38GateSkip, qwen38GatePolicy(false, true, true, true))
	require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, true, false, false))
	require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, true, false))
	require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, false, true))
	require.Equal(t, qwen38GateRun, qwen38GatePolicy(true, false, false, false))
}

func qwen38RequiredEnv(t *testing.T, key string) string {
	t.Helper()
	value := strings.TrimSpace(os.Getenv(key))
	require.NotEmpty(t, value, "%s is required once DARKBLOOM_QWEN38_E2E=1", key)
	return value
}

func requireQwen38E2EConfig(t *testing.T) qwen38E2EConfig {
	t.Helper()
	if qwen38GatePolicy(os.Getenv("DARKBLOOM_QWEN38_E2E") == "1", false, false, false) == qwen38GateSkip {
		t.Skip("set DARKBLOOM_QWEN38_E2E=1 and the pinned local artifact variables to run the real-process Qwen3.8 E2E")
	}

	modelID := qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MODEL_ID")
	revision := qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MODEL_REVISION")
	capabilitiesRaw := qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_EXPECT_PROVIDER_CAPABILITIES")
	modelPath := qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MODEL_PATH")
	manifestPath := qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MANIFEST_PATH")
	require.Equal(t, qwen38ConcreteModel, modelID,
		"DARKBLOOM_QWEN38_MODEL_ID must name the final protected catalog build")
	require.Equal(t, qwen38TargetRev, revision,
		"DARKBLOOM_QWEN38_MODEL_REVISION must be the reviewed immutable revision")

	expectedCapabilities := strings.Split(capabilitiesRaw, ",")
	for i := range expectedCapabilities {
		expectedCapabilities[i] = strings.TrimSpace(expectedCapabilities[i])
	}
	sort.Strings(expectedCapabilities)
	require.Equal(t, []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}, expectedCapabilities, "Qwen3.8 E2E must explicitly require the protected M5+NAX capability set")

	requireQwen38Host(t)
	targetPath := requireQwen38Snapshot(
		t, modelPath, qwen38ConcreteModel, qwen38TargetRev, true)
	manifest := loadQwen38Manifest(
		t, manifestPath, targetPath, qwen38ConcreteModel)

	cfg := qwen38E2EConfig{targetPath: targetPath, manifest: manifest}
	mtpPath := strings.TrimSpace(os.Getenv("DARKBLOOM_QWEN38_MTP_PATH"))
	if mtpPath == "" {
		require.Empty(t, strings.TrimSpace(os.Getenv("DARKBLOOM_QWEN38_MTP_REVISION")),
			"DARKBLOOM_QWEN38_MTP_REVISION requires DARKBLOOM_QWEN38_MTP_PATH")
		require.Empty(t, strings.TrimSpace(os.Getenv("DARKBLOOM_QWEN38_MTP_MANIFEST_PATH")),
			"DARKBLOOM_QWEN38_MTP_MANIFEST_PATH requires DARKBLOOM_QWEN38_MTP_PATH")
		return cfg
	}
	require.Equal(t, qwen38MTPRev,
		qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MTP_REVISION"),
		"local MTP must use the reviewed immutable assistant revision")
	cfg.mtpPath = requireQwen38Snapshot(t, mtpPath, qwen38MTPModel, qwen38MTPRev, false)
	mtpManifest := loadQwen38Manifest(
		t, qwen38RequiredEnv(t, "DARKBLOOM_QWEN38_MTP_MANIFEST_PATH"),
		cfg.mtpPath, qwen38MTPModel)
	cfg.mtpManifest = &mtpManifest
	return cfg
}

func requireQwen38Host(t *testing.T) {
	t.Helper()
	chip, err := exec.Command("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string").Output()
	if err != nil {
		require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, true, false))
		t.Fatalf("cannot establish opted-in Qwen3.8 host eligibility: sysctl chip query failed: %v", err)
	}
	if !strings.Contains(strings.TrimSpace(string(chip)), "Apple M5") {
		require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, true, false))
		t.Fatalf("opted-in Qwen3.8 requires an Apple M5 host; this host reports %q",
			strings.TrimSpace(string(chip)))
	}
	rawMemory, err := exec.Command("/usr/sbin/sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, true, false))
		t.Fatalf("cannot establish opted-in Qwen3.8 host eligibility: sysctl memory query failed: %v", err)
	}
	memoryBytes, err := strconv.ParseUint(strings.TrimSpace(string(rawMemory)), 10, 64)
	require.NoError(t, err, "parse hw.memsize")
	if memoryBytes < 48<<30 {
		require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, true, false))
		t.Fatalf("opted-in Qwen3.8 requires at least 48 GiB unified memory; this host reports %.1f GiB",
			float64(memoryBytes)/(1<<30))
	}
}

func requireQwen38Snapshot(
	t *testing.T, configured, modelID, revision string, target bool,
) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(configured)
	require.NoError(t, err, "resolve configured snapshot %q", configured)
	info, err := os.Stat(resolved)
	require.NoError(t, err, "stat configured snapshot %q", resolved)
	require.True(t, info.IsDir(), "configured snapshot must be a directory: %s", resolved)
	require.Equal(t, revision, filepath.Base(resolved),
		"snapshot path must end in the immutable revision")
	if target {
		home, err := os.UserHomeDir()
		require.NoError(t, err)
		cachePath := filepath.Join(home, ".cache", "huggingface", "hub",
			"models--"+strings.ReplaceAll(modelID, "/", "--"), "snapshots", revision)
		cached, err := filepath.EvalSymlinks(cachePath)
		require.NoError(t, err,
			"opted-in final Qwen3.8 snapshot must already be cached at %s; the test never downloads it",
			cachePath)
		require.Equal(t, cached, resolved,
			"the provider scanner serves the pinned Hugging Face cache snapshot; MODEL_PATH must identify that exact directory")
	}
	return resolved
}

func loadQwen38Manifest(
	t *testing.T, manifestPath, snapshotPath, modelID string,
) store.ModelManifest {
	t.Helper()
	raw, err := os.ReadFile(manifestPath)
	require.NoError(t, err, "read immutable model manifest")
	var manifest store.ModelManifest
	require.NoError(t, json.Unmarshal(raw, &manifest), "parse immutable model manifest")
	require.Equal(t, 1, manifest.SchemaVersion)
	require.Equal(t, modelID, manifest.ModelID)
	require.NotEmpty(t, manifest.Version)
	require.NotEmpty(t, manifest.R2Prefix)
	require.Len(t, manifest.Files, manifest.FileCount)
	require.NotEmpty(t, manifest.Files)
	requireSHA256(t, manifest.AggregateSHA256, "aggregate_sha256")

	var total int64
	seen := make(map[string]struct{}, len(manifest.Files))
	for _, file := range manifest.Files {
		require.NotEmpty(t, file.Role, "manifest role for %q", file.Path)
		requireSHA256(t, file.SHA256, file.Path)
		clean := filepath.Clean(file.Path)
		require.False(t, filepath.IsAbs(clean), "manifest path must be relative: %q", file.Path)
		require.NotEqual(t, "..", clean)
		require.False(t, strings.HasPrefix(clean, ".."+string(filepath.Separator)),
			"manifest path escapes snapshot: %q", file.Path)
		_, duplicate := seen[clean]
		require.False(t, duplicate, "duplicate manifest path %q", clean)
		seen[clean] = struct{}{}
		info, err := os.Stat(filepath.Join(snapshotPath, clean))
		require.NoError(t, err, "manifest file missing from snapshot: %s", clean)
		require.Equal(t, file.SizeBytes, info.Size(), "manifest size mismatch for %s", clean)
		total += file.SizeBytes
	}
	require.Equal(t, manifest.TotalSizeBytes, total, "manifest total_size_bytes")
	return manifest
}

func requireSHA256(t *testing.T, value, field string) {
	t.Helper()
	decoded, err := hex.DecodeString(value)
	require.NoError(t, err, "%s must be hexadecimal", field)
	require.Len(t, decoded, 32, "%s must be a SHA-256 digest", field)
	require.Equal(t, strings.ToLower(value), value, "%s must use canonical lowercase hex", field)
}

func qwen38SuiteConfig(cfg qwen38E2EConfig) testbed.SuiteConfig {
	metadata := map[string]any{
		"hugging_face_id": qwen38ConcreteModel,
		"source_revision": qwen38TargetRev,
	}
	if cfg.mtpManifest != nil {
		var configSHA string
		roles := make(map[string]struct{})
		for _, file := range cfg.mtpManifest.Files {
			roles[file.Role] = struct{}{}
			if filepath.Clean(file.Path) == "config.json" {
				configSHA = file.SHA256
			}
		}
		allowed := make([]string, 0, len(roles))
		for role := range roles {
			allowed = append(allowed, role)
		}
		sort.Strings(allowed)
		metadata["spec_dec"] = map[string]any{
			"assistant_model_id": qwen38MTPModel,
			"r2_prefix":          cfg.mtpManifest.R2Prefix,
			"manifest_sha256":    cfg.mtpManifest.AggregateSHA256,
			"total_size_bytes":   cfg.mtpManifest.TotalSizeBytes,
			"file_count":         cfg.mtpManifest.FileCount,
			"max_file_count":     cfg.mtpManifest.FileCount,
			"allowed_file_types": allowed,
			"config_sha256":      configSHA,
			"revision":           qwen38MTPRev,
		}
	}
	return testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{
			ModelID: qwen38ConcreteModel, NumProviders: 1,
		}},
		UseMemoryStore: true,
		CatalogModels: []testbed.CatalogModel{{
			Entry: store.ModelRegistryEntry{
				ID: qwen38ConcreteModel, DisplayName: "Qwen3.8 27B",
				Family: "qwen3.8", Architecture: "27B dense VLM", Quantization: "4bit",
				MaxContextLength: 262144, MaxOutputLength: 32768, MinRAMGB: 48,
				Capabilities: []string{"tools", "reasoning", "json_mode", "vision", "video"},
				RequiredProviderCapabilities: []string{
					registry.ProviderCapabilityAppleM5,
					registry.ProviderCapabilityMLXNAX,
				},
				Status:      "active",
				Description: "Dense Qwen3.8 vision-language model with bounded image and video input.",
				RuntimeParameters: map[string]any{
					"reasoning_parser":       "qwen3",
					"tool_call_parser":       "qwen3_coder",
					"chat_template_required": true,
				},
				Metadata: metadata,
			},
			Manifest: cfg.manifest,
		}},
		ModelAliases: []store.ModelAlias{{
			AliasID: qwen38Alias, DisplayName: "Qwen3.8 27B",
			DesiredBuild: qwen38ConcreteModel, Active: true,
		}},
		ExpectedProviderCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
		MTPDrafterPath: cfg.mtpPath,
	}
}

func qwen38ExpectedBuiltKVBackend(requested string) (string, error) {
	switch requested {
	case "", testbed.KVBackendAuto:
		// The provider's production .auto selection resolves contiguous.
		return testbed.KVBackendContiguous, nil
	case testbed.KVBackendPaged, testbed.KVBackendContiguous:
		return requested, nil
	default:
		return "", fmt.Errorf("unsupported Qwen3.8 testbed KV backend %q", requested)
	}
}

func TestQwen38ExpectedBuiltKVBackend(t *testing.T) {
	for requested, want := range map[string]string{
		"":                          testbed.KVBackendContiguous,
		testbed.KVBackendAuto:       testbed.KVBackendContiguous,
		testbed.KVBackendContiguous: testbed.KVBackendContiguous,
		testbed.KVBackendPaged:      testbed.KVBackendPaged,
	} {
		got, err := qwen38ExpectedBuiltKVBackend(requested)
		require.NoError(t, err)
		require.Equal(t, want, got)
	}
	_, err := qwen38ExpectedBuiltKVBackend("invalid")
	require.Error(t, err)
}

func qwen38LoadFailureProbe(provider *testbed.Provider) func() error {
	return func() error {
		if !provider.Running() {
			return errors.New("provider process exited during model load")
		}
		raw, err := os.ReadFile(provider.DaemonStatePath())
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read provider daemon state: %w", err)
		}
		var state struct {
			Slots []struct {
				Model     string  `json:"model"`
				LoadError *string `json:"load_error"`
			} `json:"slots"`
		}
		if err := json.Unmarshal(raw, &state); err != nil {
			// The daemon owns this asynchronously-written observation. A
			// transient partial read is not a model-load verdict; retry.
			return nil
		}
		for _, slot := range state.Slots {
			if slot.Model == qwen38ConcreteModel &&
				slot.LoadError != nil &&
				strings.TrimSpace(*slot.LoadError) != "" {
				return fmt.Errorf("daemon-state load_error: %s", *slot.LoadError)
			}
		}
		return nil
	}
}

func prewarmQwen38(t *testing.T, s *testbed.Suite) {
	t.Helper()
	providerIDs := s.Coordinator.Registry.ProviderIDs()
	require.Len(t, providerIDs, 1, "Qwen3.8 E2E requires one exact provider slot")
	expectedBackend, err := qwen38ExpectedBuiltKVBackend(
		testbed.ResolveKVBackend(s.Config.KVBackend))
	require.NoError(t, err)

	err = testbed.PrewarmRegistrySlot(
		s.Ctx,
		s.Coordinator.Registry,
		providerIDs[0],
		qwen38ConcreteModel,
		expectedBackend,
		qwen38PrewarmTimeout,
		s.Logger,
		qwen38LoadFailureProbe(s.Providers[0]),
	)
	if err == nil {
		return
	}
	daemonState, stateErr := os.ReadFile(s.Providers[0].DaemonStatePath())
	if stateErr != nil {
		t.Fatalf("Qwen3.8 production pre-warm failed: %v; "+
			"provider daemon state unavailable: %v; inspect provider stdout/stderr above",
			err, stateErr)
	}
	t.Fatalf("Qwen3.8 production pre-warm failed: %v\nprovider daemon state: %s",
		err, daemonState)
}

func postQwen38Request(
	t *testing.T, s *testbed.Suite, body map[string]any,
) (*http.Response, []byte) {
	t.Helper()
	bodyJSON, err := json.Marshal(body)
	require.NoError(t, err)
	req, err := http.NewRequestWithContext(
		s.Ctx, http.MethodPost, s.Coordinator.BaseURL()+"/v1/chat/completions",
		bytes.NewReader(bodyJSON))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer testbed-admin-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return resp, respBody
}

func assertQwen38Route(t *testing.T, s *testbed.Suite, resp *http.Response) {
	t.Helper()
	ids := s.Coordinator.Registry.ProviderIDs()
	require.Len(t, ids, 1)
	require.Equal(t, ids[0], resp.Header.Get("X-Provider-Id"), "concrete provider attribution")
	require.Contains(t, resp.Header.Get("X-Provider-Chip"), "M5")
	p := s.Coordinator.Registry.GetProvider(ids[0])
	require.NotNil(t, p)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	key, err := base64.StdEncoding.DecodeString(p.PublicKey)
	require.NoError(t, err, "provider route must carry an X25519 key for sealed wire requests")
	require.Len(t, key, 32, "provider route must use a 32-byte X25519 public key")
	require.Equal(t, "M5", p.Hardware.ChipFamily)
	for _, requiredCapability := range []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	} {
		require.Contains(t, p.RuntimeCapabilities, requiredCapability)
	}
	var advertised *bool
	for i := range p.Models {
		if p.Models[i].ID == qwen38ConcreteModel {
			advertised = p.Models[i].TemplateRenderOK
			require.True(t, p.Models[i].IsVision, "video route must be backed by a VLM advertisement")
			require.Equal(t, s.Config.CatalogModels[0].Manifest.AggregateSHA256, p.Models[i].WeightHash)
		}
	}
	require.NotNil(t, advertised, "provider must advertise the concrete protected build")
	require.True(t, *advertised, "required-tool route needs the provider's rendered-template capability")
}

func assertQwen38Catalog(t *testing.T, s *testbed.Suite) {
	t.Helper()
	req, err := http.NewRequestWithContext(
		s.Ctx, http.MethodGet, s.Coordinator.BaseURL()+"/v1/models/catalog?include_aliases=1", nil)
	require.NoError(t, err)
	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)
	var catalog struct {
		Models  []map[string]any `json:"models"`
		Aliases []map[string]any `json:"aliases"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&catalog))
	var concrete map[string]any
	for _, model := range catalog.Models {
		if model["id"] == qwen38ConcreteModel {
			concrete = model
		}
	}
	require.NotNil(t, concrete)
	require.ElementsMatch(t,
		[]any{registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX},
		concrete["required_provider_capabilities"])
	runtimeParameters, ok := concrete["runtime_parameters"].(map[string]any)
	require.True(t, ok)
	require.Equal(t, "qwen3", runtimeParameters["reasoning_parser"])
	require.Equal(t, "qwen3_coder", runtimeParameters["tool_call_parser"])
	require.Equal(t, true, runtimeParameters["chat_template_required"])
	require.Len(t, catalog.Aliases, 1)
	require.Equal(t, qwen38Alias, catalog.Aliases[0]["id"])
	require.Equal(t, qwen38ConcreteModel, catalog.Aliases[0]["desired_build"])
	resolved, alias, ok := s.Coordinator.Registry.ResolveModel(qwen38Alias)
	require.True(t, ok)
	require.True(t, alias)
	require.Equal(t, qwen38ConcreteModel, resolved)
	require.NotNil(t, findRoutableProvider(s.Coordinator.Registry, qwen38ConcreteModel))
}

func assertQwen38DaemonPosture(t *testing.T, s *testbed.Suite, localMTP bool) {
	t.Helper()
	require.Len(t, s.Providers, 1)
	type slotPosture struct {
		Model             string  `json:"model"`
		MTPEnabled        bool    `json:"mtp_enabled"`
		MTPActive         bool    `json:"mtp_active"`
		MTPInactiveReason *string `json:"mtp_inactive_reason"`
		LoadError         *string `json:"load_error"`
	}
	var target slotPosture
	require.Eventually(t, func() bool {
		raw, err := os.ReadFile(s.Providers[0].DaemonStatePath())
		if err != nil {
			return false
		}
		var state struct {
			Slots []slotPosture `json:"slots"`
		}
		if json.Unmarshal(raw, &state) != nil {
			return false
		}
		for _, slot := range state.Slots {
			if slot.Model == qwen38ConcreteModel {
				target = slot
				return true
			}
		}
		return false
	}, 30*time.Second, 250*time.Millisecond, "provider never published Qwen3.8 slot posture")
	require.Nil(t, target.LoadError, "target model must remain the authoritative serving slot")
	configBytes, err := os.ReadFile(filepath.Join(s.Providers[0].StateDir, "provider.toml"))
	require.NoError(t, err)
	require.NotContains(t, string(configBytes), "mtp_mode",
		"testbed must preserve the provider's exact-model automatic MTP policy")
	if localMTP {
		require.Contains(t, string(configBytes), "mtp_drafter_path",
			"local MTP path must be used only when explicitly configured")
		require.True(t, target.MTPEnabled, "configured immutable assistant was not enabled")
	} else {
		require.NotContains(t, string(configBytes), "mtp_drafter_path",
			"ordinary target-only runs must not inject a local assistant")
	}
	if target.MTPActive {
		require.True(t, target.MTPEnabled)
		require.Nil(t, target.MTPInactiveReason)
	} else {
		require.NotNil(t, target.MTPInactiveReason,
			"target-only fallback must name why the subordinate MTP assistant is inactive")
		require.NotEmpty(t, *target.MTPInactiveReason)
	}
	require.True(t, s.Providers[0].Running(), "provider process exited after tool/video inference")
}

func TestIntegration_Qwen38RealProcessToolsAndVideo(t *testing.T) {
	cfg := requireQwen38E2EConfig(t)
	s := testbed.NewSuite(qwen38SuiteConfig(cfg))
	err := s.Start(context.Background())
	if errors.Is(err, testbed.ErrProviderIneligible) {
		require.Equal(t, qwen38GateFail, qwen38GatePolicy(true, false, false, true))
		t.Fatalf("opted-in M5+NAX provider failed signed capability admission: %v", err)
	}
	require.NoError(t, err, "Qwen3.8 suite startup failed")
	t.Cleanup(s.Stop)
	prewarmQwen38(t, s)
	assertQwen38Catalog(t, s)

	toolBody := map[string]any{
		"model": qwen38Alias,
		"messages": []map[string]string{{
			"role":    "user",
			"content": `Call get_weather exactly once with the city argument exactly "Boston".`,
		}},
		"tools": []map[string]any{{
			"type": "function",
			"function": map[string]any{
				"name": "get_weather", "description": "Get weather for a city",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"city": map[string]string{"type": "string"},
					},
					"required": []string{"city"}, "additionalProperties": false,
				},
			},
		}},
		"tool_choice": "required", "enable_thinking": false,
		"reasoning_effort": "low", "temperature": 0.0, "max_tokens": 96,
	}
	_, hasReasoningParser := toolBody["reasoning_parser"]
	_, hasToolParser := toolBody["tool_call_parser"]
	require.False(t, hasReasoningParser, "client must omit the catalog-owned reasoning parser")
	require.False(t, hasToolParser, "client must omit the catalog-owned tool parser")
	toolResp, toolRespBody := postQwen38Request(t, s, toolBody)
	require.Equal(t, http.StatusOK, toolResp.StatusCode, "body: %s", toolRespBody)
	assertQwen38Route(t, s, toolResp)
	var toolCompletion struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				ToolCalls []struct {
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(toolRespBody, &toolCompletion))
	require.Equal(t, qwen38Alias, toolCompletion.Model, "response model must be rewritten to the public alias")
	require.NotContains(t, string(toolRespBody), qwen38ConcreteModel,
		"concrete route identity must not leak through the alias response body")
	require.Len(t, toolCompletion.Choices, 1)
	require.Len(t, toolCompletion.Choices[0].Message.ToolCalls, 1)
	call := toolCompletion.Choices[0].Message.ToolCalls[0].Function
	require.Equal(t, "get_weather", call.Name)
	var arguments map[string]any
	require.NoError(t, json.Unmarshal([]byte(call.Arguments), &arguments))
	require.Equal(t, "Boston", arguments["city"])
	require.Greater(t, toolCompletion.Usage.PromptTokens, 0)
	require.Greater(t, toolCompletion.Usage.CompletionTokens, 0)
	require.Equal(t,
		toolCompletion.Usage.PromptTokens+toolCompletion.Usage.CompletionTokens,
		toolCompletion.Usage.TotalTokens)

	video, err := os.ReadFile(filepath.Join(
		"..", "libs", "mlx-swift-lm", "Tests", "MLXLMTests", "Resources", "1080p_30.mov"))
	require.NoError(t, err)
	require.Less(t, len(video), 128<<10, "canonical color-bar video fixture must stay bounded")
	videoURI := "data:video/quicktime;base64," + base64.StdEncoding.EncodeToString(video)
	videoBody := map[string]any{
		"model": qwen38Alias,
		"messages": []map[string]any{{
			"role": "user",
			"content": []map[string]any{
				{"type": "text", "text": "Describe the main test pattern in this video in a short phrase."},
				{"type": "video_url", "video_url": map[string]string{"url": videoURI}},
			},
		}},
		"enable_thinking": false, "temperature": 0.0, "max_tokens": 32,
	}
	videoResp, videoRespBody := postQwen38Request(t, s, videoBody)
	require.Equal(t, http.StatusOK, videoResp.StatusCode, "body: %s", videoRespBody)
	assertQwen38Route(t, s, videoResp)
	var videoCompletion struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(videoRespBody, &videoCompletion))
	require.Equal(t, qwen38Alias, videoCompletion.Model)
	require.NotContains(t, string(videoRespBody), qwen38ConcreteModel)
	require.Len(t, videoCompletion.Choices, 1)
	grounded := strings.TrimSpace(videoCompletion.Choices[0].Message.Content)
	require.NotEmpty(t, grounded, "decrypted video response must contain grounded text")
	normalizedGrounded := strings.ToLower(grounded)
	require.True(t,
		strings.Contains(normalizedGrounded, "color bar") ||
			strings.Contains(normalizedGrounded, "colour bar"),
		"response must identify the canonical color-bar fixture: %q", grounded)
	require.Greater(t, videoCompletion.Usage.PromptTokens, 0)
	require.Greater(t, videoCompletion.Usage.CompletionTokens, 0)
	require.Equal(t,
		videoCompletion.Usage.PromptTokens+videoCompletion.Usage.CompletionTokens,
		videoCompletion.Usage.TotalTokens)

	assertQwen38DaemonPosture(t, s, cfg.mtpPath != "")
	report := tbassert.NewAccountingAsserter(s.PgStore).EvaluateAll(s.Ctx)
	require.True(t, report.Passed, "tool/video accounting integrity failed\n%s", report.SummaryTable())
}

func TestIntegration_StreamingInference(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	ri := inst.NewRequest()
	timer := ri.StartSegment(testbed.SegmentTotalE2E)

	resp := postChatCompletions(t, s, "Count from 1 to 5.", true, 50)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	timer.Stop()
	ri.EndWithDuration(0)

	// Counting bare `data: ` lines was vacuous: the `[DONE]` sentinel is a
	// `data: ` line, so a stream that produced NOTHING but its terminator
	// (or only role-preamble boilerplate) still passed. Require at least one
	// payload-bearing chunk: not `[DONE]`, parses as a chunk, and carries
	// non-empty delta text. gpt-oss is a reasoning model, so the Harmony
	// analysis channel (`delta.reasoning`) counts as payload exactly as
	// TestIntegration_StreamingContentValidation already treats it — under a
	// small token cap the final `content` channel may not start at all.
	var chunks, payloadChunks int
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		chunks++
		ri.StreamChunk(chunks)
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if len(chunk.Choices) > 0 &&
			(chunk.Choices[0].Delta.Content != "" || chunk.Choices[0].Delta.Reasoning != "") {
			payloadChunks++
		}
	}
	require.Greater(t, chunks, 0, "expected at least one SSE chunk")
	require.Greater(t, payloadChunks, 0,
		"expected at least one parseable chunk carrying delta content/reasoning — "+
			"a stream of boilerplate plus [DONE] is not an inference")
	t.Logf("streaming: received %d SSE chunks (%d payload-bearing)", chunks, payloadChunks)

	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())

	assertAccounting(t, s)
}

// Within-backend greedy determinism: the same temperature-0 prompt, sent
// twice to the same provider process, must produce byte-identical
// completions. This is the one CONTENT property the e2e layer can assert
// without lying: cross-backend token equality is known-divergent on gemma-4
// (8.85% teacher-forced disagreement, accepted drift) and golden-token
// pinning would break on any harmless kernel/template change — but a single
// engine slot answering the same greedy question two different ways is a
// nondeterminism bug on ANY backend, and no e2e test asserted anything about
// content at all.
//
// The suite runs one provider (startSuite's default), so "the same provider"
// is structural, and requests are sequential, so both runs decode at batch
// size 1 — this does not depend on batch-composition invariance, which the
// live Swift parity suite owns.
func TestIntegration_GreedyDeterminism(t *testing.T) {
	s := startSuite(t)

	// 256 tokens for the same reason as TestIntegration_E2EEncryptionCorrectness:
	// gpt-oss spends its first tokens in the Harmony analysis channel, and the
	// assertion below wants the final `content` channel populated too.
	const prompt = "What is 2+2? Answer with just the number."
	type completion struct {
		content   string
		reasoning string
		tokens    int
	}
	run := func(attempt int) completion {
		resp := postChatCompletions(t, s, prompt, false, 256)
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)
		require.Equal(t, http.StatusOK, resp.StatusCode,
			"attempt %d: body: %s", attempt, string(respBody[:min(len(respBody), 500)]))

		var result struct {
			Choices []struct {
				Message struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"message"`
			} `json:"choices"`
			Usage struct {
				CompletionTokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		require.NoError(t, json.Unmarshal(respBody, &result), "attempt %d", attempt)
		require.Len(t, result.Choices, 1, "attempt %d", attempt)
		require.NotEmpty(t, result.Choices[0].Message.Content,
			"attempt %d produced no content — nothing to compare", attempt)
		return completion{
			content:   result.Choices[0].Message.Content,
			reasoning: result.Choices[0].Message.Reasoning,
			tokens:    result.Usage.CompletionTokens,
		}
	}

	first := run(1)
	second := run(2)

	require.Equal(t, first.content, second.content,
		"greedy temperature-0 completions differ across two runs on the same provider — "+
			"within-backend nondeterminism")
	require.Equal(t, first.reasoning, second.reasoning,
		"greedy reasoning channels differ across two runs on the same provider")
	require.Equal(t, first.tokens, second.tokens,
		"identical greedy runs reported different completion token counts")
	t.Logf("determinism: two greedy runs byte-identical (%d completion tokens, content=%q)",
		first.tokens, first.content[:min(len(first.content), 80)])
}

func TestIntegration_MultipleRequestsAccounting(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)

	const totalRequests = 3
	var successCount int
	for i := 0; i < totalRequests; i++ {
		ri := inst.NewRequest()
		clientTimer := ri.StartSegment(testbed.SegmentTotalE2E)

		resp := postChatCompletions(t, s, "What is 2+2?", false, 20)
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		clientTimer.Stop()

		if resp.StatusCode != 200 {
			ri.Error(fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody[:min(len(respBody), 500)])))
			t.Logf("request %d: status=%d", i+1, resp.StatusCode)
			continue
		}

		ri.EndWithDuration(0)
		successCount++
		t.Logf("request %d: status=200", i+1)
	}

	require.Greater(t, successCount, 0, "no successful requests")

	cfg := testbed.DefaultTestConfig()
	p := tbprofile.NewProfiler(cfg, buf)
	run := p.BuildProfile()
	t.Logf("\n%s", run.SummaryTable())

	assertAccounting(t, s)
}

func TestIntegration_E2EEncryptionCorrectness(t *testing.T) {
	s := startSuite(t)

	// 256 tokens, not 20: the CBv2 default fixture (gpt-oss-20b) is a
	// reasoning model — a 20-token cap is consumed entirely by the Harmony
	// analysis channel and `content` stays empty before the final channel
	// starts. This test asserts on the decrypted CONTENT, so give the
	// model room to finish reasoning and answer.
	resp := postChatCompletions(t, s, "What is 2+2? Answer with just the number.", false, 256)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	respBody, _ := io.ReadAll(resp.Body)

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(respBody, &result))
	require.Len(t, result.Choices, 1)

	content := result.Choices[0].Message.Content
	require.NotEmpty(t, content, "response content should not be empty — if this were still encrypted/ciphertext, content would be binary garbage")
	require.Greater(t, result.Usage.PromptTokens, 0, "prompt_tokens should be positive")
	require.Greater(t, result.Usage.CompletionTokens, 0, "completion_tokens should be positive")

	var printable int
	for _, r := range content {
		if r >= 32 && r < 127 {
			printable++
		}
	}
	printableRatio := float64(printable) / float64(len(content))
	require.Greater(t, printableRatio, 0.8, "response should be mostly printable text (got %.0f%%), not encrypted binary", printableRatio*100)

	t.Logf("E2E encryption: content is valid decrypted text (%d chars, %d prompt / %d completion tokens)",
		len(content), result.Usage.PromptTokens, result.Usage.CompletionTokens)
}

func TestIntegration_BillingBalanceDeduction(t *testing.T) {
	s := startSuite(t)

	accountID := "billing-user"
	apiKey, err := s.PgStore.CreateKeyForAccount(accountID)
	require.NoError(t, err, "should create API key for billing user")

	require.NoError(t, s.PgStore.Credit(accountID, 1_000_000, "deposit", "seed"))

	balanceBefore := getBalance(t, s, accountID)
	require.Greater(t, balanceBefore, int64(0), "user should have positive balance before request")

	resp := postChatCompletionsWithAuth(t, s, apiKey, "Say hello.", false, 20)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	balanceAfter := getBalance(t, s, accountID)
	require.Less(t, balanceAfter, balanceBefore, "balance should decrease after inference")

	charges := queryLedgerEntries(t, s, accountID, "charge")
	require.NotEmpty(t, charges, "should have at least one charge entry")
	lastCharge := charges[len(charges)-1]
	require.Less(t, lastCharge.AmountMicroUSD, int64(0), "charge amount should be negative")

	refunds := queryLedgerEntries(t, s, accountID, "refund")
	if len(refunds) > 0 {
		lastRefund := refunds[len(refunds)-1]
		require.Greater(t, lastRefund.AmountMicroUSD, int64(0), "refund amount should be positive")
	}

	expectedMinCost := payments.MinimumCharge()
	require.GreaterOrEqual(t, -lastCharge.AmountMicroUSD+sumAmounts(refunds), expectedMinCost,
		"total cost should be at least the minimum charge")

	assertAccounting(t, s)
	t.Logf("billing: balance %d -> %d (charged %d micro-USD)",
		balanceBefore, balanceAfter, balanceBefore-balanceAfter)
}

func TestIntegration_ProviderPayoutSplit(t *testing.T) {
	s := startSuite(t)

	accountID := "payout-user"
	// The global default platform fee is 0% during the public alpha, so set an
	// explicit non-zero per-account override to exercise the payout/fee split
	// end-to-end (the settlement reads the consumer's PlatformFeePercent).
	feePercent := int64(5)
	require.NoError(t, s.PgStore.CreateUser(&store.User{
		AccountID:          accountID,
		PrivyUserID:        "did:privy:" + accountID,
		PlatformFeePercent: &feePercent,
	}), "should create payout user with a fee override")

	apiKey, err := s.PgStore.CreateKeyForAccount(accountID)
	require.NoError(t, err, "should create API key for payout user")

	require.NoError(t, s.PgStore.Credit(accountID, 1_000_000, "deposit", "seed"))

	resp := postChatCompletionsWithAuth(t, s, apiKey, "Say hello.", false, 20)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	charges := queryLedgerEntries(t, s, accountID, "charge")
	require.NotEmpty(t, charges, "should have charge entries for this account")

	refunds := queryLedgerEntries(t, s, accountID, "refund")
	netCharge := -sumAmounts(charges)
	refundTotal := sumAmounts(refunds)
	totalCost := netCharge + refundTotal

	expectedPayout := payments.ProviderPayoutWithPercent(totalCost, &feePercent)
	expectedFee := payments.PlatformFeeWithPercent(totalCost, &feePercent)

	require.GreaterOrEqual(t, expectedFee, int64(1), "platform fee should be at least 1 micro-USD (5%% of %d)", totalCost)
	require.Equal(t, totalCost, expectedPayout+expectedFee,
		"payout + fee should equal total cost")

	// The override must take effect end-to-end: the platform ledger should show
	// a fee for this request.
	platformFees := queryLedgerEntries(t, s, "platform", "platform_fee")
	require.NotEmpty(t, platformFees, "platform should receive a fee entry for the 5%% override")

	assertAccounting(t, s)
	t.Logf("payout split: total=%d provider=95%%(%d) platform=5%%(%d)", totalCost, expectedPayout, expectedFee)
}

func TestIntegration_InsufficientBalance(t *testing.T) {
	s := startSuite(t)

	poorKey, err := s.PgStore.CreateKeyForAccount("poor-user")
	require.NoError(t, err, "should create API key for poor user")

	require.NoError(t, s.PgStore.Credit("poor-user", 1, "deposit", "seed"))

	resp := postChatCompletionsWithAuth(t, s, poorKey, "Say hello.", false, 20)
	defer resp.Body.Close()

	require.Equal(t, http.StatusPaymentRequired, resp.StatusCode, "should get 402 for insufficient balance")

	respBody, _ := io.ReadAll(resp.Body)
	errType, errMsg := parseErrorResponse(t, respBody)
	require.Equal(t, "insufficient_funds", errType, "error type should be insufficient_funds, got: %s", errMsg)

	t.Logf("insufficient balance: got 402 with type=%s", errType)
}

func TestIntegration_InvalidModel(t *testing.T) {
	s := startSuite(t)

	resp := postChatCompletionsWithModel(t, s, "nonexistent-model-xyz", "Say hello.", false, 20)
	defer resp.Body.Close()

	require.Equal(t, http.StatusNotFound, resp.StatusCode, "should get 404 for unknown model")

	respBody, _ := io.ReadAll(resp.Body)
	errType, _ := parseErrorResponse(t, respBody)
	require.Equal(t, "model_not_found", errType, "error type should be model_not_found")

	t.Logf("invalid model: got 404 with type=%s", errType)
}

func TestIntegration_StreamingContentValidation(t *testing.T) {
	s := startSuite(t)

	resp := postChatCompletions(t, s, "Say exactly: hello world", true, 50)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	require.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))

	var contentChunks []string
	var hasDone bool
	var hasAttestation bool
	var rawDataLines []string
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			hasDone = true
			break
		}
		rawDataLines = append(rawDataLines, data)
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"delta"`
			} `json:"choices"`
			SESignature string `json:"se_signature"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if chunk.SESignature != "" {
			hasAttestation = true
		}
		if len(chunk.Choices) > 0 {
			if chunk.Choices[0].Delta.Content != "" {
				contentChunks = append(contentChunks, chunk.Choices[0].Delta.Content)
			}
			if chunk.Choices[0].Delta.Reasoning != "" {
				contentChunks = append(contentChunks, chunk.Choices[0].Delta.Reasoning)
			}
		}
	}

	require.True(t, hasDone, "stream should end with [DONE]")
	if len(rawDataLines) > 0 {
		t.Logf("first SSE data: %s", rawDataLines[0][:min(len(rawDataLines[0]), 300)])
	}
	require.NotEmpty(t, contentChunks, "should receive at least one content chunk (got %d data lines)", len(rawDataLines))

	fullContent := strings.Join(contentChunks, "")
	require.NotEmpty(t, fullContent, "accumulated content should not be empty")

	var printable int
	for _, r := range fullContent {
		if r >= 32 && r < 127 {
			printable++
		}
	}
	printableRatio := float64(printable) / float64(len(fullContent))
	require.Greater(t, printableRatio, 0.8, "streamed content should be mostly printable text")

	if hasAttestation {
		t.Logf("streaming: %d content chunks, attestation present, content=%q", len(contentChunks), fullContent[:min(len(fullContent), 100)])
	} else {
		t.Logf("streaming: %d content chunks, content=%q", len(contentChunks), fullContent[:min(len(fullContent), 100)])
	}
}

func TestIntegration_ConcurrentRequests(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)

	const numRequests = 5
	type result struct {
		statusCode int
		body       string
	}
	results := make([]result, numRequests)
	var wg sync.WaitGroup
	wg.Add(numRequests)

	for i := 0; i < numRequests; i++ {
		go func(idx int) {
			defer wg.Done()
			ri := inst.NewRequest()
			timer := ri.StartSegment(testbed.SegmentTotalE2E)

			resp := postChatCompletions(t, s, fmt.Sprintf("What is %d+%d?", idx, idx+1), false, 20)
			defer resp.Body.Close()
			respBody, _ := io.ReadAll(resp.Body)

			timer.Stop()
			results[idx] = result{statusCode: resp.StatusCode, body: string(respBody[:min(len(respBody), 200)])}

			if resp.StatusCode == http.StatusOK {
				ri.EndWithDuration(0)
			} else {
				ri.Error(fmt.Errorf("status %d", resp.StatusCode))
			}
		}(i)
	}
	wg.Wait()

	var successCount int
	for i, r := range results {
		if r.statusCode == http.StatusOK {
			successCount++
		} else {
			t.Logf("request %d: status=%d body=%s", i, r.statusCode, r.body)
		}
	}
	require.Greater(t, successCount, 0, "at least some concurrent requests should succeed")

	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())

	assertAccounting(t, s)
	t.Logf("concurrent: %d/%d requests succeeded", successCount, numRequests)
}

func TestIntegration_AttestationHeaders(t *testing.T) {
	s := startSuite(t)

	resp := postChatCompletions(t, s, "Say hello.", false, 20)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	assert.NotEmpty(t, resp.Header.Get("X-Provider-Id"), "X-Provider-Id should be set")
	assert.NotEmpty(t, resp.Header.Get("X-Provider-Trust-Level"), "X-Provider-Trust-Level should be set")
	assert.NotEmpty(t, resp.Header.Get("X-Provider-Chip"), "X-Provider-Chip should be set")

	respBody, _ := io.ReadAll(resp.Body)
	var result struct {
		SESignature  string `json:"se_signature"`
		ResponseHash string `json:"response_hash"`
	}
	require.NoError(t, json.Unmarshal(respBody, &result))
	if resp.Header.Get("X-Provider-Attested") == "true" {
		assert.NotEmpty(t, result.SESignature, "attested response should include se_signature")
		assert.NotEmpty(t, result.ResponseHash, "attested response should include response_hash")
	}

	t.Logf("attestation: provider=%s chip=%s trust=%s se_sig=%d chars",
		resp.Header.Get("X-Provider-Id"),
		resp.Header.Get("X-Provider-Chip"),
		resp.Header.Get("X-Provider-Trust-Level"),
		len(result.SESignature),
	)
}

// findRoutableProvider selects a provider for model via the PRODUCTION routing
// path (ReserveProviderEx), releases the reserved capacity, and returns the
// selected provider — or nil when no provider can serve the model right now.
// It replaces the removed score-based registry.FindProvider as a routability
// probe: the production path applies the same structural/privacy/trust/challenge/
// capacity gates, so "is this provider routable?" assertions hold without a
// parallel routing implementation to keep in sync.
func findRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
	pr := &registry.PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := reg.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	return p
}

func TestIntegration_SwiftProviderRealRoutingGates(t *testing.T) {
	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)

	for _, id := range s.Coordinator.Registry.ProviderIDs() {
		p := s.Coordinator.Registry.GetProvider(id)
		require.NotNil(t, p)
		p.ChallengeVerifiedSIP = true
		p.RuntimeManifestChecked = true
		s.Coordinator.Registry.RecordChallengeSuccess(id)
	}

	model := s.PrimaryModelID()
	found := findRoutableProvider(s.Coordinator.Registry, model)
	require.NotNil(t, found, "Swift provider should be routable after challenge success without ForceTrustProvider")

	resp := postChatCompletions(t, s, "What is 1+1? Answer with just the number.", false, 20)
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	require.Equal(t, http.StatusOK, resp.StatusCode, "body: %s", string(respBody[:min(len(respBody), 500)]))

	t.Logf("Swift provider real routing: status=200 via challenge-verified path")
}

func TestIntegration_FullNetworkSingleSwiftProviderMultiModelRouting(t *testing.T) {
	if os.Getenv("DARKBLOOM_FULL_NETWORK_SMOKE") == "" {
		t.Skip("set DARKBLOOM_FULL_NETWORK_SMOKE=1 to run the full coordinator + real Swift provider multi-model smoke")
	}

	// v0.7.5 one-engine: only CBv2-adapted checkpoints can serve, so the
	// full-network smoke defaults to the production pair.
	modelA := envOr("DARKBLOOM_FULL_NETWORK_MODEL_A", "mlx-community/gpt-oss-20b-MXFP4-Q8")
	modelB := envOr("DARKBLOOM_FULL_NETWORK_MODEL_B", "mlx-community/gemma-4-26B-A4B-it-qat-4bit")
	require.NotEqual(t, modelA, modelB, "full-network smoke requires two distinct model IDs")

	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs:     []testbed.ModelSpec{{ModelIDs: []string{modelA, modelB}, NumProviders: 1}},
		NumUsers:       1,
		SeedBalance:    500_000_000,
		UseMemoryStore: true,
	})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)
	require.Equal(t, 1, s.Coordinator.Registry.ProviderCount(), "smoke must route both models through one provider")

	models := []string{modelA, modelB, modelA}
	var providerID string
	for _, model := range models {
		resp := postChatCompletionsWithModel(t, s, model, "Reply with one short word.", false, 16)
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		require.Equal(t, http.StatusOK, resp.StatusCode, "model %s body: %s", model, string(respBody[:min(len(respBody), 500)]))

		currentProviderID := resp.Header.Get("X-Provider-Id")
		require.NotEmpty(t, currentProviderID, "coordinator should report provider id for model %s", model)
		if providerID == "" {
			providerID = currentProviderID
		} else {
			require.Equal(t, providerID, currentProviderID, "all requests should route to the same multi-model provider")
		}

		var decoded struct {
			Model   string `json:"model"`
			Choices []struct {
				Message struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"message"`
			} `json:"choices"`
		}
		require.NoError(t, json.Unmarshal(respBody, &decoded))
		require.Equal(t, model, decoded.Model)
		require.NotEmpty(t, decoded.Choices)
		message := decoded.Choices[0].Message
		require.NotEmpty(t, message.Content+message.Reasoning)
	}

	t.Logf("full-network multi-model smoke routed %v through provider %s", models, providerID)
}

func TestIntegration_ReferralRewardDistribution(t *testing.T) {
	s := startSuite(t)

	referrerKey := "referrer"
	consumerKey := "referred-consumer"

	require.NoError(t, s.PgStore.Credit(referrerKey, 0, "deposit", "seed"))
	require.NoError(t, s.PgStore.Credit(consumerKey, 1_000_000, "deposit", "seed"))

	// Referral rewards are funded from the platform fee, which defaults to 0%
	// during the public alpha. Give the consumer an explicit non-zero fee
	// override so there is a fee pool to distribute.
	feePercent := int64(5)
	require.NoError(t, s.PgStore.CreateUser(&store.User{
		AccountID:          consumerKey,
		PrivyUserID:        "did:privy:" + consumerKey,
		PlatformFeePercent: &feePercent,
	}), "should create referred consumer with a fee override")

	consumerAPIKey, err := s.PgStore.CreateKeyForAccount(consumerKey)
	require.NoError(t, err, "should create API key for referred consumer")

	billingSvc := s.Coordinator.Server.Billing()
	require.NotNil(t, billingSvc, "billing service should be available")
	referral := billingSvc.Referral()
	require.NotNil(t, referral, "referral service should be available")

	_, err = referral.Register(referrerKey, "TESTREF")
	require.NoError(t, err, "should register referrer")

	err = referral.Apply(consumerKey, "TESTREF")
	require.NoError(t, err, "should apply referral code")

	resp := postChatCompletionsWithAuth(t, s, consumerAPIKey, "Say hello.", false, 20)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	rewards := queryLedgerEntries(t, s, referrerKey, "referral_reward")
	require.NotEmpty(t, rewards, "referrer should receive a referral reward")

	platformFees := queryLedgerEntries(t, s, "platform", "platform_fee")
	require.NotEmpty(t, platformFees, "should have platform fee entries")

	rewardTotal := sumAmounts(rewards)
	feeTotal := sumAmounts(platformFees)
	require.Greater(t, rewardTotal, int64(0), "referral reward should be positive")
	require.Less(t, rewardTotal, feeTotal, "referral reward should be less than total platform fee")

	assertAccounting(t, s)
	t.Logf("referral: reward=%d micro-USD, platform_fee=%d micro-USD", rewardTotal, feeTotal)
}
