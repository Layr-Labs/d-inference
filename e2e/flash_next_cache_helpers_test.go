package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/stretchr/testify/require"
)

// Explicit complete manifest from the selected immutable artifact, never the
// newest HF snapshot or a similarly named Qwen3.5/27B model.
func flashNextCacheArtifacts(t *testing.T) exactCacheArtifactFixture {
	t.Helper()
	root := os.Getenv("DARKBLOOM_QWEN4_MODEL_PATH")
	manifestPath := os.Getenv("DARKBLOOM_FLASH_NEXT_ARTIFACT_MANIFEST")
	require.True(t, filepath.IsAbs(root) && filepath.IsAbs(manifestPath))
	raw, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	var supplied struct {
		ModelID   string                    `json:"model_id"`
		ModelType string                    `json:"model_type"`
		Aggregate string                    `json:"model_aggregate_sha256"`
		Files     []promptcontract.Artifact `json:"files"`
	}
	require.NoError(t, json.Unmarshal(raw, &supplied))
	require.Equal(t, flashNextMatrixModel, supplied.ModelID)
	require.Equal(t, "qwen4_exp", supplied.ModelType)
	fixture := exactCacheArtifactFixture{files: map[string][]byte{}, manifest: promptcontract.Manifest{
		ModelID: supplied.ModelID, ModelType: supplied.ModelType, Files: supplied.Files,
		AggregateSHA256: supplied.Aggregate,
	}}
	seen := map[string]bool{}
	for _, artifact := range supplied.Files {
		require.True(t, filepath.IsLocal(artifact.Path))
		require.False(t, seen[artifact.Path], "duplicate artifact")
		seen[artifact.Path] = true
		info, err := os.Stat(filepath.Join(root, artifact.Path))
		require.NoError(t, err)
		require.Equal(t, artifact.SizeBytes, info.Size())
		// The native loader recomputes the full weight aggregate. Provisioning
		// validates that complete manifest but downloads only prompt roles.
		if !promptcontract.IsPromptRole(artifact.Role) {
			continue
		}
		body, err := os.ReadFile(filepath.Join(root, artifact.Path))
		require.NoError(t, err)
		hash := sha256.Sum256(body)
		require.Equal(t, artifact.SHA256, hex.EncodeToString(hash[:]))
		require.Equal(t, artifact.SizeBytes, int64(len(body)))
		fixture.files[artifact.Path] = body
	}
	sorted := append([]promptcontract.Artifact(nil), supplied.Files...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Path < sorted[j].Path })
	aggregate := sha256.New()
	for _, artifact := range sorted {
		digest, err := hex.DecodeString(artifact.SHA256)
		require.NoError(t, err)
		require.Len(t, digest, sha256.Size)
		_, err = aggregate.Write(digest)
		require.NoError(t, err)
	}
	require.Equal(t, supplied.Aggregate, hex.EncodeToString(aggregate.Sum(nil)))
	require.Len(t, supplied.Files, 31)
	require.True(t, seen["video_preprocessor_config.json"])
	config := fixture.files["config.json"]
	hash := sha256.Sum256(config)
	require.Equal(t, "319b334a1abb705acf06035aa0331bcb7c25976ff93a5035b543548738a10824", hex.EncodeToString(hash[:]))
	var decoded map[string]any
	require.NoError(t, json.Unmarshal(config, &decoded))
	require.Equal(t, "qwen4_exp", decoded["model_type"])
	require.Equal(t, false, decoded["language_model_only"])
	return fixture
}

func flashNextCacheScopeBody() []byte {
	var prompt strings.Builder
	prompt.WriteString("Read this synthetic maintenance log.\n")
	for i := 0; i < 180; i++ {
		fmt.Fprintf(&prompt, "Entry %d: sensor %d reported value %d at tick %d.\n", i, i%17, i*37%1000, i*13)
	}
	prompt.WriteString("Summarize the log in two concise sentences.")
	body, _ := json.Marshal(map[string]any{
		"model":       flashNextMatrixModel,
		"messages":    []map[string]string{{"role": "user", "content": prompt.String()}},
		"temperature": 0, "seed": 0, "max_tokens": 64, "stream": true,
		"stream_options":       map[string]bool{"include_usage": true},
		"chat_template_kwargs": map[string]bool{"enable_thinking": false},
		"user":                 "same-untrusted-caller-label", "prompt_cache_key": "same-untrusted-caller-label",
	})
	return body
}

func flashNextCacheEquivalent(t *testing.T, reference, actual connectedStream) {
	t.Helper()
	// Preserve bytes and actual finish/counts; cache details are necessarily
	// different. No trimming, normalized values or repaired output here.
	require.Equal(t, reference.Content, actual.Content)
	require.Equal(t, reference.Reasoning, actual.Reasoning)
	require.Equal(t, reference.Finish, actual.Finish)
	require.Empty(t, reference.Tools)
	require.Empty(t, actual.Tools)
	var first, second map[string]any
	require.NoError(t, json.Unmarshal(reference.Usage, &first))
	require.NoError(t, json.Unmarshal(actual.Usage, &second))
	for _, key := range []string{"prompt_tokens", "completion_tokens", "total_tokens"} {
		require.Contains(t, first, key)
		require.Equal(t, first[key], second[key], key)
	}
}

func flashNextCacheMetrics(t *testing.T, output, name, baseURL, keyPath string) {
	t.Helper()
	key, err := os.ReadFile(keyPath)
	require.NoError(t, err)
	request, err := http.NewRequest(http.MethodGet, baseURL+"/metrics", nil)
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(key)))
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	require.Equal(t, http.StatusOK, response.StatusCode)
	raw, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	require.NoError(t, err)
	require.Less(t, len(raw), 8<<20)
	require.NoError(t, flashNextMatrixWrite(filepath.Join(output, name+".metrics.json"), map[string]any{"metrics": string(raw)}))
	for _, field := range []string{"kv_active_requests", "kv_waiting_requests", "paged_kv_live_bytes", "paged_kv_reserved_bytes", "complete_prefix_key_persistent"} {
		found := 0
		for _, line := range strings.Split(string(raw), "\n") {
			if !strings.HasPrefix(line, field+"{") {
				continue
			}
			parts := strings.Fields(line)
			require.GreaterOrEqual(t, len(parts), 2)
			value, err := strconv.ParseFloat(parts[len(parts)-1], 64)
			require.NoError(t, err)
			require.Zero(t, value, field)
			found++
		}
		require.Equal(t, 1, found, "exact one-model metric required: "+field)
	}
}
