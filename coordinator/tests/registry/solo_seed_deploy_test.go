package registry_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
)

// repoFile locates a repository-relative file by walking up from the test's
// working directory (the Go module root is coordinator/, one level below the
// repository root).
func repoFile(t *testing.T, rel string) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		candidate := filepath.Join(dir, rel)
		if _, statErr := os.Stat(candidate); statErr == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no ancestor of %q contains %s", dir, rel)
		}
		dir = parent
	}
}

// envValue returns the value of key in a KEY=VALUE deploy file, failing when
// the key is absent.
func envValue(t *testing.T, path, key string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if after, ok := strings.CutPrefix(strings.TrimSpace(line), key+"="); ok {
			return after
		}
	}
	t.Fatalf("%s carries no %s line", path, key)
	return ""
}

// soloSeedDeployFiles are the two files that must carry
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED, authoritative one first:
//
//   - deploy/gcp/prod/release-env-defaults is what refresh-env.sh merges into
//     /etc/d-inference/env, so it is the only one that reaches a coordinator;
//   - deploy/environments/prod.env is the sanitized reference operators read.
//     Its own header says it is not consumed directly.
//
// The seed lived ONLY in the reference file for an entire release, so the
// coordinator never saw it. Pinning both — and requiring them to agree — is
// what stops that from recurring in either direction.
var soloSeedDeployFiles = [...]string{
	"deploy/gcp/prod/release-env-defaults",
	"deploy/environments/prod.env",
}

// prodSoloTPSSeed returns the EIGENINFERENCE_MODEL_SOLO_TPS_SEED value the
// production coordinator actually receives, and fails when the sanitized
// reference has drifted from it. Reading the real files rather than pinning a
// copy is deliberate: the P1 this suite defends is a bad VALUE in them, so a
// test asserting against a hand-copied CSV would keep passing while prod
// regressed.
func prodSoloTPSSeed(t *testing.T) string {
	t.Helper()
	authoritative := envValue(t, repoFile(t, soloSeedDeployFiles[0]), modelSoloTPSSeedEnv)
	for _, rel := range soloSeedDeployFiles[1:] {
		if got := envValue(t, repoFile(t, rel), modelSoloTPSSeedEnv); got != authoritative {
			t.Fatalf("%s carries %s=%q but the authoritative %s carries %q — a coordinator would run the second value while operators read the first",
				rel, modelSoloTPSSeedEnv, got, soloSeedDeployFiles[0], authoritative)
		}
	}
	return authoritative
}

// TestSoloSeedReachesProductionEnv pins the deploy half of the blocker: the
// seed must live in the file refresh-env.sh merges into /etc/d-inference/env
// AND in the manifest that refuses a coordinator env missing it. Present in
// neither, the whole chip-class-scoped seed above is dead configuration.
func TestSoloSeedReachesProductionEnv(t *testing.T) {
	// Parses to a usable seed table with a class-qualified entry — an
	// unqualified-only CSV would re-create the fleet-wide over-admission.
	seed := quality.ParseModelFloatMap(prodSoloTPSSeed(t))
	if len(seed) == 0 {
		t.Fatalf("%s in %s parses to no usable entries", modelSoloTPSSeedEnv, soloSeedDeployFiles[0])
	}
	qualified := 0
	for key := range seed {
		if strings.Contains(key, soloSeedClassSep) {
			qualified++
		}
	}
	if qualified == 0 {
		t.Fatalf("%s carries no %q class-qualified entry — an unqualified-only seed is the fleet-wide value this suite exists to prevent",
			modelSoloTPSSeedEnv, soloSeedClassSep)
	}

	// refresh-env.sh hard-fails a coordinator env that lacks a manifest key,
	// so listing it here is what makes the seed non-optional in production.
	manifest, err := os.ReadFile(repoFile(t, "deploy/gcp/prod/required-env-keys.txt"))
	if err != nil {
		t.Fatalf("read required-env-keys.txt: %v", err)
	}
	for _, line := range strings.Split(string(manifest), "\n") {
		if strings.TrimSpace(line) == modelSoloTPSSeedEnv {
			return
		}
	}
	t.Fatalf("deploy/gcp/prod/required-env-keys.txt does not list %s — refresh-env would accept a coordinator env without it", modelSoloTPSSeedEnv)
}

