package e2e

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// TestIntegrationExactCacheRecurrentCompanyLeaves drives the chunk-agnostic
// recurrent capture rule through the real coordinator and a real provider.
//
// Shape: a ~9k-token Qwen prompt is primed once (fleet-novel: the coordinator
// sends a 0 repeat hint and the provider settles `skipped_novel`, no file),
// then sent again while a second tenant's request is already decoding on the
// same provider. The donor prefills in plain chunks beside that company; the
// company finishes mid-prompt and the donor continues on its solo stripe.
// Under the earlier uniform-chunk rule the chunk change disarmed capture, so
// the donor published only its last plain-chunk boundary (3,072 at most) and
// the next turn restored that or nothing. The coordinator's observed demand
// from the prime names the fork hint, the provider writes, and the repeat
// must restore a boundary at least as deep as the last full chunk end.
//
// Gated: DARKBLOOM_EXACT_CACHE_RECURRENT_MODEL names a cached `qwen3_5` or
// `qwen3_5_moe` checkpoint (for example EigenLabs/Qwen3.5-9B-MLX-4bit-mtp).
// The ordinary testbed checkpoints are attention-only and never take this
// path.
func TestIntegrationExactCacheRecurrentCompanyLeaves(t *testing.T) {
	if testing.Short() {
		t.Skip("requires the real Swift provider and a local recurrent MLX checkpoint")
	}
	model := os.Getenv("DARKBLOOM_EXACT_CACHE_RECURRENT_MODEL")
	if model == "" {
		t.Skip("set DARKBLOOM_EXACT_CACHE_RECURRENT_MODEL to a cached qwen3_5 checkpoint")
	}
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs:                 []testbed.ModelSpec{{ModelID: model, NumProviders: 1}},
		NumUsers:                   2,
		EnableEphemeralPrefixCache: true,
		// The provider enables the SSD cache by default only for production
		// catalog IDs; a cached dev artifact needs the explicit opt-in.
		PrefixCacheMode: "ssd",
		// Company needs a second running row on the one provider.
		MaxConcurrent: 4,
	})
	require.NoError(t, suite.Start(context.Background()))
	t.Cleanup(suite.Stop)

	providers := liveProviders(suite.Coordinator.Registry)
	require.Len(t, providers, 1)
	provider := providers[0]
	require.NoError(t, suite.Coordinator.Registry.SendLoadModel(provider.ID, model))
	loaded := waitForLoadedModel(t, provider, model, 5*time.Minute)
	require.Eventually(t, func() bool {
		provider.Mu().Lock()
		_, advertised := provider.PrefixCacheV2Models[model]
		provider.Mu().Unlock()
		return advertised
	}, 4*time.Minute, 250*time.Millisecond,
		"the recurrent slot did not advertise complete-checkpoint capability; provider statuses: %s",
		func() string {
			provider.Mu().Lock()
			defer provider.Mu().Unlock()
			encoded, _ := json.Marshal(provider.PrefixCacheStatuses)
			return string(encoded)
		}())

	fixture := loadExactCacheArtifacts(t, model, loaded.WeightHash)
	contractArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contractID, err := promptcontract.ContractID(contractArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	provider.Mu().Lock()
	capability := provider.PrefixCacheV2Models[model]
	provider.Mu().Unlock()
	require.Equal(t, contractID, capability.PromptContractID)
	require.Equal(t, loaded.WeightHash, capability.ModelAggregateHash)

	startExactCacheSidecar(t, suite, fixture, model, contractID)
	suite.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, WeightHash: loaded.WeightHash,
	}})
	maxDiscountMs, maxCostFraction := 1000.0, .35
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(
		registry.CacheRoutingConfig{
			Mode:            registry.CacheRoutingOn,
			ActivationPct:   100,
			TTL:             10 * time.Minute,
			MaxHolders:      4,
			MaxDiscountMs:   &maxDiscountMs,
			MaxCostFraction: &maxCostFraction,
			MasterKey:       "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
		}))

	donorPrompt := recurrentDonorPrompt()
	donorUser, companyUser := suite.Users[0].APIKey, suite.Users[1].APIKey

	// 1. Prime. Fleet-novel: no demand hint above the floor, no local tag
	// history, so the provider declines the write. This request is also what
	// teaches the coordinator's demand index the prefix.
	before := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	prime := postRecurrentChat(t, suite, donorUser, model, donorPrompt, 16)
	require.Zero(t, prime.cachedTokens, "the prime must prefill cold")
	requireRecurrentMarker(t, "prime", prime.content)
	require.GreaterOrEqual(t, prime.promptTokens, 8_192+256,
		"the donor prompt must reach past the 8,192 boundary; lengthen recurrentDonorPrompt")
	require.Eventually(t, func() bool {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().SSDMisses > before.SSDMisses
	}, 2*time.Minute, 250*time.Millisecond, "the prime did not enter the cache protocol")
	settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
	holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
	require.Zero(t, holders, "a fleet-novel prime must not publish a holder (skipped_novel)")

	// 2. Donor under company. The company request streams and is submitted
	// first; its first content token is the provider's evidence that the row
	// is decoding, and only then is the donor submitted, so the donor's first
	// prompt chunks share the step with a decoding row (plain chunks, not the
	// solo stripe). The company is then cancelled while the donor is still
	// prefilling (the donor's own first token marks the end of its prefill),
	// so the donor's later chunks run solo again: that is the cap switch the
	// old uniform-chunk rule disarmed on. A client disconnect reaches the
	// provider as a cancel (`sendProviderCancel`), which is how a real
	// tenant leaves mid-prompt. The provider's chunk trace itself is the
	// engine live test's job.
	companyCtx, cancelCompany := context.WithCancel(suite.Ctx)
	defer cancelCompany()
	companyFirst := make(chan time.Time, 1)
	companyTokens := make(chan time.Time, 8192)
	companyDone := make(chan recurrentStreamOutcome, 1)
	go func() {
		result, err := streamRecurrentChat(companyCtx, suite, companyUser, model, recurrentCompanyPrompt(), 512, companyFirst, companyTokens)
		companyDone <- recurrentStreamOutcome{result: result, err: err}
	}()
	select {
	case at := <-companyFirst:
		t.Logf("company first token at %s", at.Format(time.StampMilli))
	case outcome := <-companyDone:
		require.NoError(t, outcome.err)
		t.Fatal("company stream ended before its first content token")
	case <-time.After(3 * time.Minute):
		t.Fatal("company never produced a first token")
	}
	// Cancel the company by the donor's progress, not by the clock. Solo,
	// the company decodes a token every few milliseconds; once the donor is
	// prefilling beside it, every engine step carries one donor chunk (the
	// plain cap, 512 tokens) and one company token, so the company's
	// inter-token gap jumps by an order of magnitude. Sample the solo
	// cadence first, submit the donor, then count the company tokens that
	// arrive at the slower cadence and cancel at the Nth: the donor has then
	// computed about N plain chunks, far below the depth the repeat must
	// restore, whatever the machine's speed.
	solo := recurrentGapSample{}
	sampleDeadline := time.After(2 * time.Minute)
	for len(solo.times) < recurrentSoloCadenceSamples {
		select {
		case at := <-companyTokens:
			solo.times = append(solo.times, at)
		case outcome := <-companyDone:
			require.NoError(t, outcome.err)
			t.Fatalf("company stream ended after %d solo tokens", len(solo.times))
		case <-sampleDeadline:
			t.Fatalf("company produced only %d solo tokens", len(solo.times))
		}
	}
	threshold := recurrentSlowGapThreshold(solo)
	donorFirst := make(chan time.Time, 1)
	donorDone := make(chan recurrentStreamOutcome, 1)
	donorStarted := time.Now()
	go func() {
		result, err := streamRecurrentChat(suite.Ctx, suite, donorUser, model, donorPrompt, 16, donorFirst, nil)
		donorDone <- recurrentStreamOutcome{result: result, err: err}
	}()
	slow := 0
	previous := solo.times[len(solo.times)-1]
	deadline := time.After(3 * time.Minute)
	for slow < recurrentCompanyChunksBesideDonor {
		select {
		case at := <-companyTokens:
			if at.After(donorStarted) && at.Sub(previous) > threshold {
				slow++
			}
			previous = at
		case outcome := <-companyDone:
			require.NoError(t, outcome.err)
			t.Fatalf("company stream ended after %d slow tokens, before the donor was beside it", slow)
		case <-deadline:
			t.Fatalf("company never slowed beside the donor: %d slow tokens, threshold %s", slow, threshold)
		}
	}
	companyLeft := time.Now()
	cancelCompany()
	t.Logf("company cancelled after %d tokens beside the donor (solo median gap %s, threshold %s)",
		slow, solo.median().Round(time.Millisecond), threshold.Round(time.Millisecond))
	companyOutcome := <-companyDone
	company := companyOutcome.result
	require.Error(t, companyOutcome.err, "the company stream must have been cut short by the cancel")
	require.True(t, company.firstToken.Before(donorStarted),
		"the donor must be submitted after the company's first token")
	require.True(t, company.lastToken.After(donorStarted),
		"the company must still be decoding after the donor was submitted: last token %s, donor started %s",
		company.lastToken.Format(time.StampMilli), donorStarted.Format(time.StampMilli))
	donorOutcome := <-donorDone
	require.NoError(t, donorOutcome.err)
	donor := donorOutcome.result
	require.True(t, companyLeft.Before(donor.firstToken),
		"the company must leave while the donor is still prefilling: left %s, donor first token %s",
		companyLeft.Format(time.StampMilli), donor.firstToken.Format(time.StampMilli))
	require.Zero(t, donor.cachedTokens, "nothing durable existed before the donor")
	requireRecurrentMarker(t, "donor", donor.content)
	require.Eventually(t, func() bool {
		holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return holders > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"the donor under company did not publish a holder")
	settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)

	// 3. Repeat. The holder is the only provider; what matters is the depth.
	hitsBefore := suite.Coordinator.Registry.CacheRoutingLifecycleStatus().SSDHits
	repeat := postRecurrentChat(t, suite, donorUser, model, donorPrompt, 16)
	require.Positive(t, repeat.cachedTokens, "the repeat did not restore a checkpoint")
	requireRecurrentMarker(t, "repeat", repeat.content)
	require.Zero(t, repeat.cachedTokens%256, "restored depth %d is not block aligned", repeat.cachedTokens)
	// The deepest boundary is the last full range end before the ragged
	// tail, at most one solo stripe below the prompt end; the largest
	// production stripe is the dense default of 4,096
	// (`EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens`). The old
	// uniform-chunk rule disarmed at the cap switch, which the company's
	// cancel forces after about `recurrentCompanyChunksBesideDonor` plain
	// chunks (a few thousand tokens at most), so it could publish nothing
	// deeper; the floor below is far above that and far below the allowance.
	require.GreaterOrEqual(t, repeat.cachedTokens, repeat.promptTokens-4_096,
		"restored %d of %d prompt tokens: capture stopped early", repeat.cachedTokens, repeat.promptTokens)
	require.Greater(t, repeat.cachedTokens, 8_192,
		"restored %d tokens: no deeper than the uniform-chunk rule could reach", repeat.cachedTokens)
	require.Eventually(t, func() bool {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().SSDHits > hitsBefore
	}, 30*time.Second, 100*time.Millisecond, "hit lifecycle telemetry did not advance")
	t.Logf("recurrent company-leaves: prompt=%d restored=%d prime=%s donor=%s repeat=%s company=%s",
		repeat.promptTokens, repeat.cachedTokens,
		prime.elapsed.Round(10*time.Millisecond), donor.finished.Sub(donorStarted).Round(10*time.Millisecond),
		repeat.elapsed.Round(10*time.Millisecond), companyLeft.Sub(company.firstToken).Round(10*time.Millisecond))
}

