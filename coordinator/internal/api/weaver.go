package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	weaverModeDeep     = "deep"
	weaverModeDeepPlus = "deep_plus"

	weaverVerifierMaxTokens = 256
)

type weaverConfig struct {
	Mode           string
	CandidateCount int
	VerifierCount  int
	Trace          bool
}

type weaverCandidate struct {
	ID      string `json:"id"`
	Index   int    `json:"index"`
	Label   string `json:"label"`
	Model   string `json:"model"`
	Status  string `json:"status"`
	Content string `json:"content"`
	Error   string `json:"error,omitempty"`
}

type weaverVerifierScore struct {
	CandidateID   string  `json:"candidate_id"`
	VerifierModel string  `json:"verifier_model"`
	Score         float64 `json:"score"`
	Rationale     string  `json:"rationale,omitempty"`
}

type weaverTrace struct {
	Mode              string                `json:"mode"`
	Status            string                `json:"status"`
	CandidateCount    int                   `json:"candidateCount"`
	VerifierCount     int                   `json:"verifierCount"`
	SelectedCandidate string                `json:"selectedCandidate,omitempty"`
	Confidence        float64               `json:"confidence,omitempty"`
	Candidates        []weaverCandidate     `json:"candidates"`
	VerifierScores    []weaverVerifierScore `json:"verifierScores"`
}

type weaverRunResult struct {
	Candidate weaverCandidate
	Usage     protocol.UsageInfo
	Err       error
}

type weaverProviderJob struct {
	Provider *registry.Provider
	Pending  *registry.PendingRequest
}

type weaverSSEWriter struct {
	mu      sync.Mutex
	w       http.ResponseWriter
	flusher http.Flusher
}

func (sw *weaverSSEWriter) write(event string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	sw.mu.Lock()
	defer sw.mu.Unlock()
	fmt.Fprintf(sw.w, "event: %s\n", event)
	fmt.Fprintf(sw.w, "data: %s\n\n", data)
	sw.flusher.Flush()
}

func parseWeaverConfig(parsed map[string]any) (weaverConfig, bool, error) {
	raw, ok := parsed["weaver"]
	if !ok || raw == nil {
		return weaverConfig{}, false, nil
	}
	obj, ok := raw.(map[string]any)
	if !ok {
		return weaverConfig{}, true, errors.New("weaver must be an object")
	}

	mode, _ := obj["mode"].(string)
	cfg := weaverConfig{Mode: mode, Trace: true}
	switch mode {
	case weaverModeDeep:
		cfg.CandidateCount = 4
		cfg.VerifierCount = 3
	case weaverModeDeepPlus:
		cfg.CandidateCount = 8
		cfg.VerifierCount = 5
	default:
		return weaverConfig{}, true, errors.New("weaver.mode must be deep or deep_plus")
	}

	if v, ok := numberFromAny(obj["candidate_count"]); ok {
		cfg.CandidateCount = v
	}
	if v, ok := numberFromAny(obj["verifier_count"]); ok {
		cfg.VerifierCount = v
	}
	if trace, ok := obj["trace"].(bool); ok {
		cfg.Trace = trace
	}
	if cfg.CandidateCount < 1 || cfg.CandidateCount > 16 {
		return weaverConfig{}, true, errors.New("weaver.candidate_count must be between 1 and 16")
	}
	if cfg.VerifierCount < 1 || cfg.VerifierCount > 10 {
		return weaverConfig{}, true, errors.New("weaver.verifier_count must be between 1 and 10")
	}
	return cfg, true, nil
}

func numberFromAny(v any) (int, bool) {
	switch n := v.(type) {
	case float64:
		return int(n), true
	case int:
		return n, true
	default:
		return 0, false
	}
}

