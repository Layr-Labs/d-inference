package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Optional extension of the existing D48 fixture, not a second sidecar server.
// The real mode never launches TestCachePlanningHelperProcess or calls /test/*.
type cachePlanningRealArtifact struct {
	manifest promptcontract.Manifest
	files    map[string][]byte
}

type cachePlanningRealSidecarOptions struct {
	binary, sha256 string
	artifacts      []cachePlanningRealArtifact
}

func cachePlanningVerifyRealBinary(t *testing.T, path, expected string) {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	digest, digestErr := hex.DecodeString(expected)
	if err != nil || !filepath.IsAbs(path) || filepath.Clean(path) != path || resolved != path ||
		filepath.Base(path) != "promptsidecar" || strings.Contains(path, string(filepath.Separator)+"deps"+string(filepath.Separator)) ||
		digestErr != nil || len(digest) != sha256.Size || expected != strings.ToLower(expected) {
		t.Fatal("bind a canonical source-qualified promptsidecar service and lowercase SHA256")
	}
	before, err := os.Lstat(path)
	if err != nil || !before.Mode().IsRegular() || before.Mode().Perm()&0o111 == 0 || before.Size() > 256<<20 {
		t.Fatal("real sidecar is not a bounded executable regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, readErr := io.Copy(hash, io.LimitReader(file, before.Size()+1))
	closeErr := file.Close()
	after, statErr := os.Lstat(path)
	if readErr != nil || closeErr != nil || statErr != nil || !os.SameFile(before, after) ||
		before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) || hex.EncodeToString(hash.Sum(nil)) != expected {
		t.Fatal("source-bound real sidecar bytes changed")
	}
}

func cachePlanningRealArtifactFor(t *testing.T, model string, invalidTokenizer bool) cachePlanningRealArtifact {
	t.Helper()
	tokenizer := []byte(`{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"user":1,"hello":2,"world":3,"assistant":4,":":5},"unk_token":"[UNK]"}}`)
	if invalidTokenizer {
		tokenizer = []byte(`{"not_a_tokenizer":true}`)
	}
	contents := map[string][]byte{
		"tokenizer.json":        tokenizer,
		"tokenizer_config.json": []byte(`{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}`),
		"config.json":           []byte(fmt.Sprintf(`{"model_type":"fixture","variant":%q}`, model)),
	}
	var names []string
	for name := range contents {
		names = append(names, name)
	}
	sort.Strings(names)
	manifest := promptcontract.Manifest{ModelID: model, ModelType: "fixture", R2Prefix: "models/" + model}
	aggregate := sha256.New()
	for _, name := range names {
		digest := sha256.Sum256(contents[name])
		role := "tokenizer"
		if name == "config.json" {
			role = "config"
		}
		manifest.Files = append(manifest.Files, promptcontract.Artifact{Path: name, Role: role,
			SizeBytes: int64(len(contents[name])), SHA256: hex.EncodeToString(digest[:])})
		_, _ = aggregate.Write(digest[:])
	}
	manifest.AggregateSHA256 = hex.EncodeToString(aggregate.Sum(nil))
	return cachePlanningRealArtifact{manifest: manifest, files: contents}
}

func cachePlanningRealContract(t *testing.T, artifact cachePlanningRealArtifact) string {
	t.Helper()
	files, err := promptcontract.PromptArtifacts(artifact.manifest.Files)
	if err != nil {
		t.Fatal(err)
	}
	id, err := promptcontract.ContractID(files, promptcontract.CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func cachePlanningRealMetrics(t *testing.T, ctx context.Context, fixture *cachePlanningUDSFixture) promptcontract.SidecarStatus {
	t.Helper()
	status, err := fixture.supervisor.Client().Metrics(ctx)
	if err != nil {
		t.Fatalf("actual Rust metrics unavailable: %v", err)
	}
	return status
}

// This is a real API -> Go controller -> Rust planner -> encrypted provider
// request gate. It does not exercise model inference, native KV hits or signing.
// The runner must bind this Go tree and the named service's compiler/source
// receipts; an environment role label or hash by itself is not provenance.
func TestCachePlanningRealSidecarHealthyMemberHTTP(t *testing.T) {
	binary := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR")
	if binary == "" {
		t.Skip("requires a source-bound actual candidate Rust service")
	}
	if os.Getenv("DARKBLOOM_TEST_PROMPT_GO_VERSION") != "candidate" {
		t.Fatal("real partial-planning gate requires the source-bound candidate Go composition")
	}
	expected := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR_SHA256")
	cachePlanningVerifyRealBinary(t, binary, expected)
	for _, condition := range []string{"failed_tokenizer", "pending_artifact"} {
		t.Run(condition, func(t *testing.T) {
			reg, _, server, transport := setupTTFTFailoverServer(t)
			t.Cleanup(server.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			a := cachePlanningRealArtifactFor(t, "partial-planning-a", false)
			b := cachePlanningRealArtifactFor(t, "partial-planning-b", condition == "failed_tokenizer")
			bContract := cachePlanningRealContract(t, b)
			frames := make(chan protocol.InferenceRequestMessage, 2)
			provider := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
				Name: "real-partial-provider", Version: "0.8.15", DecodeTPS: 1000,
				Models: []failoverModelSpec{{ID: a.manifest.ModelID}, {ID: b.manifest.ModelID}},
				Script: func(ctx context.Context, fp *failoverProvider, request protocol.InferenceRequestMessage, decrypted []byte) {
					select {
					case frames <- request:
					case <-ctx.Done():
						return
					}
					var body struct {
						Model string `json:"model"`
					}
					if json.Unmarshal(decrypted, &body) != nil || body.Model == "" {
						t.Error("provider received no decrypted model")
						return
					}
					fp.serveFull(ctx, request, body.Model, "REAL_PARTIAL_OK")
				},
			})
			setPrefixCacheProtocol(t, reg, provider, 1)
			pending := make(chan struct{})
			var pendingOnce sync.Once
			fixture := newCachePlanningUDSFixtureWithOptions(t, server, cachePlanningFixtureOptions{
				deferReadiness: true,
				realSidecar: &cachePlanningRealSidecarOptions{binary: binary, sha256: expected,
					artifacts: []cachePlanningRealArtifact{a, b}},
				artifactHandler: func(w http.ResponseWriter, request *http.Request, contents []byte) {
					if condition == "pending_artifact" && request.URL.Path == "/"+b.manifest.R2Prefix+"/tokenizer.json" {
						pendingOnce.Do(func() { close(pending) })
						<-request.Context().Done() // Provisioner.Close/parent cancellation always releases this fixture.
						return
					}
					_, _ = w.Write(contents)
				},
			}, provider.registryID)
			if condition == "pending_artifact" {
				select {
				case <-pending:
				case <-time.After(5 * time.Second):
					t.Fatal("B download never reached its real artifact gate")
				}
			}
			awaitCondition(t, 10*time.Second, func() bool {
				status, exists := fixture.provisioner.Status(b.manifest.ModelID)
				counts := fixture.provisioner.Counts()
				if !exists || !fixture.controller.ReadyFor(fixture.contract) || fixture.controller.ReadyFor(bContract) {
					return false
				}
				if condition == "failed_tokenizer" {
					return status.ArtifactReady && counts.Ready == 2 && counts.Pending == 0 && fixture.controller.Status().Failures > 0
				}
				return !status.ArtifactReady && status.LastError == "" && counts.Ready == 1 && counts.Pending == 1
			}, "healthy A acknowledged despite unrelated B state")
			fixture.waitReady(t) // Verifies A's actual artifact identity, not just global readiness.
			var capabilities []protocol.PrefixCacheV2Capability
			for _, artifact := range []cachePlanningRealArtifact{a, b} {
				capability := cacheEligibilityV2Capability(artifact.manifest.ModelID)
				capability.ModelAggregateHash = artifact.manifest.AggregateSHA256
				capability.PromptContractID = cachePlanningRealContract(t, artifact)
				capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
				capabilities = append(capabilities, capability)
			}
			// One capability snapshot must retain both model identities.
			if err := reg.UpdatePrefixCacheCapabilities(provider.registryID, 2, capabilities); err != nil {
				t.Fatal(err)
			}
			initial := cachePlanningRealMetrics(t, ctx, fixture)
			if !initial.Ready || initial.PlanningPermitsAvailable != 1 || initial.LoadingContracts != 0 ||
				(condition == "failed_tokenizer" && initial.Metrics.Preloads.Failed == 0) {
				t.Fatal("real Rust did not establish the required healthy-subset control")
			}
			seenNonces := make(map[string]bool)
			for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
				for _, stream := range []bool{false, true} {
					for _, model := range []string{a.manifest.ModelID, b.manifest.ModelID} {
						beforeRust := cachePlanningRealMetrics(t, ctx, fixture)
						before := server.metrics.Snapshot()
						beforeDispatches := provider.dispatchCount()
						correlation := fmt.Sprintf("partial-%s-%s-%s-%t", condition, model, strings.TrimPrefix(endpoint, "/v1/"), stream)
						content := strings.Repeat("hello ", 300) + correlation
						body := strings.ReplaceAll(cachePlanningEndpointBody(model, endpoint, stream), "planning lifecycle fixture", content)
						status, response, err := postGenericInference(ctx, transport.URL, endpoint, body)
						if err != nil || status != http.StatusOK || cachePlanningResponseText(endpoint, stream, response) != "REAL_PARTIAL_OK" {
							t.Fatalf("ordinary inference failed for %s/%s/%s/stream=%t: status=%d error=%v", condition, model, endpoint, stream, status, err)
						}
						if err := cachePlanningResponseTerminalError(endpoint, stream, response); err != nil {
							t.Fatal(err)
						}
						var frame protocol.InferenceRequestMessage
						select {
						case frame = <-frames:
						case <-time.After(time.Second):
							t.Fatal("provider frame missing")
						}
						select {
						case decrypted := <-provider.bodies:
							if !bytes.Contains(decrypted, []byte(correlation)) {
								t.Fatal("encrypted dispatch did not carry this synthetic request")
							}
							var parsed map[string]any
							if json.Unmarshal(decrypted, &parsed) != nil || parsed["model"] != model {
								t.Fatal("resolved provider model mismatch")
							}
						case <-time.After(time.Second):
							t.Fatal("decrypted provider body missing")
						}
						if frame.EncryptedBody == nil || frame.EncryptedBody.Ciphertext == "" || frame.EncryptedBody.EphemeralPublicKey == "" ||
							provider.dispatchCount() != beforeDispatches+1 {
							t.Fatal("expected exactly one encrypted ordinary dispatch")
						}
						afterRust := cachePlanningRealMetrics(t, ctx, fixture)
						reason, calls := "planned", uint64(1)
						if model == b.manifest.ModelID {
							calls, reason = 0, "preload_not_ready"
							if condition == "pending_artifact" {
								reason = "artifact_pending"
							}
							if frame.PrefixCacheProtocol != 0 || frame.CacheReceiptNonce != "" || frame.CacheScope != "" || frame.CacheReceiptBoundaryMode != "" {
								t.Fatal("unready B dispatched cache metadata instead of cold inference")
							}
						} else {
							if frame.PrefixCacheProtocol != 2 || frame.CacheScope == "" || frame.CacheReceiptNonce == "" || seenNonces[frame.CacheReceiptNonce] || frame.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
								t.Fatal("healthy A lacked a unique actual V2 plan/attempt")
							}
							seenNonces[frame.CacheReceiptNonce] = true
						}
						if afterRust.Metrics.Plans.Started != beforeRust.Metrics.Plans.Started+calls ||
							afterRust.Metrics.Plans.Succeeded != beforeRust.Metrics.Plans.Succeeded+calls ||
							afterRust.Metrics.Plans.Failed != beforeRust.Metrics.Plans.Failed || afterRust.LoadingContracts != 0 || afterRust.PlanningPermitsAvailable != 1 {
							t.Fatal("actual Rust planning execution population or permit drain differs")
						}
						after := server.metrics.Snapshot()
						modelKey := "cache_model_planning_decision_total{model=" + model + ",reason=" + reason + "}"
						decisionKey := "exact_cache_planning_decision_total{reason=" + reason + "}"
						if after.Counters[modelKey]-before.Counters[modelKey] != 1 || after.Counters[decisionKey]-before.Counters[decisionKey] != 1 {
							t.Fatal("per-model planning decision did not match real Rust/cold path")
						}
						var decisions, modelDecisions, legacy int64
						for name, value := range after.Counters {
							if strings.HasPrefix(name, "exact_cache_planning_decision_total{") {
								decisions += value - before.Counters[name]
							}
							if strings.HasPrefix(name, "cache_model_planning_decision_total{") {
								modelDecisions += value - before.Counters[name]
							}
							if strings.HasPrefix(name, "exact_cache_plan_total{") {
								legacy += value - before.Counters[name]
							}
						}
						if decisions != 1 || modelDecisions != 1 || legacy != int64(calls) {
							t.Fatal("request added or lost a planning decision/Registry invocation")
						}
						if !fixture.controller.ReadyFor(fixture.contract) || fixture.controller.ReadyFor(bContract) {
							t.Fatal("request changed healthy/unready membership")
						}
					}
				}
			}
			registered := reg.GetProvider(provider.registryID)
			if registered == nil {
				t.Fatal("provider vanished before ownership check")
			}
			awaitCondition(t, time.Second, func() bool {
				return registered.PendingCount() == 0 && reg.Queue().QueueSize(a.manifest.ModelID) == 0 && reg.Queue().QueueSize(b.manifest.ModelID) == 0
			}, "all real partial-planning HTTP work drained")
			if provider.dispatchCount() != 16 || len(frames) != 0 || len(provider.bodies) != 0 || fixture.supervisor.Status().Restarts != 0 {
				t.Fatal("partial-readiness fixture dispatched extra work or restarted its real child")
			}
		})
	}
}