// requireRecurrentMarker checks the answer semantically. The prime prefills
// solo, the donor under company and the repeat from a restored state, and on
// the `qwen3_5_moe` path a cold answer already varies by chunk width and
// decode batch composition (see the 2026-09-27 parity report), so exact
// equality across those schedules would reject correct behaviour. The prompt
// fixes the answer: the release marker, and never the backup marker.
func requireRecurrentMarker(t *testing.T, phase, content string) {
	t.Helper()
	require.Contains(t, content, recurrentReleaseMarker, "%s answer lost the release marker: %q", phase, content)
	require.NotContains(t, content, recurrentBackupMarker, "%s answer leaked the backup marker: %q", phase, content)
}

const (
	recurrentReleaseMarker = "ALDER-427"
	recurrentBackupMarker  = "BRONZE-913"
)

// recurrentCompanyChunksBesideDonor is how many company tokens must arrive at
// the slowed, one-per-step cadence after the donor was submitted before the
// test cancels the company. Each such step carried one plain donor chunk, so
// the donor has computed about that many chunks (at most a few thousand
// tokens) when the company leaves: enough to have prefilled beside it, far
// below the depth the repeat must restore.
const recurrentCompanyChunksBesideDonor = 4

// recurrentSoloCadenceSamples is how many company tokens (the first
// included) are observed solo, before the donor is submitted, to measure
// the company's unshared decode cadence.
const recurrentSoloCadenceSamples = 9

