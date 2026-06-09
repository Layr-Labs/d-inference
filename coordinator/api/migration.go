package api

import (
	"context"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// migrationTick is how often the controller re-evaluates each active migration.
const migrationTick = 20 * time.Second

// prefetchResendTTL suppresses re-sending prefetch to a provider that was
// recently told to fetch the new build but hasn't finished (re-advertised) yet.
const prefetchResendTTL = 10 * time.Minute

// migrationAckGrace is how long after sending prefetch we wait for a provider
// to acknowledge (any prefetch_model_status) before concluding its binary
// doesn't support prefetch. Such providers can't be migrated and are excluded
// so they never stall the ramp/done from converging on capable providers.
const migrationAckGrace = 2 * time.Minute

// MigrationController drives zero-downtime build cutovers. Each tick it asks the
// registry which providers serve the old vs new build, tells a bounded batch of
// old-build providers to prefetch the new build, and ramps the alias's routing
// weight toward the new build as it becomes available (draining the old build).
// The actual ramp decision lives in the pure advanceMigration function so it is
// unit-testable without timers, the registry, or the store.
type MigrationController struct {
	s    *Server
	mu   sync.Mutex
	sent map[string]time.Time // "alias|provider|build" → last prefetch send
}

func newMigrationController(s *Server) *MigrationController {
	return &MigrationController{s: s, sent: make(map[string]time.Time)}
}

// migrationSnapshot is the fleet state advanceMigration reasons over.
type migrationSnapshot struct {
	// prefetchCandidates are providers advertising the old build that we may
	// tell to prefetch the new one (advertise-based — we prefetch onto any live
	// node). nil falls back to servingFrom for older tests.
	prefetchCandidates map[string]bool
	// servingFrom/servingTo are the providers that can actually ROUTE the old /
	// new build (the real routing gate), used for ramp coverage and done — so a
	// non-routable old provider (private-only, stale, untrusted) never pins the
	// ramp below 100%.
	servingFrom map[string]bool
	servingTo   map[string]bool
	inflight    map[string]bool // providers told to prefetch, not yet serving `to`
	healthOK    bool            // safe to ramp more traffic onto the new build
	currentTo   int             // new build's current routing weight (0..100)
}

// migrationAction is what to do this tick.
type migrationAction struct {
	prefetchTargets []string // providers to send prefetch_model(to)
	fromWeight      int      // new alias weight for the old build
	toWeight        int      // new alias weight for the new build
	done            bool     // every old-build provider now serves `to` at 100%
}

// advanceMigration is the pure ramp/drain/prefetch decision for one tick.
//
// Ramp is capacity-proportional: the new build's target weight tracks the
// fraction of relevant providers that can already serve it, clamped to
// MaxStepPercent per tick so traffic moves smoothly (a single freshly-ready
// provider yields a small canary share, not an instant cutover). Health gating
// freezes the weight (no ramp up or down) when the new build looks unhealthy.
func advanceMigration(m store.ModelMigration, snap migrationSnapshot) migrationAction {
	cur := snap.currentTo

	// Paused / terminal: hold the current split, prefetch nothing.
	if m.Status != store.MigrationActive {
		return migrationAction{fromWeight: clampPct(100 - cur), toWeight: clampPct(cur)}
	}

	// Prefetch the new build onto old-build providers that don't have it yet,
	// bounded by BatchSize so we never pull too much capacity offline at once.
	batch := m.BatchSize
	if batch <= 0 {
		batch = 1
	}
	candidates := snap.prefetchCandidates
	if candidates == nil {
		candidates = snap.servingFrom
	}
	var targets []string
	for id := range candidates {
		if snap.servingTo[id] || snap.inflight[id] {
			continue
		}
		targets = append(targets, id)
		if len(targets) >= batch {
			break
		}
	}

	// Capacity-proportional target weight for the new build.
	union := make(map[string]bool, len(snap.servingFrom)+len(snap.servingTo))
	for id := range snap.servingFrom {
		union[id] = true
	}
	for id := range snap.servingTo {
		union[id] = true
	}
	desired := cur
	if len(union) > 0 && snap.healthOK {
		coverage := float64(len(snap.servingTo)) / float64(len(union))
		target := int(math.Round(coverage * 100))
		step := m.MaxStepPercent
		if step <= 0 {
			step = 25
		}
		if target > cur+step {
			target = cur + step
		}
		// Ramp DOWN is intentional and self-healing: if `to`-coverage drops
		// (e.g. a provider transiently de-advertises the new build), the weight
		// eases back toward the old build instead of over-routing to shrunken
		// capacity. This is never a black-hole — ResolveModel still prefers a
		// build with a live provider — and it settles once Status=complete.
		if target < cur-step {
			target = cur - step
		}
		desired = target
	}
	desired = clampPct(desired)

	// Done when every old-build provider also serves the new build and traffic
	// has fully shifted. (servingTo>0 guards the trivial empty-fleet case.)
	allMigrated := len(snap.servingTo) > 0
	for id := range snap.servingFrom {
		if !snap.servingTo[id] {
			allMigrated = false
			break
		}
	}
	done := allMigrated && desired >= 100

	return migrationAction{
		prefetchTargets: targets,
		fromWeight:      clampPct(100 - desired),
		toWeight:        desired,
		done:            done,
	}
}

func clampPct(v int) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

// Start launches the control loop until ctx is cancelled.
func (mc *MigrationController) Start(ctx context.Context) {
	saferun.Go(mc.s.logger, "migration_controller", func() {
		ticker := time.NewTicker(migrationTick)
		defer ticker.Stop()
		mc.runOnce() // act immediately on startup
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				mc.runOnce()
			}
		}
	})
}

