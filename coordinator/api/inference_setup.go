package api

import (
	_ "embed"
	"time"

	infer "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
)

// FirstContentDeadline returns this server's request-absolute first-content
// policy duration for a concrete model. Account enforcement is selected by
// requestFirstContentDeadline; this helper also supplies a hedge timing hint.
// The ordinary base is instance-owned so
// production-like E2E servers can use the production value without mutating
// concurrent unit tests. Exact-model overrides and per-token slopes are
// centralized in modelpolicy.
func (s *Server) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
	return s.inference.FirstContentDeadline(model, estimatedPromptTokens)
}

func (s *Server) SetPromptSupervisor(supervisor *promptcontract.Supervisor) {
	s.inference.SetPromptSupervisor(supervisor)
}

// ExactCacheStatusSnapshot exposes aggregate optimizer health only. It never
// includes models, providers, accounts, scopes, route keys, prompt material, or
// token-chain hashes.
func (s *Server) ExactCacheStatusSnapshot() infer.ExactCacheStatus {
	return s.inference.ExactCacheStatusSnapshot()
}

// SetPromptArtifactProvisioner attaches the optional Phase 1 optimizer
// lifecycle. Provisioning remains independent of inference availability.
func (s *Server) SetPromptArtifactProvisioner(provisioner *promptcontract.Provisioner) {
	s.inference.SetPromptArtifactProvisioner(provisioner)
}

func (s *Server) SetPromptContractClient(client *promptcontract.Client) {
	s.inference.SetPromptContractClient(client)
}

func (s *Server) SetPromptPreloadController(controller *promptcontract.PreloadController) {
	s.inference.SetPromptPreloadController(controller)
}

func (s *Server) PromptArtifactStatus(modelID string) (promptcontract.ProvisionStatus, bool) {
	return s.inference.PromptArtifactStatus(modelID)
}

// SetPromptContextCalibrationFromEnv parses an override of the form
// "family:factor,family:factor" (e.g. "gpt-oss:1.3,gemma:1.15") and REPLACES the
// calibration map when at least one valid pair is present. Invalid pairs and
// factors < 1.0 are skipped (a factor below 1 would under-reject, the wrong
// direction). A blank string is a no-op (keeps the built-in default). Returns the
// number of pairs applied. Called once at startup from main.go.
func SetPromptContextCalibrationFromEnv(raw string) int {
	return infer.SetPromptContextCalibrationFromEnv(raw)
}

// SetTokenLimiters configures the per-account input/output token-per-minute
// limiters for the consumer and service tiers. Pass nil for a tier to disable
// token limiting for it.
func (s *Server) SetTokenLimiters(consumer, service *ratelimit.TokenLimiter) {
	s.inference.SetTokenLimiters(consumer, service)
}

func (s *Server) SetOutputAdmissionEstimator(estimator *ratelimit.OutputAdmissionEstimator) {
	s.inference.SetOutputAdmissionEstimator(estimator)
}

// SetKeyLimiters configures the per-key (variable-rate) RPM and ITPM/OTPM
// limiters used for per-key overrides. Pass nil to disable per-key limiting.
func (s *Server) SetKeyLimiters(rpm *ratelimit.Limiter, tokens *ratelimit.KeyTokenLimiter) {
	s.inference.SetKeyLimiters(rpm, tokens)
}

// SetTTFTHardReject toggles the per-request TTFT admission ceiling between a
// hard 429 (true, legacy) and a soft routing preference (false, default). See
// the ttftHardReject field for rationale. Call before serving starts.
func (s *Server) SetTTFTHardReject(enabled bool) { s.inference.SetTTFTHardReject(enabled) }

// SetRejectModels sets the requested/resolved model IDs to 429 at public
// admission. Call before serving starts.
func (s *Server) SetRejectModels(models map[string]bool) { s.inference.SetRejectModels(models) }

// SetMinDecodeTPS sets the per-request sustained-decode floor (tokens/sec) the
// scheduler uses as a soft routing preference. <= 0 disables it. See the
// minDecodeTPS field. Call before serving starts.
func (s *Server) SetMinDecodeTPS(tps float64) { s.inference.SetMinDecodeTPS(tps) }

// DefaultRoutingConcurrency is the built-in routing-scan semaphore capacity:
// one scan per CPU (a scan is pure CPU under the registry read lock), floored
// at 2 so a tiny container never serializes routing entirely. Exported so
// main.go can log the effective default alongside the env override.
func DefaultRoutingConcurrency() int { return infer.DefaultRoutingConcurrency() }

// SetRoutingConcurrency replaces the routing-scan semaphore with one of the
// given capacity (EIGENINFERENCE_ROUTING_CONCURRENCY). Values < 2 clamp to 2.
// Call before serving starts — replacing the channel while scans are in
// flight would strand slots.
func (s *Server) SetRoutingConcurrency(n int) { s.inference.SetRoutingConcurrency(n) }

// SetServabilityGate toggles the smart early-429 admission gate. See the
// servabilityGate field. Call before serving starts.
func (s *Server) SetServabilityGate(enabled bool) { s.inference.SetServabilityGate(enabled) }

// SetDisableClientErrorStop is the kill switch for the C1 client-shape failover
// stop. true restores pre-fix behavior (deterministic provider 4xx fails over up
// to maxDispatchAttempts). Default (false) = stop enabled. Call before serving.
func (s *Server) SetDisableClientErrorStop(disabled bool) {
	s.inference.SetDisableClientErrorStop(disabled)
}

// SetLongPromptThreshold configures the estimated-prompt-token count at/above
// which the scheduler applies the long-prompt fastest-tier routing preference.
// 0 disables it (behavior-neutral). It is a package-level scheduler knob (like
// the prefill/decode ratio), so this delegates to the registry. Call before
// serving starts. SOFT bias only — no TTFT 429 is introduced.
func (s *Server) SetLongPromptThreshold(tokens int) { s.inference.SetLongPromptThreshold(tokens) }

// SetLongPromptPrefillWeight configures the prefill-term multiplier the scheduler
// applies to long prompts. Values < 1 clamp to 1.0 (no amplification).
// Delegates to the registry; call before serving starts.
func (s *Server) SetLongPromptPrefillWeight(weight float64) {
	s.inference.SetLongPromptPrefillWeight(weight)
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) { s.inference.SetCoordinatorKey(k) }