// recurrentGapSample holds the arrival times of the company's solo tokens.
type recurrentGapSample struct {
	times []time.Time
}

// median is the median inter-token gap of the solo sample.
func (s recurrentGapSample) median() time.Duration {
	var gaps []time.Duration
	for i := 1; i < len(s.times); i++ {
		gaps = append(gaps, s.times[i].Sub(s.times[i-1]))
	}
	if len(gaps) == 0 {
		return 0
	}
	sort.Slice(gaps, func(i, j int) bool { return gaps[i] < gaps[j] })
	return gaps[len(gaps)/2]
}

// recurrentSlowGapThreshold separates solo decode from decode beside a
// prefilling donor: five times the solo median, never below 50 ms.
func recurrentSlowGapThreshold(sample recurrentGapSample) time.Duration {
	threshold := 5 * sample.median()
	if threshold < 50*time.Millisecond {
		threshold = 50 * time.Millisecond
	}
	return threshold
}

type recurrentStreamResult struct {
	content      string
	chunks       int
	firstToken   time.Time
	lastToken    time.Time
	finished     time.Time
	promptTokens int
	cachedTokens int
}

type recurrentStreamOutcome struct {
	result recurrentStreamResult
	err    error
}

// streamRecurrentChat posts a streaming chat completion (with usage in the
// terminal chunk), reports the wall-clock time of the first content delta on
// `firstToken` (once) and of every content delta on `tokens` (when non-nil,
// never blocking), then returns when the stream ends or `ctx` is cancelled. It never asserts: it runs on a worker goroutine, and the test
// goroutine judges the returned result and error. The first delta is the
// provider's evidence that the row has left prefill and is decoding.
func streamRecurrentChat(
	ctx context.Context, suite *testbed.Suite, apiKey, model, prompt string, maxTokens int,
	firstToken chan<- time.Time, tokens chan<- time.Time,
) (recurrentStreamResult, error) {
	var result recurrentStreamResult
	body, err := json.Marshal(map[string]any{
		"model":    model,
		"messages": []map[string]string{{"role": "user", "content": prompt}},
		"stream":   true, "max_tokens": maxTokens, "temperature": 0,
		"stream_options":  map[string]any{"include_usage": true},
		"reasoning":       map[string]any{"enabled": false},
		"enable_thinking": false,
	})
	if err != nil {
		return result, err
	}
	request, err := http.NewRequestWithContext(
		ctx, http.MethodPost,
		suite.Coordinator.BaseURL()+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return result, err
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 10 * time.Minute}).Do(request)
	if err != nil {
		return result, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		payload, _ := io.ReadAll(response.Body)
		return result, fmt.Errorf("stream status %d: %s", response.StatusCode, string(payload))
	}
	var content strings.Builder
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	signalled := false
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *struct {
				PromptTokens        int `json:"prompt_tokens"`
				PromptTokensDetails struct {
					CachedTokens int `json:"cached_tokens"`
				} `json:"prompt_tokens_details"`
			} `json:"usage"`
		}
		if json.Unmarshal([]byte(payload), &chunk) != nil {
			continue
		}
		if chunk.Usage != nil {
			result.promptTokens = chunk.Usage.PromptTokens
			result.cachedTokens = chunk.Usage.PromptTokensDetails.CachedTokens
		}
		if len(chunk.Choices) == 0 {
			continue
		}
		if delta := chunk.Choices[0].Delta.Content; delta != "" {
			content.WriteString(delta)
			result.chunks++
			result.lastToken = time.Now()
			if tokens != nil {
				select {
				case tokens <- result.lastToken:
				default:
				}
			}
			if !signalled {
				result.firstToken = result.lastToken
				firstToken <- result.firstToken
				signalled = true
			}
		}
	}
	result.finished = time.Now()
	result.content = content.String()
	if err := scanner.Err(); err != nil {
		return result, err
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if !signalled {
		return result, fmt.Errorf("the stream produced no content")
	}
	return result, nil
}

