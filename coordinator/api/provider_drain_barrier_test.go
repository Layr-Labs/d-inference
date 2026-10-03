package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type drainSettlementStore struct {
	store.Store
	block         atomic.Bool
	entered       chan struct{}
	release       chan struct{}
	usageStarted  chan store.UsageRecord
	usageRelease  chan struct{}
	usageRecorded chan struct{}
}

func (s *drainSettlementStore) GetModelPrice(account, model string) (store.ModelPrice, bool) {
	if s.block.Swap(false) {
		close(s.entered)
		<-s.release
	}
	return s.Store.GetModelPrice(account, model)
}

func (s *drainSettlementStore) RecordUsage(record store.UsageRecord) {
	s.usageStarted <- record
	<-s.usageRelease
	s.Store.RecordUsage(record)
	s.usageRecorded <- struct{}{}
}

func TestProviderDrainLatestOverlappingBarrierFollowsUsageSettlementAndKeepsControlTrafficAlive(t *testing.T) {
	for _, stream := range []bool{true, false} {
		t.Run(map[bool]string{true: "streaming", false: "nonstreaming"}[stream], func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			original := memory.NewMemory(store.Config{AdminKey: "test-key"})
			blocked := &drainSettlementStore{
				Store: original, entered: make(chan struct{}), release: make(chan struct{}),
				usageStarted: make(chan store.UsageRecord, 2), usageRelease: make(chan struct{}),
				usageRecorded: make(chan struct{}, 2),
			}
			// Bind the wrapper before construction so every owner shares it.
			logger := quietLogger()
			reg := registry.New(logger)
			s := NewServer(reg, blocked, ServerConfig{}, logger)
			t.Cleanup(s.Close)
			s.SetChallengeInterval(200 * time.Millisecond)
			ts := httptest.NewServer(s.Handler())
			defer ts.Close()
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(blocked.release) }) }
			defer release()
			var usageReleaseOnce sync.Once
			releaseUsage := func() { usageReleaseOnce.Do(func() { close(blocked.usageRelease) }) }
			defer releaseUsage()
			pub := testPublicKeyB64()
			const model = "lifecycle-barrier-model"
			conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, pub)
			defer conn.CloseNow()
			waitForChallenge(t, ctx, conn, pub)
			makeProviderRoutable(reg)
			ack := make(chan struct{})
			readerAlive := make(chan struct{})
			worker := make(chan error, 1)
			go func() {
				for {
					_, data, err := conn.Read(ctx)
					if err != nil {
						worker <- err
						return
					}
					var envelope struct {
						Type string `json:"type"`
					}
					_ = json.Unmarshal(data, &envelope)
					switch envelope.Type {
					case protocol.TypeAttestationChallenge:
						_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pub))
					case protocol.TypeInferenceRequest:
						var request protocol.InferenceRequestMessage
						_ = json.Unmarshal(data, &request)
						writeEncryptedTestChunk(t, ctx, conn, request, pub, `data: {"id":"one","choices":[{"delta":{"content":"complete"}}]}`+"\n\n")
						blocked.block.Store(true)
						sendComplete(ctx, conn, request.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
						// Duplicate terminals remain exactly-once accounting even
						// while their asynchronous workers are behind the barrier.
						sendComplete(ctx, conn, request.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
						for _, id := range []string{"switch", "preliminary", "final"} {
							barrier, _ := json.Marshal(protocol.ProviderDrainMessage{Type: protocol.TypeProviderDrain, RequestID: id})
							if err := conn.Write(ctx, websocket.MessageText, barrier); err != nil {
								worker <- err
								return
							}
						}
						// A reply proves the reader processed all three barriers
						// without blocking on the held billing worker.
						_ = conn.Write(ctx, websocket.MessageText, []byte(`{"type":"models_replace","request_id":"probe","drain_request_id":"final","validate_only":true,"models":[{"id":"lifecycle-barrier-model"}]}`))
					case protocol.TypeModelsReplaceAck:
						var result protocol.ModelsReplaceAckMessage
						if err := json.Unmarshal(data, &result); err != nil || result.Accepted || result.Error != "invalid_drain" {
							worker <- fmt.Errorf("premature validation result: %s (%v)", data, err)
							return
						}
						close(readerAlive)
					case protocol.TypeProviderDrainAck:
						var result protocol.ProviderDrainMessage
						if err := json.Unmarshal(data, &result); err != nil || result.RequestID != "final" {
							worker <- fmt.Errorf("latest overlapping drain was not acknowledged: %s (%v)", data, err)
							return
						}
						close(ack)
						worker <- nil
						return
					}
				}
			}()
			response := make(chan error, 1)
			go func() {
				body, _ := json.Marshal(map[string]any{"model": model, "stream": stream, "messages": []map[string]string{{"role": "user", "content": "hello"}}})
				req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(string(body)))
				req.Header.Set("Authorization", "Bearer test-key")
				req.Header.Set("Content-Type", "application/json")
				resp, err := http.DefaultClient.Do(req)
				if err == nil {
					_, err = io.ReadAll(resp.Body)
					resp.Body.Close()
					if err == nil && resp.StatusCode != http.StatusOK {
						err = fmt.Errorf("inference response: %s", resp.Status)
					}
				}
				response <- err
			}()
			select {
			case <-blocked.entered:
			case <-ctx.Done():
				t.Fatal("settlement never started")
			}
			select {
			case <-readerAlive:
			case err := <-worker:
				t.Fatalf("control reader stopped during billing: %v", err)
			case <-ctx.Done():
				t.Fatal("control reader blocked on billing")
			}
			select {
			case <-ack:
				t.Fatal("acknowledged before settlement")
			default:
			}
			for _, id := range reg.ProviderIDs() {
				if !reg.ProviderDraining(id) {
					t.Fatal("drain did not fence dispatch")
				}
			}
			release()
			select {
			case <-ack:
			case <-ctx.Done():
				t.Fatal("no drain acknowledgement")
			}
			if err := <-worker; err != nil {
				t.Fatal(err)
			}
			if err := <-response; err != nil {
				t.Fatal(err)
			}
			// The drain covers settlement and synchronous ledger accounting.
			// Public usage persistence is a separate asynchronous write; hold it
			// until after the ACK so this distinction cannot pass by scheduling luck.
			var usage store.UsageRecord
			select {
			case usage = <-blocked.usageStarted:
			case <-ctx.Done():
				t.Fatal("usage persistence never started")
			}
			if entries := s.ledger.Usage(usage.ConsumerKey); len(entries) != 1 || entries[0].JobID != usage.RequestID {
				t.Fatalf("settled ledger usage = %+v, want one entry for %s", entries, usage.RequestID)
			}
			if count, err := original.UsageCountSince(time.Time{}); err != nil || count != 0 {
				t.Fatalf("held asynchronous usage count=%d err=%v", count, err)
			}
			releaseUsage()
			select {
			case <-blocked.usageRecorded:
			case <-ctx.Done():
				t.Fatal("usage persistence did not finish")
			}
			if count, err := original.UsageCountSince(time.Time{}); err != nil || count != 1 {
				t.Fatalf("usage count=%d err=%v", count, err)
			}
		})
	}
}