// TestSoloSeedIsChipClassScoped is the P1 guard: the 70 tok/s cold-start seed
// was MEASURED on an M4 Max, and applying it fleet-wide hands an M1 Pro — which
// decodes gemma at 10-18 tok/s — a cap of 8, projecting ~3.4 tok/s per request
// at that batch against a 15 tok/s floor. The seed the coordinator resolves
// must therefore depend on the provider's chip CLASS, and every class the
// operator did not name must land on the conservative floor.
//
// It runs against the CSV actually shipped in prod.env, so re-broadening the
// seed there fails here.
func TestSoloSeedIsChipClassScoped(t *testing.T) {
	seed := prodSoloTPSSeed(t)
	reg := newQualityRegistry(testLogger()) // fresh registry == post-restart, no solo samples
	enablePerModelQualityCap(t, reg, seed, "", "")

	cases := []struct {
		name     string
		family   string
		tier     string
		wantTPS  float64
		wantCap  int
		measured bool // the class the 70 tok/s number came from
	}{
		{name: "m4_max_measured_class", family: "M4", tier: "Max", wantTPS: 70, wantCap: 8, measured: true},
		{name: "m1_pro_slower_class", family: "M1", tier: "Pro", wantTPS: 14, wantCap: 2},
		{name: "m4_pro_same_family_slower_tier", family: "M4", tier: "Pro", wantTPS: 14, wantCap: 2},
		{name: "unrecognized_chip", family: "Unknown", tier: "Unknown", wantTPS: 14, wantCap: 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := classProvider(t, reg, "box-"+tc.name, gemmaBuild, tc.family, tc.tier)
			got := resolveSolo(reg, p, gemmaBuild)
			if got.TPS != tc.wantTPS || !got.PerModel {
				t.Fatalf("%s|%s resolved %+v, want tps %v perModel true",
					tc.family, tc.tier, got, tc.wantTPS)
			}
			if cap := effCapResolved(reg, p, gemmaBuild); cap != tc.wantCap {
				t.Fatalf("%s|%s cap = %d, want %d", tc.family, tc.tier, cap, tc.wantCap)
			}
			if !tc.measured && got.TPS >= 70 {
				t.Fatalf("%s|%s inherited the M4 Max seed (%v tok/s) — the exact over-admission this fix prevents",
					tc.family, tc.tier, got.TPS)
			}
		})
	}
}

// TestSoloSeedNoMorePermissiveOnSlowerClasses is the other half of the P1: the
// scoped seed must not merely differ from the fleet-wide one, it must be
// TIGHTER everywhere except the class the fast rate was measured on.
//
// The same fleet is walked through three seed configurations — none at all
// (the pre-seed provider-level chain), the fleet-wide 70 this PR originally
// shipped, and the chip-class-scoped CSV now in prod.env — and every class
// other than M4|Max must come out no more permissive than either baseline.
// Note the pre-seed cap is the provider's REPORTED 8, not a proxy-derived
// number: with no registration benchmark and a non-dedicated model,
// effectiveMaxConcurrencyForModelRateLocked refuses to cap from the
// model-agnostic sqrt-bandwidth rate at all and returns base.
func TestSoloSeedNoMorePermissiveOnSlowerClasses(t *testing.T) {
	classes := [][2]string{{"M4", "Max"}, {"M1", "Pro"}, {"M4", "Pro"}, {"M2", "Max"}, {"Unknown", "Unknown"}}
	capsFor := func(seed string) map[string]int {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, seed, "", "")
		out := make(map[string]int, len(classes))
		for _, c := range classes {
			key := c[0] + "|" + c[1]
			p := classProvider(t, reg, "box-"+key+"-"+seed, gemmaBuild, c[0], c[1])
			out[key] = effCapResolved(reg, p, gemmaBuild)
		}
		return out
	}

	noSeed := capsFor("")
	fleetWide := capsFor(gemmaBuild + "=70") // what this PR shipped
	scoped := capsFor(prodSoloTPSSeed(t))

	for _, c := range classes {
		key := c[0] + "|" + c[1]
		if key == "M4|Max" {
			// The measured class must KEEP its cap; scoping is not a
			// fleet-wide retreat, it is a scope correction.
			if scoped[key] != fleetWide[key] {
				t.Fatalf("M4|Max cap %d != fleet-wide %d — the measured class lost its seed", scoped[key], fleetWide[key])
			}
			continue
		}
		if scoped[key] > fleetWide[key] || scoped[key] > noSeed[key] {
			t.Fatalf("%s cap %d is more permissive than a baseline (fleet-wide-70 %d, no-seed %d)",
				key, scoped[key], fleetWide[key], noSeed[key])
		}
		if scoped[key] >= fleetWide[key] {
			t.Fatalf("%s cap %d did not TIGHTEN against the fleet-wide-70 baseline %d — the fix is inert on this class",
				key, scoped[key], fleetWide[key])
		}
	}
}

// TestSoloSeedUnqualifiedEntryMakesEveryClassSeeded records why the
// `allClasses > 1` arm of crossClassBounded cannot fire on the production
// fleet, which is not visible from the resolver and is the first thing anyone
// re-litigating that arm needs to know.
//
// The shipped seed carries UNQUALIFIED entries for both served models.
// soloSeedFleetFallbacks turns each into a fleet-wide fallback (clamped to the
// slowest class-qualified value for the same model), so soloTPSSeedForClass
// returns ok for EVERY chip class, including ones no operator named. hasSeed
// is therefore true fleet-wide and short-circuits the later arms.
//
// If this fails because an unqualified entry was dropped, the `allClasses > 1`
// arm becomes live in production and its weakness stops being latent.
func TestSoloSeedUnqualifiedEntryMakesEveryClassSeeded(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, prodSoloTPSSeed(t), "", "")

	// Classes the seed does not name, including the identity an unrecognized
	// chip reaches the coordinator with.
	for _, class := range []string{"M1|Pro", "M2|Ultra", "M3|Max", "Unknown|Unknown"} {
		for _, model := range []string{gemmaBuild, gptossBuild} {
			if _, ok := reg.policy.SeedForClass(model, class); !ok {
				t.Fatalf("soloTPSSeedForClass(%q, %q) reports no seed — the unqualified entry that makes hasSeed true fleet-wide is gone, so crossClassBounded now leans on `allClasses > 1`, which bounds the sampled population and not the destination box",
					model, class)
			}
		}
	}
}
