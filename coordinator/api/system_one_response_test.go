package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSystemOneResponseValidationBindsRequest(t *testing.T) {
	var parsed map[string]any
	if err := json.Unmarshal([]byte(systemOneTestBody), &parsed); err != nil {
		t.Fatal(err)
	}
	contract := systemOneQuestionContract(parsed)
	if _, ok := validateSystemOneResponse([]byte(systemOneTestResponse), contract); !ok {
		t.Fatal("valid native answer rejected")
	}
	for _, raw := range []string{
		strings.Replace(systemOneTestResponse, `"triage":`, `"injected":`, 1),
		strings.Replace(systemOneTestResponse, `"choice":"urgent"`, `"choice":"normal"`, 1),
		strings.Replace(systemOneTestResponse, `"normal":0.1`, `"unknown":0.1`, 1),
		strings.Replace(systemOneTestResponse, `"urgent":0.9`, `"urgent":0.8`, 1),
		strings.Replace(systemOneTestResponse, `"confidence":0.8`, `"confidence":1.8`, 1),
		strings.Replace(systemOneTestResponse, `"act_probability":0.95`, `"act_probability":-1`, 1),
		`{"answers":{"triage":{"type":"noul","noul":0.5,"confidence":0.5,"action":{"act_probability":0.5}}}}`,
	} {
		if _, ok := validateSystemOneResponse([]byte(raw), contract); ok {
			t.Fatalf("accepted malformed answer %s", raw)
		}
	}
	for _, raw := range []string{
		`{"answers":{"q":{"type":"noul","noul":1.01,"confidence":0.5,"action":{"act_probability":0.5}}}}`,
		`{"answers":{"q":{"type":"score","score":0.9,"legend":{"0":"low","1":"high"},"probabilities":{"0":0.5,"1":0.5},"confidence":0.5,"action":{"act_probability":0.5}}}}`,
		`{"answers":{"q":{"type":"score","score":0.5,"legend":{"0":"low","2":"high"},"probabilities":{"0":0.5,"1":0.5},"confidence":0.5,"action":{"act_probability":0.5}}}}`,
	} {
		if _, ok := parseSystemOneResponse([]byte(raw)); ok {
			t.Fatalf("accepted malformed typed answer %s", raw)
		}
	}
	clean, ok := validateSystemOneResponse([]byte(strings.Replace(systemOneTestResponse, `"model":`, `"se_signature":"forged","extra":"untrusted","model":`, 1)), contract)
	if !ok || clean["se_signature"] != nil || clean["extra"] != nil {
		t.Fatalf("provider metadata injection: %+v", clean)
	}
}

func TestSystemOneMalformedProviderDoesNotSettle(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "laya", SystemOne: true}})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "invalid-native", AuthToken: "test-key", Version: "0.9.7", DecodeTPS: 100, Models: []failoverModelSpec{{ID: "laya", ModelType: "laya", SystemOne: true}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		invalid := strings.Replace(systemOneTestResponse, `"triage":`, `"unrequested":`, 1)
		writeEncryptedTestChunk(t, ctx, fp.conn, req, fp.pubKey, invalid)
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 73, CompletionTokens: 0})
	}})
	req, err := newAuthRequest(t, ctx, ts.URL+systemOneEndpoint, systemOneTestBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == 200 {
		t.Fatalf("invalid answer accepted: %s", raw)
	}
	if records := st.UsageByConsumer(testConsumerID); len(records) != 0 {
		t.Fatalf("invalid answer settled: %+v", records)
	}
}

func TestSystemOneCompletionRejectsInvalidUsageBeforeSettlement(t *testing.T) {
	for _, usage := range []protocol.UsageInfo{{PromptTokens: 73, CompletionTokens: 1}, {PromptTokens: 0}, {PromptTokens: 513}} {
		srv, st := testServer(t)
		p := srv.registry.Register("native-provider", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Backend: "mlx-swift"})
		pr := &registry.PendingRequest{RequestID: "native-request", Model: "laya", ConsumerKey: testConsumerID, EstimatedPromptTokens: 512, Traits: registry.RequestTraits{SystemOne: true}, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
		pr.SystemOneResponseValidated.Store(true)
		p.AddPending(pr)
		srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: usage})
		select {
		case err := <-pr.ErrorCh:
			if err.StatusCode != 500 {
				t.Fatalf("native usage error status %d", err.StatusCode)
			}
		default:
			t.Fatal("invalid usage did not produce error")
		}
		if len(st.UsageByConsumer(testConsumerID)) != 0 {
			t.Fatal("invalid native usage settled")
		}
	}
}