type recurrentChatResult struct {
	content      string
	cachedTokens int
	promptTokens int
	elapsed      time.Duration
	finished     time.Time
}

func postRecurrentChat(
	t *testing.T, suite *testbed.Suite, apiKey, model, prompt string, maxTokens int,
) recurrentChatResult {
	t.Helper()
	// Qwen templates think by default; the typed nested control (and its
	// top-level alias) keeps the whole budget for the visible answer so
	// content comparisons are meaningful.
	body, err := json.Marshal(map[string]any{
		"model":    model,
		"messages": []map[string]string{{"role": "user", "content": prompt}},
		"stream":   false, "max_tokens": maxTokens, "temperature": 0,
		"reasoning":       map[string]any{"enabled": false},
		"enable_thinking": false,
	})
	require.NoError(t, err)
	request, err := http.NewRequestWithContext(
		suite.Ctx, http.MethodPost,
		suite.Coordinator.BaseURL()+"/v1/chat/completions", bytes.NewReader(body))
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Content-Type", "application/json")
	started := time.Now()
	response, err := (&http.Client{Timeout: 10 * time.Minute}).Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	payload, err := io.ReadAll(response.Body)
	finished := time.Now()
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode, string(payload))
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens        int `json:"prompt_tokens"`
			PromptTokensDetails struct {
				CachedTokens int `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(payload, &decoded))
	require.NotEmpty(t, decoded.Choices)
	t.Logf("chat %s: %s prompt=%d cached=%d timing=%s", response.Header.Get("X-Provider-Id"),
		finished.Sub(started).Round(10*time.Millisecond), decoded.Usage.PromptTokens,
		decoded.Usage.PromptTokensDetails.CachedTokens, response.Header.Get("X-Timing"))
	return recurrentChatResult{
		content:      decoded.Choices[0].Message.Content,
		cachedTokens: decoded.Usage.PromptTokensDetails.CachedTokens,
		promptTokens: decoded.Usage.PromptTokens,
		elapsed:      finished.Sub(started),
		finished:     finished,
	}
}

// recurrentDonorPrompt is a deterministic ~9k-token prompt for Qwen's
// tokenizer: numbered records that never repeat, ending in a question whose
// answer is fixed by the first line, so a restored continuation is
// comparable to the cold one at temperature 0.
func recurrentDonorPrompt() string {
	var builder strings.Builder
	fmt.Fprintf(&builder, "The release marker is %s. The backup marker is %s. Preserve both exactly.\n",
		recurrentReleaseMarker, recurrentBackupMarker)
	for n := 0; n < 460; n++ {
		fmt.Fprintf(&builder,
			"Record %d: station %d reported a routine inspection. The reservoir gauge was checked, "+
				"the inlet valve was serviced, and the next visit is scheduled for cycle %d.\n",
			n, n%17, n+3)
	}
	builder.WriteString("What is the release marker given at the beginning? Reply with that marker only; do not include the other marker.")
	return builder.String()
}

// recurrentCompanyPrompt is a second tenant's ~1.5k-token request that decodes
// for a while (max_tokens 256), so the donor's first prompt chunks share the
// provider with a running row.
func recurrentCompanyPrompt() string {
	var builder strings.Builder
	for n := 0; n < 70; n++ {
		fmt.Fprintf(&builder, "Note %d: the harbor log lists tide, wind and visibility for the morning watch.\n", n)
	}
	builder.WriteString("Write a detailed, numbered summary of every note above, one line per note.")
	return builder.String()
}
