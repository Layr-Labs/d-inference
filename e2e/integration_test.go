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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
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
	return testbed.StartSuite(t, testbed.SuiteConfig{})
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
	bodyJSON, err := json.Marshal(body)
	require.NoError(t, err)

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
	bodyJSON, err := json.Marshal(body)
	require.NoError(t, err)

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
	require.NoError(t, rows.Err(), "iterate ledger entries")
	return entries
}

func getBalance(t *testing.T, s *testbed.Suite, accountID string) (int64, error) {
	t.Helper()
	pool, err := pgxpool.New(s.Ctx, s.Pg.DatabaseURL)
	if err != nil {
		return 0, err
	}
	defer pool.Close()

	var balance int64
	err = pool.QueryRow(s.Ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID).Scan(&balance)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return balance, err
}

func sumAmounts(entries []ledgerEntry) int64 {
	var total int64
	for _, e := range entries {
		total += e.AmountMicroUSD
	}
	return total
}

func printableASCIIRatio(text string) float64 {
	var printable, total int
	for _, r := range text {
		total++
		if r == '\n' || r == '\t' || (r >= 32 && r < 127) {
			printable++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(printable) / float64(total)
}

func TestIntegration_NonStreamingInference(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	ri := inst.NewRequest()
	timer := ri.StartSegment(testbed.SegmentTotalE2E)

	// The default gpt-oss fixture may spend its first tokens in the reasoning
	// channel. Give it enough room to produce final plaintext content so this
	// smoke also verifies coordinator decryption and response normalization.
	resp := postChatCompletions(t, s, "What is 2+2? Answer with just the number.", false, 256)
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	timer.Stop()

	require.Equal(t, http.StatusOK, resp.StatusCode, "body: %s", string(respBody[:min(len(respBody), 500)]))
	var decoded struct {
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
	require.NoError(t, json.Unmarshal(respBody, &decoded))
	require.Len(t, decoded.Choices, 1)
	content := decoded.Choices[0].Message.Content
	require.NotEmpty(t, content, "live non-streaming inference must return decrypted final content")
	require.Greater(t, printableASCIIRatio(content), 0.8,
		"non-streaming content should be printable plaintext, not encrypted bytes")
	require.Greater(t, decoded.Usage.PromptTokens, 0)
	require.Greater(t, decoded.Usage.CompletionTokens, 0)

	ri.EndWithDuration(0)
	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())
	t.Logf("non-streaming: %d prompt / %d completion tokens, content=%q",
		decoded.Usage.PromptTokens, decoded.Usage.CompletionTokens, content[:min(len(content), 80)])

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

	// The default gpt-oss fixture may spend its first tokens in the Harmony
	// analysis channel, while the assertion below also requires final content.
	const prompt = "What is 2+2? Answer with just the number."
	type completion struct {
		content   string
		reasoning string
		tokens    int
	}
	run := func(attempt int) completion {
		resp := postChatCompletions(t, s, prompt, false, 256)
		defer resp.Body.Close()
		respBody, err := io.ReadAll(resp.Body)
		require.NoError(t, err, "attempt %d", attempt)
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

func TestIntegration_BillingAccounting(t *testing.T) {
	s := startSuite(t)

	const totalRequests = 3
	const referralCode = "TESTREF"
	consumerID := "billing-consumer"
	referrerID := "billing-referrer"
	feePercent := int64(5)

	require.NoError(t, s.PgStore.CreateUser(&store.User{
		AccountID:          consumerID,
		PrivyUserID:        "did:privy:" + consumerID,
		PlatformFeePercent: &feePercent,
	}), "create billing consumer with explicit platform fee")
	require.NoError(t, s.PgStore.CreateUser(&store.User{
		AccountID:   referrerID,
		PrivyUserID: "did:privy:" + referrerID,
	}), "create billing referrer")
	require.NoError(t, s.PgStore.Credit(consumerID, 1_000_000, "deposit", "seed"))

	apiKey, err := s.PgStore.CreateKeyForAccount(consumerID)
	require.NoError(t, err)
	billingSvc := s.Coordinator.Server.Billing()
	require.NotNil(t, billingSvc)
	referral := billingSvc.Referral()
	require.NotNil(t, referral)
	_, err = referral.Register(referrerID, referralCode)
	require.NoError(t, err)
	require.NoError(t, referral.Apply(consumerID, referralCode))

	balanceBefore, err := getBalance(t, s, consumerID)
	require.NoError(t, err)
	require.Positive(t, balanceBefore)
	providerIDs := s.Coordinator.Registry.ProviderIDs()
	require.Len(t, providerIDs, 1, "billing accounting requires the default single-provider fixture")
	providerID := providerIDs[0]
	provider := s.Coordinator.Registry.GetProvider(providerID)
	require.NotNil(t, provider)
	provider.Mu().Lock()
	providerAccountID := provider.AccountID
	providerKey := provider.PublicKey
	provider.Mu().Unlock()
	require.NotEmpty(t, providerAccountID, "testbed provider must be linked for payout verification")
	require.NotEmpty(t, providerKey)
	providerBalanceBefore, err := getBalance(t, s, providerAccountID)
	require.NoError(t, err)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)

	for i := range totalRequests {
		ri := inst.NewRequest()
		timer := ri.StartSegment(testbed.SegmentTotalE2E)
		resp := postChatCompletionsWithAuth(t, s, apiKey,
			fmt.Sprintf("Billing request %d: reply with one short word.", i+1), false, 32)
		respBody, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		timer.Stop()
		require.NoError(t, readErr)
		require.Equal(t, http.StatusOK, resp.StatusCode,
			"request %d body: %s", i+1, string(respBody[:min(len(respBody), 500)]))

		var decoded struct {
			Choices []json.RawMessage `json:"choices"`
			Usage   struct {
				PromptTokens     int `json:"prompt_tokens"`
				CompletionTokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		require.NoError(t, json.Unmarshal(respBody, &decoded), "request %d", i+1)
		require.NotEmpty(t, decoded.Choices, "request %d must contain a live completion", i+1)
		require.Positive(t, decoded.Usage.PromptTokens, "request %d prompt usage", i+1)
		require.Positive(t, decoded.Usage.CompletionTokens, "request %d completion usage", i+1)

		currentProviderID := resp.Header.Get("X-Provider-Id")
		require.NotEmpty(t, currentProviderID, "request %d provider metadata", i+1)
		require.Equal(t, providerID, currentProviderID,
			"shared fixture must settle all requests for the serving provider")
		ri.EndWithDuration(0)
	}

	balanceAfter, err := getBalance(t, s, consumerID)
	require.NoError(t, err)
	require.Less(t, balanceAfter, balanceBefore)
	totalCost := balanceBefore - balanceAfter
	require.GreaterOrEqual(t, totalCost, int64(totalRequests)*payments.MinimumCharge())

	charges := queryLedgerEntries(t, s, consumerID, "charge")
	refunds := queryLedgerEntries(t, s, consumerID, "refund")
	require.Len(t, charges, totalRequests, "each successful request must produce one consumer charge")
	require.Equal(t, balanceAfter-balanceBefore, sumAmounts(charges)+sumAmounts(refunds),
		"consumer ledger delta must equal the observed balance delta")

	earnings, err := s.PgStore.GetProviderEarnings(providerKey, totalRequests+1)
	require.NoError(t, err)
	require.Len(t, earnings, totalRequests, "each live inference must record one provider earning")
	var providerPayout int64
	for _, earning := range earnings {
		require.Equal(t, providerID, earning.ProviderID)
		require.Equal(t, providerAccountID, earning.AccountID)
		require.Positive(t, earning.PromptTokens)
		require.Positive(t, earning.CompletionTokens)
		require.Positive(t, earning.AmountMicroUSD)
		providerPayout += earning.AmountMicroUSD
	}
	providerBalanceAfter, err := getBalance(t, s, providerAccountID)
	require.NoError(t, err)
	require.Equal(t, providerPayout, providerBalanceAfter-providerBalanceBefore,
		"linked provider balance delta must equal recorded earnings")

	platformFees := queryLedgerEntries(t, s, "platform", "platform_fee")
	rewards := queryLedgerEntries(t, s, referrerID, "referral_reward")
	require.Len(t, platformFees, totalRequests, "each request must credit the remaining platform fee")
	require.Len(t, rewards, totalRequests, "each request must distribute a referral reward")
	platformFeeTotal := sumAmounts(platformFees)
	rewardTotal := sumAmounts(rewards)
	require.Positive(t, platformFeeTotal)
	require.Positive(t, rewardTotal)
	require.Equal(t, totalCost, providerPayout+platformFeeTotal+rewardTotal,
		"consumer cost must split exactly into provider payout, platform fee, and referral reward")

	assertAccounting(t, s)
	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())
	t.Logf("billing: %d requests cost=%d provider=%d platform=%d referral=%d",
		totalRequests, totalCost, providerPayout, platformFeeTotal, rewardTotal)
}

func TestIntegration_StreamingContentValidation(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	ri := inst.NewRequest()
	timer := ri.StartSegment(testbed.SegmentTotalE2E)

	resp := postChatCompletions(t, s, "Say exactly: hello world", true, 64)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)
	require.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))

	var contentChunks []string
	var dataChunks int
	var hasDone bool
	var hasAttestation bool
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if hasDone {
			require.Failf(t, "data after [DONE]", "unexpected SSE data frame: %s", data)
		}
		if data == "[DONE]" {
			hasDone = true
			continue
		}

		dataChunks++
		ri.StreamChunk(dataChunks)
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"delta"`
			} `json:"choices"`
			SESignature string `json:"se_signature"`
		}
		require.NoError(t, json.Unmarshal([]byte(data), &chunk),
			"every SSE data frame before [DONE] must be valid JSON: %s", data)
		if chunk.SESignature != "" {
			hasAttestation = true
		}
		for _, choice := range chunk.Choices {
			if choice.Delta.Content != "" {
				contentChunks = append(contentChunks, choice.Delta.Content)
			}
			if choice.Delta.Reasoning != "" {
				contentChunks = append(contentChunks, choice.Delta.Reasoning)
			}
		}
	}
	require.NoError(t, scanner.Err())
	timer.Stop()

	require.True(t, hasDone, "stream must end with a [DONE] data frame")
	require.Positive(t, dataChunks, "stream must contain JSON chunks before [DONE]")
	require.NotEmpty(t, contentChunks,
		"stream must contain at least one payload-bearing content or reasoning delta")
	fullContent := strings.Join(contentChunks, "")
	require.NotEmpty(t, fullContent)
	require.Greater(t, printableASCIIRatio(fullContent), 0.8,
		"streamed payload should be decrypted printable plaintext")

	ri.EndWithDuration(0)
	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())
	t.Logf("streaming: %d JSON chunks, attestation=%t, content=%q",
		dataChunks, hasAttestation, fullContent[:min(len(fullContent), 100)])
	assertAccounting(t, s)
}

func TestIntegration_ConcurrentRequests(t *testing.T) {
	s := startSuite(t)

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	client := &http.Client{Timeout: httpTimeout}

	const numRequests = 5
	type result struct {
		statusCode int
		body       string
		providerID string
		hasPayload bool
		err        error
	}
	results := make([]result, numRequests)
	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(numRequests)

	for i := range numRequests {
		go func(idx int) {
			defer wg.Done()
			<-start

			ri := inst.NewRequest()
			timer := ri.StartSegment(testbed.SegmentTotalE2E)
			bodyJSON, err := json.Marshal(map[string]any{
				"model":       s.PrimaryModelID(),
				"messages":    []map[string]string{{"role": "user", "content": fmt.Sprintf("What is %d+%d?", idx, idx+1)}},
				"stream":      false,
				"max_tokens":  32,
				"temperature": 0.0,
			})
			if err != nil {
				results[idx].err = err
				ri.Error(err)
				timer.Stop()
				return
			}
			req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
				s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
			if err != nil {
				results[idx].err = err
				ri.Error(err)
				timer.Stop()
				return
			}
			req.Header.Set("Authorization", "Bearer testbed-admin-key")
			req.Header.Set("Content-Type", "application/json")

			resp, err := client.Do(req)
			if err != nil {
				results[idx].err = err
				ri.Error(err)
				timer.Stop()
				return
			}
			respBody, readErr := io.ReadAll(resp.Body)
			resp.Body.Close()
			timer.Stop()
			if readErr != nil {
				results[idx].err = readErr
				ri.Error(readErr)
				return
			}

			var decoded struct {
				Choices []struct {
					Message struct {
						Content   string `json:"content"`
						Reasoning string `json:"reasoning"`
					} `json:"message"`
				} `json:"choices"`
			}
			if err := json.Unmarshal(respBody, &decoded); err != nil {
				results[idx].err = err
				ri.Error(err)
				return
			}
			hasPayload := len(decoded.Choices) > 0 &&
				decoded.Choices[0].Message.Content+decoded.Choices[0].Message.Reasoning != ""
			results[idx] = result{
				statusCode: resp.StatusCode,
				body:       string(respBody[:min(len(respBody), 300)]),
				providerID: resp.Header.Get("X-Provider-Id"),
				hasPayload: hasPayload,
			}
			if resp.StatusCode != http.StatusOK {
				ri.Error(fmt.Errorf("status %d", resp.StatusCode))
				return
			}
			ri.EndWithDuration(0)
		}(i)
	}
	close(start)
	wg.Wait()

	var providerID string
	for i, result := range results {
		require.NoError(t, result.err, "concurrent request %d", i)
		require.Equal(t, http.StatusOK, result.statusCode,
			"concurrent request %d body: %s", i, result.body)
		require.True(t, result.hasPayload, "concurrent request %d returned no live payload", i)
		require.NotEmpty(t, result.providerID, "concurrent request %d missing provider metadata", i)
		if providerID == "" {
			providerID = result.providerID
		} else {
			require.Equal(t, providerID, result.providerID,
				"all concurrent requests should reach the single live provider")
		}
	}

	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())
	assertAccounting(t, s)
	t.Logf("concurrent: all %d requests completed via provider %s", numRequests, providerID)
}

func TestIntegration_ProviderMetadata(t *testing.T) {
	s := startSuite(t)

	resp := postChatCompletions(t, s, "Say hello.", false, 32)
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode,
		"body: %s", string(respBody[:min(len(respBody), 500)]))

	require.NotEmpty(t, resp.Header.Get("X-Provider-Id"))
	require.NotEmpty(t, resp.Header.Get("X-Provider-Trust-Level"))
	require.NotEmpty(t, resp.Header.Get("X-Provider-Chip"))
	attested := resp.Header.Get("X-Provider-Attested")
	require.Contains(t, []string{"true", "false"}, attested)

	var decoded struct {
		SESignature  string `json:"se_signature"`
		ResponseHash string `json:"response_hash"`
	}
	require.NoError(t, json.Unmarshal(respBody, &decoded))
	if attested == "true" {
		require.NotEmpty(t, decoded.SESignature, "attested response must include se_signature")
		require.NotEmpty(t, decoded.ResponseHash, "attested response must include response_hash")
	}

	t.Logf("provider metadata: id=%s chip=%s trust=%s attested=%s",
		resp.Header.Get("X-Provider-Id"),
		resp.Header.Get("X-Provider-Chip"),
		resp.Header.Get("X-Provider-Trust-Level"),
		attested,
	)
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

	s := testbed.StartSuite(t, testbed.SuiteConfig{
		ModelSpecs:     []testbed.ModelSpec{{ModelIDs: []string{modelA, modelB}, NumProviders: 1}},
		NumUsers:       1,
		SeedBalance:    500_000_000,
		UseMemoryStore: true,
	})
	require.Equal(t, 1, s.Coordinator.Registry.ProviderCount(), "smoke must route both models through one provider")

	models := []string{modelA, modelB, modelA}
	var providerID string
	for _, model := range models {
		resp := postChatCompletionsWithModel(t, s, model, "Reply with one short word.", false, 16)
		respBody, err := io.ReadAll(resp.Body)
		require.NoError(t, err, "model %s", model)
		resp.Body.Close()
		require.Equal(t, http.StatusOK, resp.StatusCode, "model %s body: %s", model, string(respBody[:min(len(respBody), 500)]))

		currentProviderID := resp.Header.Get("X-Provider-Id")
		require.NotEmpty(t, currentProviderID, "coordinator should report provider id for model %s", model)
		if providerID == "" {
			providerID = currentProviderID
		} else {
			require.Equal(t, providerID, currentProviderID, "all requests should route to the same multi-model provider")
		}
		provider := s.Coordinator.Registry.GetProvider(providerID)
		require.NotNil(t, provider, "provider %s disappeared after serving model %s", providerID, model)
		require.Eventually(t, func() bool {
			provider.Mu().Lock()
			defer provider.Mu().Unlock()
			if provider.BackendCapacity == nil {
				return false
			}
			for _, slot := range provider.BackendCapacity.Slots {
				if slot.Model == model && slot.State == "idle" {
					return true
				}
			}
			return false
		}, 2*time.Minute, 500*time.Millisecond,
			"provider %s did not report model %s idle before the next request", providerID, model)

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