func (s *Server) handleWeaverChatCompletions(w http.ResponseWriter, r *http.Request, cfg weaverConfig, rawBody []byte, model string, estimatedPromptTokens, requestedMaxTokens int, allowedProviderSerials []string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	writer := &weaverSSEWriter{w: w, flusher: flusher}

	candidates := make([]weaverCandidate, cfg.CandidateCount)
	for i := range candidates {
		candidates[i] = weaverCandidate{
			ID:     fmt.Sprintf("candidate-%d", i+1),
			Index:  i,
			Label:  fmt.Sprintf("Agent %d", i+1),
			Model:  model,
			Status: "queued",
		}
	}
	trace := weaverTrace{
		Mode:           cfg.Mode,
		Status:         "generating",
		CandidateCount: cfg.CandidateCount,
		VerifierCount:  cfg.VerifierCount,
		Candidates:     candidates,
		VerifierScores: []weaverVerifierScore{},
	}
	writer.write("weaver_init", trace)
	writer.write("weaver_status", map[string]any{"status": "generating"})

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	consumerKey := consumerKeyFromContext(r.Context())
	results := make(chan weaverRunResult, cfg.CandidateCount)
	var wg sync.WaitGroup
	for _, candidate := range candidates {
		wg.Add(1)
		go func(c weaverCandidate) {
			defer wg.Done()
			results <- s.runWeaverCandidate(ctx, writer, c, rawBody, model, consumerKey, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials)
		}(candidate)
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	completed := make([]weaverRunResult, 0, cfg.CandidateCount)
	var totalUsage protocol.UsageInfo
	for result := range results {
		if result.Err == nil && strings.TrimSpace(result.Candidate.Content) != "" {
			completed = append(completed, result)
			totalUsage.PromptTokens += result.Usage.PromptTokens
			totalUsage.CompletionTokens += result.Usage.CompletionTokens
		}
	}
	if len(completed) == 0 {
		writer.write("weaver_status", map[string]any{"status": "failed"})
		writer.write("error", map[string]any{"message": "all weaver candidates failed"})
		writer.write("done", map[string]any{"status": "failed"})
		return
	}

	writer.write("weaver_status", map[string]any{"status": "verifying"})
	verifierModels := s.selectWeaverVerifierModels(model, cfg.VerifierCount)
	scores := make([]weaverVerifierScore, 0, len(completed)*cfg.VerifierCount)
	for pass := 0; pass < cfg.VerifierCount; pass++ {
		verifierModel := verifierModels[pass%len(verifierModels)]
		for _, result := range completed {
			score, usage := s.runWeaverVerifier(ctx, result.Candidate, verifierModel, consumerKey, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials)
			scores = append(scores, score)
			totalUsage.PromptTokens += usage.PromptTokens
			totalUsage.CompletionTokens += usage.CompletionTokens
			writer.write("verifier_score", score)
		}
	}

	writer.write("weaver_status", map[string]any{"status": "selecting"})
	winner, confidence := selectWeaverWinner(completed, scores)
	writer.write("weaver_final", map[string]any{
		"selected_candidate": winner.Candidate.ID,
		"confidence":         confidence,
		"content":            winner.Candidate.Content,
		"usage": map[string]any{
			"tokenCount": totalUsage.CompletionTokens,
			"tps":        0,
			"ttft":       0,
		},
	})
	writer.write("weaver_status", map[string]any{"status": "complete"})
	writer.write("done", map[string]any{"status": "complete"})
}

func (s *Server) runWeaverCandidate(ctx context.Context, writer *weaverSSEWriter, candidate weaverCandidate, rawBody []byte, model, consumerKey string, estimatedPromptTokens, requestedMaxTokens int, allowedProviderSerials []string) weaverRunResult {
	candidate.Status = "streaming"
	writer.write("candidate_start", candidate)

	job, err := s.dispatchWeaverProviderJob(ctx, rawBody, model, consumerKey, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials)
	if err != nil {
		candidate.Status = "failed"
		candidate.Error = err.Error()
		writer.write("candidate_error", map[string]any{"candidate_id": candidate.ID, "error": candidate.Error})
		return weaverRunResult{Candidate: candidate, Err: err}
	}
	defer s.cleanupWeaverProviderJob(job)

	chunks, usage, err := s.collectWeaverChunks(ctx, job, func(delta string) {
		if delta != "" {
			writer.write("candidate_delta", map[string]any{"candidate_id": candidate.ID, "delta": delta})
		}
	})
	if err != nil {
		candidate.Status = "failed"
		candidate.Error = err.Error()
		writer.write("candidate_error", map[string]any{"candidate_id": candidate.ID, "error": candidate.Error})
		return weaverRunResult{Candidate: candidate, Err: err}
	}

	msg := extractMessage(chunks)
	candidate.Status = "done"
	candidate.Content = msg.Content
	writer.write("candidate_done", map[string]any{"candidate_id": candidate.ID, "content": candidate.Content})
	return weaverRunResult{Candidate: candidate, Usage: usage}
}

func (s *Server) dispatchWeaverProviderJob(ctx context.Context, rawBody []byte, model, consumerKey string, estimatedPromptTokens, requestedMaxTokens int, allowedProviderSerials []string) (*weaverProviderJob, error) {
	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		AllowedProviderSerials: allowedProviderSerials,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := s.registry.ReserveProviderEx(model, pr)
	if provider == nil {
		outcome := "no provider available"
		if decision.CapacityRejections > 0 && decision.CandidateCount == 0 {
			outcome = "provider capacity unavailable"
		}
		return nil, errors.New(outcome)
	}
	reservedMicroUSD, err := s.reserveWeaverProviderJob(pr, model, estimatedPromptTokens, requestedMaxTokens)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		return nil, err
	}
	pr.ReservedMicroUSD = reservedMicroUSD
	if provider.PublicKey == "" {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("no provider with E2E encryption")
	}
	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("provider public key invalid")
	}
	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("failed to generate session keys")
	}
	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("failed to encrypt request")
	}
	wireMsg := map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	data, err := json.Marshal(wireMsg)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("failed to marshal request")
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey
	if err := provider.Conn.Write(ctx, websocket.MessageText, data); err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundWeaverProviderJob(pr)
		return nil, errors.New("failed to send request to provider")
	}
	return &weaverProviderJob{Provider: provider, Pending: pr}, nil
}

