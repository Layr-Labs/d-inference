package registry

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// routing_diagnostics.go answers one operator question the coordinator could
// previously only answer to itself: "my machine says online, hardware-trusted,
// challenges passing, model warm, doctor all green — why is it serving
// nothing?"
//
// Whether a connected provider advertises is the conjunction of roughly a
// dozen independent gates spread across the liveness core
// (`providerLivenessGateLocked`), the private-text chokepoint
// (`providerSupportsPrivateTextLocked`), the public listing filter
// (`ListModels`), and the per-model catalog / template gates. Exactly ONE of
// them — the runtime hash — reaches the operator, as a banner. The rest fail
// silently, so a fenced machine looks identical to a healthy one from the
// outside, and "88 connected / 85 advertising" has no drill-down.
//
// The fix is not a parallel re-implementation of those gates (that would drift
// the first time someone edited one of them). Each gate here is the SINGLE
// implementation, returning the reason it refused; the boolean predicates the
// router actually calls are one-line delegates that ask whether the reason is
// empty. A diagnostic and a routing decision cannot disagree because they are
// the same code.

// ChallengeFreshnessMaxAge is how stale a provider's last PASSING attestation
// challenge may be before routing fences it. Challenges run every 5 minutes,
// so this tolerates two consecutive misses. Exported because the owner
// dashboard renders "N of M minutes" against it and must not hardcode a second
// copy of the number.
const ChallengeFreshnessMaxAge = 16 * time.Minute

// RoutingBlocker is a closed, operator-facing reason a provider or one of its
// models is excluded from routing. Values are stable wire strings: the console
// UI and `darkbloom doctor` map them to remediation text, so renaming one is a
// breaking change.
type RoutingBlocker string

const (
	// Liveness core.
	BlockerOffline           RoutingBlocker = "offline"
	BlockerUntrusted         RoutingBlocker = "untrusted"
	BlockerPrivateOnly       RoutingBlocker = "private_only"
	BlockerTrustBelowMinimum RoutingBlocker = "trust_below_minimum"
	BlockerRuntimeUnverified RoutingBlocker = "runtime_hash_mismatch"
	BlockerChallengeNever    RoutingBlocker = "attestation_challenge_never_passed"
	BlockerChallengeStale    RoutingBlocker = "attestation_challenge_stale"

	// Private-text chokepoint.
	BlockerNoEncryptionKey          RoutingBlocker = "no_encryption_key"
	BlockerUnsupportedBackend       RoutingBlocker = "unsupported_backend"
	BlockerUnencryptedChunks        RoutingBlocker = "unencrypted_response_chunks"
	BlockerRuntimeManifestUnchecked RoutingBlocker = "runtime_manifest_unchecked"
	BlockerSIPUnverified            RoutingBlocker = "sip_unverified"
	BlockerCodeAttestationMissing   RoutingBlocker = "code_attestation_missing"
	BlockerPrivacyCapsMissing       RoutingBlocker = "privacy_capabilities_missing"
	BlockerPrivacyCapsIncomplete    RoutingBlocker = "privacy_capabilities_incomplete"

	// Inventory.
	BlockerNoModelsRegistered RoutingBlocker = "no_models_registered"
	BlockerNoRoutableModels   RoutingBlocker = "no_routable_models"

	// Per-model.
	BlockerModelNotInCatalog         RoutingBlocker = "model_not_in_catalog"
	BlockerModelWeightHashMismatch   RoutingBlocker = "model_weight_hash_mismatch"
	BlockerModelTemplateRenderBroken RoutingBlocker = "model_template_render_broken"
)

