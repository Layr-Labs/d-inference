package e2e

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/payments"
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