func (s *Server) reserveWeaverProviderJob(pr *registry.PendingRequest, model string, promptTokens, maxTokens int) (int64, error) {
	if s.billing == nil {
		return 0, nil
	}
	reservedMicroUSD := s.reservationCost(model, promptTokens, maxTokens)
	if err := s.ledger.Charge(pr.ConsumerKey, reservedMicroUSD, "reserve:"+pr.RequestID); err != nil {
		return 0, errors.New("consumer balance is too low for weaver request")
	}
	return reservedMicroUSD, nil
}

func (s *Server) refundWeaverProviderJob(pr *registry.PendingRequest) {
	if pr == nil || pr.ReservedMicroUSD <= 0 {
		return
	}
	_ = s.store.Credit(pr.ConsumerKey, pr.ReservedMicroUSD, store.LedgerRefund, pr.RequestID)
	pr.ReservedMicroUSD = 0
}

func (s *Server) cleanupWeaverProviderJob(job *weaverProviderJob) {
	if job == nil || job.Provider == nil || job.Pending == nil {
		return
	}
	removed := job.Provider.RemovePending(job.Pending.RequestID)
	if removed == nil {
		return
	}
	s.refundWeaverProviderJob(removed)
	s.registry.SetProviderIdle(job.Provider.ID)
	s.sendProviderCancel(job.Provider, job.Pending.RequestID)
}