func (mc *MigrationController) runOnce() {
	migs, err := mc.s.store.ListModelMigrations()
	if err != nil {
		mc.s.logger.Error("migration controller: list migrations failed", "error", err)
		return
	}
	for i := range migs {
		m := migs[i]
		if m.Status != store.MigrationActive {
			continue
		}
		mc.runMigration(m)
	}
}

func (mc *MigrationController) runMigration(m store.ModelMigration) {
	// servingFrom (prefetch targets) is advertise-based — we prefetch onto any
	// live provider that still has the old build. servingTo (ramp coverage +
	// done) is ROUTABILITY-based — the weight only follows capacity that can
	// actually serve the new build, so we never ramp onto a build that merely
	// advertises but can't route (stale challenge, untrusted, runtime-unverified).
	// Targeting is advertise-based (prefetch onto any live node that has the old
	// build); coverage/done are routability-based (only nodes that can actually
	// serve public traffic count), so a private-only / stale / untrusted old
	// provider can't pin the ramp below 100%.
	prefetchCandidates := sliceToSet(mc.s.registry.ProvidersServingBuild(m.FromBuild))
	servingFrom := sliceToSet(mc.s.registry.RoutableProviderIDsForBuild(m.FromBuild))
	servingTo := sliceToSet(mc.s.registry.RoutableProviderIDsForBuild(m.ToBuild))
	mc.dropUnmigratable(m, servingFrom, prefetchCandidates, servingTo)
	snap := migrationSnapshot{
		prefetchCandidates: prefetchCandidates,
		servingFrom:        servingFrom,
		servingTo:          servingTo,
		inflight:           mc.inflightSet(m, servingTo),
		healthOK:           mc.toBuildHealthy(m, servingTo),
		currentTo:          mc.currentToWeight(m),
	}

	act := advanceMigration(m, snap)

	// Fleet-coverage gauges so an operator can watch a migration progress.
	aliasTag := []string{"alias:" + m.AliasID}
	mc.s.ddGauge("migration.providers_from", float64(len(servingFrom)), aliasTag)
	mc.s.ddGauge("migration.providers_to_routable", float64(len(servingTo)), aliasTag)

	for _, id := range act.prefetchTargets {
		if err := mc.s.registry.SendPrefetchModel(id, m.ToBuild, 10); err != nil {
			mc.s.logger.Warn("migration prefetch send failed", "alias", m.AliasID, "provider", id, "error", err)
			continue
		}
		mc.markSent(m, id)
		mc.s.ddIncr("migration.prefetch_sent", aliasTag)
		mc.s.logger.Info("migration prefetch sent", "alias", m.AliasID, "provider", id, "to", m.ToBuild)
	}

	// Serialize the state mutation with the admin pause/resume/rollback handlers
	// so a rollback can't be clobbered by this in-flight ramp tick. Inside the
	// lock we re-read the migration and bail unless it is still active (the
	// handlers persist their terminal state under the same lock). Prefetch sends
	// above stay OUTSIDE the lock (they do network I/O).
	mc.s.migrationMu.Lock()
	defer mc.s.migrationMu.Unlock()

	// Re-read under the lock and bail unless this is still the SAME active
	// migration the tick decided on. Checking only "some active migration exists"
	// is not enough: if the operator rolled back/completed THIS migration and
	// started a REPLACEMENT for the same alias (different from/to) inside the tick
	// window, applying the stale `m` below would clobber the replacement's alias
	// weights or mark it complete using the old pair. Compare identity, not just
	// status.
	if cur, ok, err := mc.s.store.GetModelMigration(m.AliasID); err != nil || !ok || cur.Status != store.MigrationActive {
		return
	}

	// The new build's current routing share — the headline migration gauge.
	mc.s.ddGauge("migration.to_weight", float64(act.toWeight), aliasTag)

	if act.toWeight != snap.currentTo {
		if err := mc.applyWeights(m, act.fromWeight, act.toWeight); err != nil {
			mc.s.logger.Error("migration apply weights failed", "alias", m.AliasID, "error", err)
			return
		}
		mc.s.logger.Info("migration ramp", "alias", m.AliasID,
			"from_weight", act.fromWeight, "to_weight", act.toWeight,
			"serving_from", len(servingFrom), "serving_to", len(servingTo))
	}

	if act.done {
		m.Status = store.MigrationComplete
		if err := mc.s.store.UpsertModelMigration(&m); err != nil {
			mc.s.logger.Error("migration complete persist failed", "alias", m.AliasID, "error", err)
			return
		}
		mc.s.ddIncr("migration.completed", aliasTag)
		mc.s.logger.Info("migration complete", "alias", m.AliasID, "to", m.ToBuild)
	}
}