func TestSystemOneParkedCompletionCannotChargeGeneratedTokens(t *testing.T) {
	srv, st := testServer(t)
	p := srv.registry.Register("native-provider", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Backend: "mlx-swift"})
	pr := &registry.PendingRequest{RequestID: "parked-native", ReservedMicroUSD: 100, Model: "laya", ProviderID: p.ID, ConsumerKey: testConsumerID, EstimatedPromptTokens: 512, Traits: registry.RequestTraits{SystemOne: true}}
	pr.SystemOneResponseValidated.Store(true)
	srv.holdForSettlement(pr)
	srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 73, CompletionTokens: 2}})
	deadline := time.Now().Add(2 * time.Second)
	for !pr.IsReservationFinalized() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(st.UsageByConsumer(testConsumerID)) != 0 || !pr.IsReservationFinalized() {
		t.Fatal("invalid parked native terminal settled or leaked its reservation")
	}
	if srv.claimSettlement(pr.RequestID) != nil {
		t.Fatal("parked record was not cleaned up")
	}
}

func TestSystemOneResponseAcceptsNativeRoundedProbabilities(t *testing.T) {
	for _, n := range []int{7, 10, 11} {
		probs := map[string]any{}
		options := map[string]struct{}{}
		for i := 0; i < n; i++ {
			key := fmt.Sprint(i)
			probs[key] = math.Round(10000/float64(n)) / 10000
			options[key] = struct{}{}
		}
		answer := map[string]any{"type": "choice", "choice": "0", "probabilities": probs, "confidence": 0.5, "action": map[string]any{"act_probability": 0.5}}
		body, _ := json.Marshal(map[string]any{"answers": map[string]any{"q": answer}})
		contract := map[string]registry.SystemOneQuestion{"q": {Type: "choice", Options: options}}
		if _, ok := validateSystemOneResponse(body, contract); !ok {
			t.Fatalf("valid %d-way rounded distribution rejected: %s", n, body)
		}
		probs["0"] = 0.8
		body, _ = json.Marshal(map[string]any{"answers": map[string]any{"q": answer}})
		if _, ok := validateSystemOneResponse(body, contract); ok {
			t.Fatalf("invalid %d-way probability mass accepted", n)
		}
	}
	legend := map[string]any{}
	expected := make([]any, 7)
	probs := map[string]any{}
	for i := 0; i < 7; i++ {
		value := map[string]any{"label": fmt.Sprint(i)}
		legend[fmt.Sprint(i)] = value
		expected[i] = value
		probs[fmt.Sprint(i)] = 0.1429
	}
	answer := map[string]any{"type": "score", "score": 3.0, "legend": legend, "probabilities": probs, "confidence": 0.5, "action": map[string]any{"act_probability": 0.5}}
	contract := map[string]registry.SystemOneQuestion{"q": {Type: "score", Levels: 7, Legend: expected}}
	body, _ := json.Marshal(map[string]any{"answers": map[string]any{"q": answer}})
	if _, ok := validateSystemOneResponse(body, contract); !ok {
		t.Fatalf("native rounded score/structured legend rejected: %s", body)
	}
	legend["0"] = map[string]any{"label": "changed"}
	body, _ = json.Marshal(map[string]any{"answers": map[string]any{"q": answer}})
	if _, ok := validateSystemOneResponse(body, contract); ok {
		t.Fatal("changed legend accepted")
	}
}

func TestSystemOneStructuredLegendPreservesLargeIntegers(t *testing.T) {
	request := []byte(`{"model":"laya","state":"x","questions":{"q":{"type":"score","instructions":"rate","criteria":[{"count":9007199254740993,"hundred":1e2},"high"]}}}`)
	parsed, err := decodeInferenceJSONObject(request)
	if err != nil {
		t.Fatal(err)
	}
	contract := systemOneQuestionContract(parsed)
	body := []byte(`{"answers":{"q":{"type":"score","score":0.5,"legend":{"0":{"count":9007199254740993,"hundred":100.0},"1":"high"},"probabilities":{"0":0.5,"1":0.5},"confidence":0.5,"action":{"act_probability":0.5}}}}`)
	result, ok := validateSystemOneResponse(body, contract)
	if !ok {
		t.Fatal("valid structured integer legend rejected")
	}
	encoded, err := json.Marshal(result)
	if err != nil || !strings.Contains(string(encoded), `"count":9007199254740993`) {
		t.Fatalf("integer lost precision: %s %v", encoded, err)
	}
	changed := strings.Replace(string(body), "9007199254740993", "9007199254740992", 1)
	if _, ok := validateSystemOneResponse([]byte(changed), contract); ok {
		t.Fatal("changed large integer accepted")
	}
}

func TestSystemOneResponseRejectsTrailingJSON(t *testing.T) {
	if _, ok := parseSystemOneResponse([]byte(systemOneTestResponse + ` {}`)); ok {
		t.Fatal("multiple JSON responses accepted")
	}
	for _, pair := range [][2]string{{"1e9999999999999999999999999999", "10e9999999999999999999999999998"}, {"100.00", "1e2"}, {"-0.0", "0"}} {
		if !systemOneJSONEqual(json.Number(pair[0]), json.Number(pair[1])) {
			t.Fatalf("equivalent numeric spellings rejected: %v", pair)
		}
	}
}
