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
	servingFrom map[string]bool // providers currently serving the old build
	servingTo   map[string]bool // providers currently serving the new build
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
	var targets []string
	for id := range snap.servingFrom {
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
	servingFrom := sliceToSet(mc.s.registry.ProvidersServingBuild(m.FromBuild))
	servingTo := sliceToSet(mc.s.registry.RoutableProviderIDsForBuild(m.ToBuild))
	snap := migrationSnapshot{
		servingFrom: servingFrom,
		servingTo:   servingTo,
		inflight:    mc.inflightSet(m, servingTo),
		healthOK:    mc.toBuildHealthy(m, servingTo),
		currentTo:   mc.currentToWeight(m),
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

	// Re-read the migration immediately before any state mutation so an admin
	// pause/resume/rollback that landed during this tick is not clobbered by a
	// stale in-flight decision (the handler persists the terminal state first).
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

// toBuildHealthy gates the ramp: don't shift more traffic onto the new build if
// providers already serve it but none can currently accept requests (e.g. all
// at capacity or rejecting). When no provider serves it yet, ramp is held near
// zero by coverage anyway, so we report healthy and let prefetch proceed.
func (mc *MigrationController) toBuildHealthy(m store.ModelMigration, servingTo map[string]bool) bool {
	if len(servingTo) == 0 {
		return true
	}
	for _, cap := range mc.s.registry.ModelCapacitySnapshot() {
		if cap.ModelID == m.ToBuild {
			return cap.RoutableProviders > 0
		}
	}
	return true
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