// dropUnmigratable removes from servingFrom/prefetchCandidates any old-build
// provider that can never complete the migration, so it doesn't pin coverage/
// done below 100%: (a) one whose hardware can't fit the new build (e.g. a
// small-RAM node migrating to a larger build), or (b) one told to prefetch long
// enough ago to have acknowledged but never did (its binary doesn't speak
// prefetch). A provider that acked and is merely still downloading is kept.
func (mc *MigrationController) dropUnmigratable(m store.ModelMigration, servingFrom, prefetchCandidates, servingTo map[string]bool) {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	now := time.Now()
	for id := range servingFrom {
		if servingTo[id] {
			continue
		}
		// Permanent exclusion: this provider's hardware can't hold the new build.
		if !mc.s.registry.ProviderCanFitBuild(id, m.ToBuild) {
			delete(servingFrom, id)
			delete(prefetchCandidates, id)
			mc.s.logger.Warn("migration: excluding provider that can't fit the new build",
				"alias", m.AliasID, "provider", id, "to", m.ToBuild)
			continue
		}
		ts, sent := mc.sent[sentKey(m.AliasID, id, m.ToBuild)]
		if !sent || now.Sub(ts) < migrationAckGrace {
			continue // not yet sent, or still within the ack grace window
		}
		if mc.s.registry.ProviderAckedPrefetch(id) {
			continue // it speaks prefetch — just still downloading, keep waiting
		}
		// Sent a while ago, never acked, not serving → its binary doesn't speak
		// prefetch. Exclude from both coverage (so done can converge) and
		// targeting (stop hammering it).
		delete(servingFrom, id)
		delete(prefetchCandidates, id)
		mc.s.logger.Warn("migration: excluding provider that never acked prefetch",
			"alias", m.AliasID, "provider", id, "to", m.ToBuild)
	}
}