// Description is a one-line, content-free explanation with the remediation an
// operator can act on. Never embeds request data — only fixed text.
func (b RoutingBlocker) Description() string {
	switch b {
	case BlockerOffline:
		return "the machine is not connected to the coordinator"
	case BlockerUntrusted:
		return "the machine was marked untrusted by attestation and is excluded from routing"
	case BlockerPrivateOnly:
		return "the machine is in private-only mode, so it serves only its owner's self-route traffic"
	case BlockerTrustBelowMinimum:
		return "the machine's trust level is below this network's minimum; complete MDM enrollment"
	case BlockerRuntimeUnverified:
		return "the machine's runtime hashes do not match any registered release; reinstall from the official installer"
	case BlockerChallengeNever:
		return "the machine has not yet passed an attestation challenge"
	case BlockerChallengeStale:
		return "the machine's last passing attestation challenge is older than the freshness window"
	case BlockerNoEncryptionKey:
		return "the machine has not published an end-to-end encryption public key"
	case BlockerUnsupportedBackend:
		return "the machine reports an inference backend that is no longer routable"
	case BlockerUnencryptedChunks:
		return "the machine does not encrypt streamed response chunks"
	case BlockerRuntimeManifestUnchecked:
		return "the coordinator has not verified this machine's runtime against a release manifest"
	case BlockerSIPUnverified:
		return "System Integrity Protection was not confirmed by the last attestation challenge"
	case BlockerCodeAttestationMissing:
		return "the machine has not completed code-identity attestation"
	case BlockerPrivacyCapsMissing:
		return "the machine did not report its privacy capabilities"
	case BlockerPrivacyCapsIncomplete:
		return "one or more required privacy capabilities are disabled on the machine"
	case BlockerNoModelsRegistered:
		return "the machine registered no models; check enabled_models and that the weights finished downloading"
	case BlockerNoRoutableModels:
		return "every model the machine registered was excluded — see the per-model reasons"
	case BlockerModelNotInCatalog:
		return "this model is not in the coordinator's published catalog"
	case BlockerModelWeightHashMismatch:
		return "this model's weight hash does not match the catalog entry; re-download the model"
	case BlockerModelTemplateRenderBroken:
		return "this model's chat template failed the provider's render self-check"
	default:
		return string(b)
	}
}

// ModelRoutingDiagnostics is the routing verdict for one model a provider
// registered.
type ModelRoutingDiagnostics struct {
	ID string `json:"id"`
	// PubliclyListed reports whether this model contributes to the public
	// /v1/models aggregation from this provider.
	PubliclyListed bool `json:"publicly_listed"`
	// OwnerRoutable reports whether the owner's self-route can reach it.
	OwnerRoutable bool             `json:"owner_routable"`
	Blockers      []RoutingBlocker `json:"blockers,omitempty"`
}

// ProviderRoutingDiagnostics is the coordinator's own answer to "is this
// machine serving, and if not, why not".
//
// Advertising and Routable are deliberately separate, because the coordinator
// really does treat them separately: the public catalog answers "who could
// serve this model" and omits the runtime-hash and challenge-freshness gates,
// while dispatch applies them per request. A machine can therefore be counted
// as advertising and still receive nothing — which is precisely the state that
// reads as healthy from every existing surface.
type ProviderRoutingDiagnostics struct {
	// Advertising is true when the machine currently contributes at least one
	// model to the public /v1/models aggregation. This is the "advertising"
	// half of the network page's connected/advertising counts.
	Advertising bool `json:"advertising"`
	// Routable is true when public traffic can actually be dispatched to the
	// machine: the full liveness gate plus at least one catalog-allowed model.
	// Routable implies Advertising; the reverse does not hold.
	Routable bool `json:"routable"`
	// OwnerRoutable is true when the owner's own self-route requests can reach
	// the machine for at least one model.
	OwnerRoutable bool `json:"owner_routable"`
	// Blockers are the machine-level reasons traffic is not reaching it, in
	// the order the router evaluates them. Empty when routable.
	Blockers []RoutingBlocker          `json:"blockers,omitempty"`
	Models   []ModelRoutingDiagnostics `json:"models,omitempty"`
	// ChallengeMaxAgeSeconds is the freshness window behind
	// BlockerChallengeStale, so a client can render "N of M minutes".
	ChallengeMaxAgeSeconds int `json:"challenge_max_age_seconds"`
}

// RoutingDiagnostics returns the coordinator's routing verdict for one live
// provider, or nil when the id is not connected. Safe to call from HTTP
// handlers; takes r.mu and p.mu internally.
func (r *Registry) RoutingDiagnostics(providerID string, now time.Time) *ProviderRoutingDiagnostics {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerID]
	if !ok {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.routingDiagnosticsLocked(p, now)
}

