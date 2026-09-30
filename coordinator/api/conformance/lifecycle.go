package conformance

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func orNextEither(t *testing.T, f *orFixture, a, b *orProvider) (*orProvider, orDispatch) {
	t.Helper()
	select {
	case r := <-a.requests:
		return a, r
	case r := <-b.requests:
		return b, r
	case e := <-a.faults:
		t.Fatal(e)
	case e := <-b.faults:
		t.Fatal(e)
	case <-f.ctx.Done():
		t.Fatal("dispatch deadline")
	}
	return nil, orDispatch{}
}

func (s Suite) TestOpenRouterConformanceRetry(t *testing.T) {
	for _, exhaust := range []bool{false, true} {
		t.Run(fmt.Sprintf("exhaust_%t", exhaust), func(t *testing.T) {
			f := s.newORFixture(t, true)
			a, b := f.provider("0.8.15"), f.provider("0.8.15")
			ch, cancel := f.startChat(f.keys[orAccount], true, nil)
			defer cancel()
			loser, first := orNextEither(t, f, a, b)
			loser.chunk(first, strings.Replace(orFrame(`{"role":"assistant"}`, "null"), "fixture-response", "losing-preamble", 1))
			// Deliberate synthetic work duration makes millisecond wire-budget decline
			// observable; no tight performance assertion is made about this timer.
			select {
			case <-time.After(15 * time.Millisecond):
			case <-f.ctx.Done():
				t.Fatal("fixture expired")
			}
			loser.failure(first, 503, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable)
			winner, second := orNextEither(t, f, a, b)
			if winner == loser || first.request.RequestID == second.request.RequestID || second.request.FirstContentBudgetMS <= 0 || second.request.FirstContentBudgetMS >= first.request.FirstContentBudgetMS {
				t.Fatalf("retry identity/budgets: %d -> %d", first.request.FirstContentBudgetMS, second.request.FirstContentBudgetMS)
			}
			if exhaust {
				winner.failure(second, 503, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable)
			} else {
				winner.success(second, true, true)
			}
			result := f.response(ch)
			attempts := int(a.count.Load() + b.count.Load())
			if attempts != 2 {
				t.Fatalf("attempts=%d", attempts)
			}
			if exhaust {
				body := orReadBody(t, result.resp)
				retry, e := strconv.Atoi(result.resp.Header.Get("Retry-After"))
				if result.resp.StatusCode != 429 || e != nil || retry <= 0 || !json.Valid(body) || strings.Contains(string(body), "losing-preamble") || strings.Contains(result.resp.Header.Get("Content-Type"), "event-stream") {
					t.Fatalf("pre-content exhaustion status=%d retry=%d validJSON=%v", result.resp.StatusCode, retry, json.Valid(body))
				}
				f.settled(orAccount, 0, 0)
				f.report("A6", orObservation{Status: 429, RetryAfter: strconv.Itoa(retry), Terminal: "http_error", Model: orAlias}, attempts, 0, true)
			} else {
				o, err := orObserve(f.ctx, result.resp, result.start, result.headersNS)
				if err != nil || o.ID != "fixture-response" || o.Text != "héllo" {
					t.Fatalf("winning stream: %+v %v", o, err)
				}
				f.settled(orAccount, orCost, 1)
				f.report("A5", o, attempts, orCost, true)
			}
		})
	}
}

func (s Suite) TestOpenRouterConformancePostContentFailure(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		t.Run(fmt.Sprintf("disconnect_%t", disconnect), func(t *testing.T) {
			f := s.newORFixture(t, true)
			p := f.provider("0.8.15")
			ch, cancel := f.startChat(f.keys[orAccount], true, nil)
			defer cancel()
			r := p.next()
			p.chunk(r, orFrame(`{"content":"delivered prefix"}`, "null"))
			result := f.response(ch) // headers only exist after the semantic commit.
			if disconnect {
				p.close()
			} else {
				p.failure(r, 500, "", "")
			}
			o, err := orObserve(f.ctx, result.resp, result.start, result.headersNS)
			if err == nil || o.Status != 200 || o.Terminal != "in_band_error" || o.Text != "delivered prefix" || o.SemanticNS == nil {
				t.Fatalf("post-content outcome %+v err=%v", o, err)
			}
			if p.count.Load() != 1 {
				t.Fatal("replayed committed response")
			}
			f.settled(orAccount, 0, 0)
			f.report("A7", o, 1, 0, true)
		})
	}
}

func (s Suite) TestOpenRouterConformanceClientError(t *testing.T) {
	f := s.newORFixture(t, true)
	a, b := f.provider("0.8.15"), f.provider("0.8.15")
	ch, cancel := f.startChat(f.keys[orAccount], true, nil)
	defer cancel()
	p, r := orNextEither(t, f, a, b)
	p.failure(r, 400, protocol.FailureCodeInvalidRequest, "")
	result := f.response(ch)
	body := orReadBody(t, result.resp)
	if result.resp.StatusCode != 400 || !json.Valid(body) || a.count.Load()+b.count.Load() != 1 {
		t.Fatalf("client-error status=%d attempts=%d", result.resp.StatusCode, a.count.Load()+b.count.Load())
	}
	f.settled(orAccount, 0, 0)
}

