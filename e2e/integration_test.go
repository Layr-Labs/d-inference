package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/payments"
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

	var chunks int
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "data: ") {
			chunks++
			ri.StreamChunk(chunks)
		}
	}
	require.Greater(t, chunks, 0, "expected at least one SSE chunk")
	t.Logf("streaming: received %d SSE chunks", chunks)

	run := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf).BuildProfile()
	t.Logf("\n%s", run.SummaryTable())

	assertAccounting(t, s)
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

	resp := postChatCompletions(t, s, "What is 2+2? Answer with just the number.", false, 20)
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

	expectedPayout := payments.ProviderPayout(totalCost)
	expectedFee := payments.PlatformFee(totalCost)

	require.GreaterOrEqual(t, expectedFee, int64(1), "platform fee should be at least 1 micro-USD (5%% of %d)", totalCost)
	require.Equal(t, totalCost, expectedPayout+expectedFee,
		"payout + fee should equal total cost")

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
	found := s.Coordinator.Registry.FindProvider(model)
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

	modelA := envOr("DARKBLOOM_FULL_NETWORK_MODEL_A", "mlx-community/Qwen3-0.6B-8bit")
	modelB := envOr("DARKBLOOM_FULL_NETWORK_MODEL_B", "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
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