func (s *Server) collectWeaverChunks(ctx context.Context, job *weaverProviderJob, onDelta func(string)) ([]string, protocol.UsageInfo, error) {
	chunks := make([]string, 0, 16)
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()
	for {
		select {
		case chunk, ok := <-job.Pending.ChunkCh:
			if !ok {
				var usage protocol.UsageInfo
				select {
				case u, ok := <-job.Pending.CompleteCh:
					if ok {
						usage = u
					}
				default:
				}
				return chunks, usage, nil
			}
			normalized := normalizeSSEChunk(chunk)
			chunks = append(chunks, normalized)
			onDelta(extractMessage([]string{normalized}).Content)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)
		case errMsg := <-job.Pending.ErrorCh:
			if errMsg.Error == "" {
				errMsg.Error = "provider error"
			}
			s.refundWeaverProviderJob(job.Pending)
			return nil, protocol.UsageInfo{}, errors.New(errMsg.Error)
		case <-timer.C:
			return nil, protocol.UsageInfo{}, errors.New("request timed out")
		case <-ctx.Done():
			return nil, protocol.UsageInfo{}, ctx.Err()
		}
	}
}

func (s *Server) selectWeaverVerifierModels(baseModel string, count int) []string {
	if count <= 0 {
		return []string{baseModel}
	}

	online := make(map[string]struct{})
	for _, m := range s.registry.ListModels() {
		online[m.ID] = struct{}{}
	}
	hasOnline := len(online) > 0
	isOnline := func(id string) bool {
		if !hasOnline {
			return true
		}
		_, ok := online[id]
		return ok
	}

	catalogModels := s.store.ListSupportedModels()
	if len(catalogModels) == 0 {
		return selectOnlineVerifierModels(s.registry.ListModels(), baseModel, count)
	}

	var baseFamily string
	eligible := make([]store.SupportedModel, 0, len(catalogModels))
	for _, m := range catalogModels {
		if m.ID == baseModel {
			baseFamily = strings.TrimSpace(m.Family)
		}
		if !m.Active || IsRetiredProviderModel(m) || !isTextCatalogModel(m.ModelType) || !m.CanVerify {
			continue
		}
		if m.ID == baseModel || !isOnline(m.ID) {
			continue
		}
		eligible = append(eligible, m)
	}

	if len(eligible) == 0 {
		s.logger.Warn("weaver: no eligible verifier models, falling back to self-verification",
			"base_model", baseModel,
			"catalog_size", len(catalogModels))
		return []string{baseModel}
	}

	sort.SliceStable(eligible, func(i, j int) bool {
		di := isDifferentVerifierFamily(eligible[i].Family, baseFamily)
		dj := isDifferentVerifierFamily(eligible[j].Family, baseFamily)
		if di != dj {
			return di
		}
		si := verifierSizeSortKey(eligible[i].SizeGB)
		sj := verifierSizeSortKey(eligible[j].SizeGB)
		if si != sj {
			return si < sj
		}
		return eligible[i].ID < eligible[j].ID
	})

	limit := count
	if limit > len(eligible) {
		limit = len(eligible)
	}
	ids := make([]string, 0, limit)
	for _, m := range eligible[:limit] {
		ids = append(ids, m.ID)
	}
	return ids
}

func selectOnlineVerifierModels(models []registry.AggregateModel, baseModel string, count int) []string {
	ids := make([]string, 0, len(models))
	for _, m := range models {
		if m.ID == baseModel || !isTextCatalogModel(m.ModelType) {
			continue
		}
		ids = append(ids, m.ID)
	}
	if len(ids) == 0 {
		return []string{baseModel}
	}
	sort.Strings(ids)
	if count < len(ids) {
		return ids[:count]
	}
	return ids
}

func isTextCatalogModel(modelType string) bool {
	modelType = strings.ToLower(strings.TrimSpace(modelType))
	return modelType == "" ||
		modelType == "text" ||
		modelType == "chat" ||
		strings.Contains(modelType, "text") ||
		strings.Contains(modelType, "chat") ||
		strings.Contains(modelType, "completion") ||
		strings.Contains(modelType, "test")
}

func isDifferentVerifierFamily(family, baseFamily string) bool {
	family = strings.TrimSpace(family)
	baseFamily = strings.TrimSpace(baseFamily)
	return family != "" && baseFamily != "" && family != baseFamily
}