func (s Suite) TestOpenRouterConformanceCancellation(t *testing.T) {
	for _, holds := range []bool{false, true} {
		for _, content := range []bool{false, true} {
			t.Run(fmt.Sprintf("holds_%t/content_%t", holds, content), func(t *testing.T) {
				f := s.newORFixture(t, holds)
				p := f.provider("0.8.15")
				ch, cancel := f.startChat(f.keys[orAccount], true, nil)
				defer cancel()
				r := p.next()
				// Receiving bytes can precede the writer's completion transition.
				// This case asserts cancellation of a fully dispatched attempt;
				// an in-flight write may instead correctly abort its connection.
				orEventually(t, func() bool {
					provider := f.srv.Registry.GetProvider(p.id)
					if provider == nil {
						return false
					}
					pending := provider.GetPending(r.request.RequestID)
					return pending != nil && pending.Profile.Get(registry.StampWriteDone) > 0
				}, "provider request write completed before caller cancellation")
				if content {
					p.chunk(r, orFrame(`{"content":"delivered prefix"}`, "null"))
					result := f.response(ch)
					reader := bufio.NewReader(result.resp.Body)
					line, err := reader.ReadString('\n')
					if err != nil || !strings.Contains(line, "delivered prefix") {
						t.Fatalf("prefix not delivered %q %v", line, err)
					}
					cancel()
					result.resp.Body.Close()
				} else {
					cancel()
					select {
					case result := <-ch:
						if result.err == nil {
							result.resp.Body.Close()
							t.Fatal("cancel before content returned response")
						}
					case <-f.ctx.Done():
						t.Fatal("cancelled HTTP caller did not return")
					}
				}
				select {
				case id := <-p.cancels:
					if id != r.request.RequestID {
						t.Fatal("cancel targeted wrong attempt")
					}
				case <-f.ctx.Done():
					t.Fatal("matching provider cancel not delivered")
				}
				p.failure(r, 499, protocol.FailureCodeCancelled, errorReasonCancelled)
				orEventually(t, func() bool { return f.srv.Inflight() == 0 }, "cancelled handler exit")
				p.barrier()
				f.settled(orAccount, 0, 0)
				// Cancellation/error cleanup wins first. Replayed complete and error frames
				// must not mint a usage row or a second credit after the refund/hold release.
				p.complete(r)
				p.failure(r, 499, protocol.FailureCodeCancelled, errorReasonCancelled)
				p.barrier()
				f.settled(orAccount, 0, 0)
				if p.count.Load() != 1 {
					t.Fatal("retry after caller cancellation")
				}
				f.report("A8_cancel_first", orObservation{Terminal: "caller_cancel", Model: orAlias}, 1, 0, holds)
			})
		}
	}
}

func (s Suite) TestOpenRouterConformanceCompletionFirst(t *testing.T) {
	for _, holds := range []bool{false, true} {
		t.Run(fmt.Sprintf("holds_%t", holds), func(t *testing.T) {
			f := s.newORFixture(t, holds)
			p := f.provider("0.8.15")
			ch, cancel := f.startChat(f.keys[orAccount], true, nil)
			r := p.next()
			p.success(r, true, true)
			result := f.response(ch)
			o, err := orObserve(f.ctx, result.resp, result.start, result.headersNS)
			if err != nil {
				t.Fatal(err)
			}
			f.settled(orAccount, orCost, 1)
			cancel()
			p.complete(r)
			p.failure(r, 499, protocol.FailureCodeCancelled, errorReasonCancelled)
			p.barrier()
			f.settled(orAccount, orCost, 1)
			orNoCancel(t, p)
			if p.count.Load() != 1 {
				t.Fatal("replay after clean completion")
			}
			f.report("A8_A12_completion_first", o, 1, orCost, holds)
		})
	}
}

func (s Suite) TestOpenRouterConformanceTools(t *testing.T) {
	for _, supported := range []bool{false, true} {
		t.Run(fmt.Sprintf("supported_%t", supported), func(t *testing.T) {
			f := s.newORFixture(t, true)
			p := f.provider("0.9.5")
			// Current providers are fenced by the real per-model template
			// verdict, not the retired pre-0.9.5 version heuristics.
			p.write(protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate, Models: []protocol.ModelInfo{{ID: f.model, WeightHash: testHash, ModelType: "chat", Quantization: "4bit", TemplateRenderOK: &supported}}})
			orEventually(t, func() bool {
				rp := f.srv.Registry.GetProvider(p.id)
				rp.Mu().Lock()
				defer rp.Mu().Unlock()
				for _, m := range rp.Models {
					if m.ID == f.model && m.TemplateRenderOK != nil {
						return *m.TemplateRenderOK == supported
					}
				}
				return false
			}, "template capability advertisement")
			extra := map[string]any{"tools": []any{map[string]any{"type": "function", "function": map[string]any{"name": "fixture_tool", "parameters": map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"type": "string"}}}}}}}
			ch, cancel := f.startChat(f.keys[orAccount], false, extra)
			defer cancel()
			if supported {
				r := p.next()
				raw, err := json.Marshal(r.body["tools"])
				if err != nil || !strings.Contains(string(raw), `"name":"fixture_tool"`) || !strings.Contains(string(raw), `"value"`) {
					t.Fatalf("tools not forwarded %s %v", raw, err)
				}
				p.success(r, false, false)
			}
			result := f.response(ch)
			body := orReadBody(t, result.resp)
			if supported {
				if result.resp.StatusCode != 200 || p.count.Load() != 1 {
					t.Fatal("supported tool forwarding failed")
				}
				f.settled(orAccount, orCost, 1)
			} else {
				if result.resp.StatusCode != http.StatusServiceUnavailable || p.count.Load() != 0 || !strings.Contains(string(body), "tool calls") {
					t.Fatalf("unsupported tool fence status=%d attempts=%d", result.resp.StatusCode, p.count.Load())
				}
				f.settled(orAccount, 0, 0)
			}
		})
	}
}
