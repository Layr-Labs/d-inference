package registry_test

// The operator's approval file is the only way configuration becomes a
// catalog. It is strict: anything unknown, missing, malformed or out of
// bounds is refused, so a mistyped file never enables a weaker policy.

import (
	"encoding/json"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

func TestNativeRuntimeCatalogFileIsStrict(t *testing.T) {
	entry := func(mutate func(map[string]any)) map[string]any {
		approval := clustermember.Approval("approval-a", nativePairFixtureModel, "fixture-chip", "second-chip")
		if mutate != nil {
			mutate(approval)
		}
		return approval
	}
	document := func(schema string, approvals ...map[string]any) []byte {
		data, err := json.Marshal(map[string]any{"schema": schema, "approvals": approvals})
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	valid := document(production.NativeRuntimeCatalogSchema, entry(nil))
	catalog, err := production.ParseNativeRuntimeCatalog(valid)
	if err != nil {
		t.Fatalf("valid catalog refused: %v", err)
	}
	policy, ok := catalog.PolicySHA256("approval-a")
	if !ok || len(policy) != 64 || policy != strings.ToLower(policy) {
		t.Fatalf("policy commitment = %q, %v", policy, ok)
	}
	if _, ok = catalog.PolicySHA256("unknown"); ok {
		t.Fatal("commitment reported for an approval the catalog does not hold")
	}
	if production.NewNativePairCoordinator(pairEnvironment(t), catalog) == nil {
		t.Fatal("parsed catalog did not enable pair control")
	}
	// A changed approval is a different policy: members that installed the old
	// one are not silently offered the new one.
	changed, err := production.ParseNativeRuntimeCatalog(document(production.NativeRuntimeCatalogSchema,
		entry(func(a map[string]any) { a["generation"] = 4 })))
	if err != nil {
		t.Fatal(err)
	}
	if other, _ := changed.PolicySHA256("approval-a"); other == policy {
		t.Fatal("policy commitment did not change with the approval")
	}

	refused := map[string][]byte{
		"not JSON":             []byte("schema: yaml"),
		"wrong schema":         document("darkbloom_cluster_pair_catalog_v0", entry(nil)),
		"no approvals":         document(production.NativeRuntimeCatalogSchema),
		"unknown top field":    []byte(strings.Replace(string(valid), `"schema"`, `"default_trust":true,"schema"`, 1)),
		"unknown entry field":  document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["allow_all"] = true })),
		"trailing document":    append(append([]byte{}, valid...), valid...),
		"duplicate id":         document(production.NativeRuntimeCatalogSchema, entry(nil), entry(nil)),
		"missing digest":       document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { delete(a, "metallib_sha256") })),
		"uppercase digest":     document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["plan_sha256"] = strings.Repeat("A", 64) })),
		"zero digest":          document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["plan_sha256"] = strings.Repeat("0", 64) })),
		"short digest":         document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["plan_sha256"] = "abcd" })),
		"missing generation":   document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { delete(a, "generation") })),
		"unknown schedule":     document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["schedule"] = 3 })),
		"no frame overhead":    document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["maximum_transport_frame"] = 4096 })),
		"no chips":             document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["allowed_chips"] = []string{} })),
		"unsorted chips":       document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["allowed_chips"] = []string{"b", "a"} })),
		"missing expiry":       document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { delete(a, "not_after") })),
		"expiry not RFC 3339":  document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["not_after"] = "next year" })),
		"oversized file":       append([]byte(strings.Repeat(" ", 1<<20)), valid...),
		"negative record cap":  document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["maximum_records"] = -1 })),
		"model missing":        document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["model"] = "" })),
		"approval id too long": document(production.NativeRuntimeCatalogSchema, entry(func(a map[string]any) { a["id"] = strings.Repeat("i", 129) })),
	}
	for name, data := range refused {
		if got, err := production.ParseNativeRuntimeCatalog(data); err == nil || got != nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}