// routingDiagnosticsLocked builds the verdict. Caller holds r.mu and p.mu.
func (r *Registry) routingDiagnosticsLocked(p *Provider, now time.Time) *ProviderRoutingDiagnostics {
	diag := &ProviderRoutingDiagnostics{
		ChallengeMaxAgeSeconds: int(ChallengeFreshnessMaxAge.Seconds()),
	}

	// Three verdicts over the same machine, each with its own gate set:
	//   listing  — what ListModels counts into the public catalog
	//   dispatch — what public traffic must pass to actually land here
	//   owner    — the owner's self-route (relaxed trust, privacy intact)
	listingBlocker := r.publicListingBlockerLocked(p, now)
	dispatchBlocker := r.providerLivenessBlockerLocked(p, r.MinTrustLevel, false, now)
	ownerBlocker := r.providerLivenessBlockerLocked(p, TrustNone, true, now)
	// Dispatch first: it is the stricter gate and the actionable one. The
	// listing blocker only differs when the two disagree about which gate
	// failed first, and then it is worth reporting both.
	diag.Blockers = appendBlocker(diag.Blockers, dispatchBlocker)
	diag.Blockers = appendBlocker(diag.Blockers, listingBlocker)

	if len(p.Models) == 0 {
		diag.Blockers = append(diag.Blockers, BlockerNoModelsRegistered)
		return diag
	}

	diag.Models = make([]ModelRoutingDiagnostics, 0, len(p.Models))
	publicModels, ownerModels := 0, 0
	for _, m := range p.Models {
		if m.ID == "" {
			continue
		}
		md := ModelRoutingDiagnostics{ID: m.ID}
		md.Blockers = r.modelBlockersLocked(m)
		// Public listing applies the catalog gate but NOT the template-render
		// gate (ListModels intentionally leaves render-broken builds visible
		// in the aggregate); the owner list applies both.
		md.PubliclyListed = listingBlocker == "" && r.modelAllowedByCatalogLocked(m)
		md.OwnerRoutable = ownerBlocker == "" &&
			r.modelServableForOwnerLocked(m) &&
			!templateRenderBroken(m)
		if md.PubliclyListed {
			publicModels++
		}
		if md.OwnerRoutable {
			ownerModels++
		}
		diag.Models = append(diag.Models, md)
	}
	sort.Slice(diag.Models, func(i, j int) bool { return diag.Models[i].ID < diag.Models[j].ID })

	diag.Advertising = listingBlocker == "" && publicModels > 0
	diag.Routable = dispatchBlocker == "" && publicModels > 0
	diag.OwnerRoutable = ownerModels > 0
	if len(diag.Blockers) == 0 && publicModels == 0 {
		diag.Blockers = append(diag.Blockers, BlockerNoRoutableModels)
	}
	return diag
}

// appendBlocker adds a non-empty blocker unless it is already present.
func appendBlocker(blockers []RoutingBlocker, b RoutingBlocker) []RoutingBlocker {
	if b == "" {
		return blockers
	}
	for _, existing := range blockers {
		if existing == b {
			return blockers
		}
	}
	return append(blockers, b)
}

// modelBlockersLocked lists the per-model exclusions for a build the provider
// registered. Caller holds r.mu and p.mu.
func (r *Registry) modelBlockersLocked(m protocol.ModelInfo) []RoutingBlocker {
	var blockers []RoutingBlocker
	if r.modelCatalog != nil {
		entry, tracked := r.modelCatalog[m.ID]
		switch {
		case !tracked:
			blockers = append(blockers, BlockerModelNotInCatalog)
		case entry.WeightHash != "" && m.WeightHash != "" && m.WeightHash != entry.WeightHash:
			blockers = append(blockers, BlockerModelWeightHashMismatch)
		}
	}
	if templateRenderBroken(m) {
		blockers = append(blockers, BlockerModelTemplateRenderBroken)
	}
	return blockers
}

// templateRenderBroken reports an EXPLICIT render-check failure. A nil field
// (pre-0.6.5 providers, no opinion) is not a failure — matching dispatch.
func templateRenderBroken(m protocol.ModelInfo) bool {
	return m.TemplateRenderOK != nil && !*m.TemplateRenderOK
}