// currentToWeight reads the new build's current routing weight from the alias.
func (mc *MigrationController) currentToWeight(m store.ModelMigration) int {
	alias, ok, err := mc.s.store.GetModelAlias(m.AliasID)
	if err != nil || !ok {
		return 0
	}
	for _, b := range alias.Builds {
		if b.BuildID == m.ToBuild {
			return clampPct(b.Weight)
		}
	}
	return 0
}

// applyWeights writes the new from/to weights into the alias (adding the builds
// if missing) and re-syncs the registry so routing reflects the new split.
func (mc *MigrationController) applyWeights(m store.ModelMigration, fromWeight, toWeight int) error {
	alias, ok, err := mc.s.store.GetModelAlias(m.AliasID)
	if err != nil {
		return err
	}
	if !ok {
		alias = &store.ModelAlias{AliasID: m.AliasID, Active: true}
	}
	setBuildWeight(alias, m.FromBuild, fromWeight)
	setBuildWeight(alias, m.ToBuild, toWeight)
	if err := mc.s.store.UpsertModelAlias(alias); err != nil {
		return err
	}
	mc.s.SyncModelCatalog()
	return nil
}

func setBuildWeight(alias *store.ModelAlias, buildID string, weight int) {
	for i := range alias.Builds {
		if alias.Builds[i].BuildID == buildID {
			alias.Builds[i].Weight = weight
			alias.Builds[i].Active = true
			return
		}
	}
	alias.Builds = append(alias.Builds, store.ModelAliasBuild{BuildID: buildID, Weight: weight, Active: true})
}

// toBuildHealthy gates the ramp. It must NOT use a saturation-sensitive signal
// (e.g. ModelCapacitySnapshot.RoutableProviders, which drops to 0 once providers
// are busy): the ramp itself drives canary traffic onto the new build, which
// saturates it, which would then freeze the ramp — a self-inflicted deadlock.
// `servingTo` here is the routability-based coverage set (counts busy/cold
// providers), so "the new build has at least one provider that can route it" is
// the right, saturation-insensitive gate. A real error-rate / TTFT health gate
// (auto-pause on a genuinely bad build) is a tracked follow-up.
func (mc *MigrationController) toBuildHealthy(m store.ModelMigration, servingTo map[string]bool) bool {
	return len(servingTo) > 0
}

func (mc *MigrationController) inflightSet(m store.ModelMigration, servingTo map[string]bool) map[string]bool {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	now := time.Now()
	out := make(map[string]bool)
	for key, ts := range mc.sent {
		alias, provider, ok := splitSentKey(key, m.ToBuild)
		if !ok || alias != m.AliasID {
			continue
		}
		if now.Sub(ts) > prefetchResendTTL {
			delete(mc.sent, key)
			continue
		}
		if servingTo[provider] {
			// It finished and re-advertised; stop tracking.
			delete(mc.sent, key)
			continue
		}
		// Terminal failure since we sent it (transient disk/network/hash error):
		// clear the marker so the next tick re-sends (and the provider resumes
		// from its on-disk staging) instead of waiting out the full resend TTL.
		if failedAt, ok := mc.s.registry.PrefetchFailedAt(provider, m.ToBuild); ok && failedAt.After(ts) {
			delete(mc.sent, key)
			continue
		}
		out[provider] = true
	}
	return out
}

func (mc *MigrationController) markSent(m store.ModelMigration, providerID string) {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	mc.sent[sentKey(m.AliasID, providerID, m.ToBuild)] = time.Now()
}

func sentKey(alias, provider, build string) string {
	return alias + "\x00" + provider + "\x00" + build
}

func splitSentKey(key, build string) (alias, provider string, ok bool) {
	// key = alias \x00 provider \x00 build
	first := strings.IndexByte(key, '\x00')
	if first < 0 {
		return "", "", false
	}
	rest := key[first+1:]
	second := strings.IndexByte(rest, '\x00')
	if second < 0 {
		return "", "", false
	}
	provider = rest[:second]
	if rest[second+1:] != build {
		return "", "", false
	}
	return key[:first], provider, true
}

func sliceToSet(ids []string) map[string]bool {
	m := make(map[string]bool, len(ids))
	for _, id := range ids {
		m[id] = true
	}
	return m
}