func verifierSizeSortKey(sizeGB float64) float64 {
	if sizeGB <= 0 {
		return math.MaxFloat64
	}
	return sizeGB
}

func (s *Server) runWeaverVerifier(ctx context.Context, candidate weaverCandidate, verifierModel, consumerKey string, estimatedPromptTokens, requestedMaxTokens int, allowedProviderSerials []string) (weaverVerifierScore, protocol.UsageInfo) {
	body := map[string]any{
		"model":      verifierModel,
		"stream":     true,
		"max_tokens": weaverVerifierMaxTokens,
		"messages": []map[string]string{
			{
				"role":    "system",
				"content": "Score the candidate answer from 0 to 10 for correctness, completeness, and clarity. Return only strict JSON: {\"score\": number, \"rationale\": string}. Do not include hidden reasoning.",
			},
			{
				"role":    "user",
				"content": fmt.Sprintf("Candidate %s answer:\n\n%s", candidate.Label, candidate.Content),
			},
		},
	}
	raw, _ := json.Marshal(body)
	verifierPromptTokens := estimatePromptTokens(body)
	score := weaverVerifierScore{
		CandidateID:   candidate.ID,
		VerifierModel: verifierModel,
		Score:         0,
		Rationale:     "abstained",
	}
	job, err := s.dispatchWeaverProviderJob(ctx, raw, verifierModel, consumerKey, verifierPromptTokens, weaverVerifierMaxTokens, allowedProviderSerials)
	if err != nil {
		score.Rationale = "abstained: " + err.Error()
		return score, protocol.UsageInfo{}
	}
	defer s.cleanupWeaverProviderJob(job)

	chunks, usage, err := s.collectWeaverChunks(ctx, job, func(string) {})
	if err != nil {
		score.Rationale = "abstained: " + err.Error()
		return score, usage
	}
	msg := extractMessage(chunks)
	var parsed struct {
		Score     float64 `json:"score"`
		Rationale string  `json:"rationale"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(msg.Content)), &parsed); err != nil {
		score.Rationale = "abstained: malformed verifier output"
		return score, usage
	}
	if math.IsNaN(parsed.Score) || math.IsInf(parsed.Score, 0) {
		score.Rationale = "abstained: invalid verifier score"
		return score, usage
	}
	if parsed.Score < 0 {
		parsed.Score = 0
	}
	if parsed.Score > 10 {
		parsed.Score = 10
	}
	score.Score = parsed.Score
	score.Rationale = parsed.Rationale
	return score, usage
}

func selectWeaverWinner(results []weaverRunResult, scores []weaverVerifierScore) (weaverRunResult, float64) {
	byID := make(map[string]weaverRunResult, len(results))
	for _, result := range results {
		byID[result.Candidate.ID] = result
	}
	type avgScore struct {
		id    string
		avg   float64
		count int
		index int
	}
	avgs := make([]avgScore, 0, len(results))
	for _, result := range results {
		var sum float64
		var count int
		for _, score := range scores {
			if score.CandidateID == result.Candidate.ID && score.Score > 0 {
				sum += score.Score
				count++
			}
		}
		avg := 0.0
		if count > 0 {
			avg = sum / float64(count)
		}
		avgs = append(avgs, avgScore{id: result.Candidate.ID, avg: avg, count: count, index: result.Candidate.Index})
	}
	sort.SliceStable(avgs, func(i, j int) bool {
		if avgs[i].avg == avgs[j].avg {
			return avgs[i].index < avgs[j].index
		}
		return avgs[i].avg > avgs[j].avg
	})
	if len(avgs) == 0 {
		return results[0], 0
	}
	best := avgs[0]
	confidence := best.avg / 10
	if len(avgs) > 1 && best.avg > 0 {
		gap := best.avg - avgs[1].avg
		confidence = math.Max(0.5, math.Min(0.99, 0.5+gap/10))
	}
	if best.count == 0 {
		confidence = 0
	}
	return byID[best.id], confidence
}