// publicListingBlockerLocked is the SINGLE implementation of the per-provider
// gate `ListModels` applies before counting a machine's models into the public
// aggregation. Returns "" when the machine may contribute.
//
// It deliberately omits the runtime-verified and challenge-freshness checks of
// the full liveness gate: the public catalog answers "who could serve this
// model", while dispatch re-applies the stricter gate per request. Caller
// holds r.mu and p.mu.
func (r *Registry) publicListingBlockerLocked(p *Provider, now time.Time) RoutingBlocker {
	if blocker := statusBlocker(p); blocker != "" {
		return blocker
	}
	// Private-only machines serve only their owner's self-route traffic, so
	// they must not appear in or inflate the public aggregation.
	if p.PrivateOnly {
		return BlockerPrivateOnly
	}
	if !r.trustMeetsMinimum(p.TrustLevel) {
		return BlockerTrustBelowMinimum
	}
	return r.providerPrivateTextBlockerLocked(p)
}

// providerLivenessBlockerLocked is the SINGLE implementation of the
// liveness/trust/privacy core shared by every provider-eligibility decision
// (see routing_eligibility.go for the callers and the ordering rationale). It
// returns the first gate that refused, or "" when the provider passes.
//
// minTrust is the trust floor to enforce; allowPrivate admits an otherwise
// private-only machine. Caller holds r.mu and p.mu.
func (r *Registry) providerLivenessBlockerLocked(
	p *Provider, minTrust TrustLevel, allowPrivate bool, now time.Time,
) RoutingBlocker {
	if blocker := statusBlocker(p); blocker != "" {
		return blocker
	}
	if p.PrivateOnly && !allowPrivate {
		return BlockerPrivateOnly
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return BlockerTrustBelowMinimum
	}
	if !p.RuntimeVerified {
		return BlockerRuntimeUnverified
	}
	if blocker := r.providerPrivateTextBlockerLocked(p); blocker != "" {
		return blocker
	}
	if p.LastChallengeVerified.IsZero() {
		return BlockerChallengeNever
	}
	if now.Sub(p.LastChallengeVerified) > ChallengeFreshnessMaxAge {
		return BlockerChallengeStale
	}
	return ""
}

// providerPrivateTextBlockerLocked is the SINGLE implementation of the
// private/text routing chokepoint. It is a method on *Registry (not a free
// function) so the APNs code-identity gate can consult the live rollout policy
// (codeAttestationEnforcedLocked) rather than a value stamped at registration
// — that is what lets the grace→enforce deadline flip without a reconnect.
// Caller holds r.mu and p.mu.
func (r *Registry) providerPrivateTextBlockerLocked(p *Provider) RoutingBlocker {
	if p.PublicKey == "" {
		return BlockerNoEncryptionKey
	}
	if !privateTextBackendSupported(p.Backend) {
		return BlockerUnsupportedBackend
	}
	if !p.EncryptedResponseChunks {
		return BlockerUnencryptedChunks
	}
	if !p.RuntimeManifestChecked {
		return BlockerRuntimeManifestUnchecked
	}
	// Require coordinator-verified SIP (from the attestation challenge) rather
	// than trusting the provider's self-reported SIPEnabled field.
	if !p.ChallengeVerifiedSIP {
		return BlockerSIPUnverified
	}
	// v0.6.0 APNs code-identity gate — the SINGLE chokepoint, no self-route
	// exemption (gate everyone). Enforced only once configured AND past the
	// grace deadline, so the fleet keeps routing through the rollout;
	// fail-closed after.
	if r.codeAttestationEnforcedLocked() && !p.CodeAttested {
		return BlockerCodeAttestationMissing
	}
	caps := p.PrivacyCapabilities
	if caps == nil {
		return BlockerPrivacyCapsMissing
	}
	// Only mlx-swift is routable (enforced by privateTextBackendSupported
	// above). Python-specific caps (PythonRuntimeLocked,
	// DangerousModulesBlocked) are retained in the protocol struct for wire
	// backward compat but are no longer required for routing.
	if !caps.TextBackendInprocess || !caps.TextProxyDisabled ||
		!caps.AntiDebugEnabled || !caps.CoreDumpsDisabled || !caps.EnvScrubbed {
		return BlockerPrivacyCapsIncomplete
	}
	return ""
}

func statusBlocker(p *Provider) RoutingBlocker {
	switch p.Status {
	case StatusOffline:
		return BlockerOffline
	case StatusUntrusted:
		return BlockerUntrusted
	default:
		return ""
	}
}
