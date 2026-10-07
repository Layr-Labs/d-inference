package request_test

import (
	"bytes"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// (a) A schema nested far deeper than fixtureMaxToolSchemaDepth must NOT panic or
// overflow the stack; the shallow part is normalized and the part beyond the
// depth budget is left exactly as-is (which is safe — see fixtureMaxToolSchemaDepth).
func TestNormalizeToolSchemas_DepthLimitStopsRecursionWithoutPanic(t *testing.T) {
	const levels = fixtureMaxToolSchemaDepth + 200 // comfortably past the ceiling
	body := tsnDeepPropertiesBody(levels)

	var out []byte
	// A naive unbounded recursion on a sufficiently deep input would overflow
	// the stack and crash the test process; reaching the assertions at all is
	// the core guarantee. (defer/recover would not catch a fatal stack overflow,
	// so the real protection is the depth bound under test, not this guard.)
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("normalization panicked on a deeply-nested schema: %v", r)
			}
		}()
		out = production.NormalizeToolSchemas(body)
	}()

	// The shallow part WAS repaired, so the body changed and re-encoded.
	if bytes.Equal(out, body) {
		t.Fatal("deeply-nested body was returned unchanged; the shallow part should have normalized")
	}

	// Walk down the properties chain and confirm: nodes above the limit gained
	// a structural "object" type, and the node at the depth limit was left
	// untouched (no type invented beyond the budget).
	node := tsnParams(t, out) // depth 0
	depth := 0
	for {
		props, ok := node["properties"].(map[string]any)
		if !ok {
			break
		}
		// A node that carries properties and was reached within the budget must
		// have been typed "object".
		if depth < fixtureMaxToolSchemaDepth {
			if got, ok := node["type"].(string); !ok || got != "object" {
				t.Fatalf("node at depth %d type = %v, want object (within budget)", depth, node["type"])
			}
		} else {
			// At or beyond the limit, recursion stopped: no type was injected.
			if _, ok := node["type"]; ok {
				t.Fatalf("node at depth %d gained a type %v; recursion should have stopped at the limit",
					depth, node["type"])
			}
		}
		child, ok := props["child"].(map[string]any)
		if !ok {
			t.Fatalf("missing properties.child at depth %d", depth)
		}
		node = child
		depth++
	}

	// The leaf is the enum-only node; it sits at depth `levels`, far past the
	// limit, so it must NOT have gained a "string" type — proof the deep part
	// was left as-is rather than (impossibly) traversed.
	if _, ok := node["type"]; ok {
		t.Errorf("enum leaf at depth %d gained a type %v; it is past the depth budget and must be untouched",
			depth, node["type"])
	}
	if enum, ok := node["enum"].([]any); !ok || len(enum) != 1 {
		t.Errorf("enum leaf content changed: %v", node["enum"])
	}
}

// A node sitting exactly at the LAST in-budget depth is still normalized; the
// first node past it is not. Pins the boundary so an off-by-one in the depth
// accounting is caught.
func TestNormalizeToolSchemas_DepthLimitBoundaryIsNormalized(t *testing.T) {
	// Leaf at depth fixtureMaxToolSchemaDepth-1 (the deepest in-budget node) must be
	// repaired; building exactly that many wrapper levels puts the enum leaf
	// one step inside the budget.
	body := tsnDeepPropertiesBody(fixtureMaxToolSchemaDepth - 1)
	out := production.NormalizeToolSchemas(body)
	if bytes.Equal(out, body) {
		t.Fatal("boundary body was not normalized")
	}

	node := tsnParams(t, out)
	for i := 0; i < fixtureMaxToolSchemaDepth-1; i++ {
		props, ok := node["properties"].(map[string]any)
		if !ok {
			t.Fatalf("missing properties at depth %d", i)
		}
		node = tsnMap(t, props["child"], "child")
	}
	// node is now the enum leaf at depth fixtureMaxToolSchemaDepth-1 (in budget).
	if got, ok := node["type"].(string); !ok || got != "string" {
		t.Errorf("in-budget leaf type = %v, want string", node["type"])
	}
}
