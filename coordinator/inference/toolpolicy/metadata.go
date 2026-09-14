package toolpolicy

// rejectReservedSchemaMetadata walks a declared tool schema looking for the
// coordinator's own normalization marker. NormalizeBytes stamps
// originalBooleanSchemaKey onto schemas it rewrites so the provider can
// restore the original allow/deny-all semantics after generation; a caller
// that plants the key itself would forge that decision. Validation runs on
// the pre-normalization body (consumer.go's originalRawBody), so any
// occurrence here is client-supplied and must be refused.
//
// This is deliberately NOT a grammar-feasibility check. Auto and none never
// compile a sampler grammar — their tool calls are checked post-generation by
// the provider's JSON-Schema validator, which enforces allOf/anyOf/oneOf/not/
// enum/const/pattern/patternProperties/if-then-else/dependentRequired/
// dependentSchemas/propertyNames. Unresolvable ($ref) and annotation-dependent
// (unevaluated*) assertions are not-asserted — though author-written siblings
// beside a $ref stay enforced — so every other JSON-Schema construct passes
// through untouched.
//
// Depth bound: the walk must scan at least as deep as every walker that can
// LIFT a marker upward. NormalizeBytes descends to maxToolSchemaDepth
// and constantMarkedCombinator folds marker-only combinator nodes toward the
// root, so a forged marker below the scan horizon could otherwise surface as
// shallow, coordinator-vouched metadata — and the provider trusts vouched
// bodies (its own byte-scan only guards unvouched ones). A schema deeper than
// the horizon therefore cannot be vouched marker-free and is rejected: the
// bound fails CLOSED, and it is maxToolSchemaDepth itself so the two walks
// can never drift. Schemas past that depth do not occur in practice (the
// pre-#603 scan rejected everything past depth 32 and no legitimate traffic
// ever hit it).
func rejectReservedSchemaMetadata(schema any, depth int) error {
	if depth > maxToolSchemaDepth {
		return invalidToolConstraint(
			"tool schema exceeds the reserved-metadata scan depth", "tools")
	}
	switch value := schema.(type) {
	case []any:
		for _, child := range value {
			if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
				return err
			}
		}
	case map[string]any:
		if _, forged := value[originalBooleanSchemaKey]; forged {
			return invalidToolConstraint(
				"tool schema contains reserved internal metadata", "tools")
		}
		for _, key := range []string{
			"additionalProperties", "additionalItems", "contains", "contentSchema",
			"if", "then", "else", "not", "propertyNames",
			"unevaluatedItems", "unevaluatedProperties",
		} {
			child, exists := value[key]
			if !exists {
				continue
			}
			if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
				return err
			}
		}
		for _, key := range []string{"allOf", "anyOf", "oneOf", "prefixItems"} {
			children, ok := value[key].([]any)
			if !ok {
				continue
			}
			for _, child := range children {
				if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
					return err
				}
			}
		}
		// `items` is a schema in draft 2020-12 and a tuple in draft-07. The
		// tuple array is a container, not a schema node, so it must not
		// consume a level of the depth budget the way a nested schema does.
		if items, exists := value["items"]; exists {
			if tuple, ok := items.([]any); ok {
				for _, child := range tuple {
					if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
						return err
					}
				}
			} else if err := rejectReservedSchemaMetadata(items, depth+1); err != nil {
				return err
			}
		}
		for _, key := range []string{
			"properties", "patternProperties", "dependentSchemas",
			"dependencies", "definitions", "$defs",
		} {
			children, ok := value[key].(map[string]any)
			if !ok {
				continue
			}
			for _, child := range children {
				if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
					return err
				}
			}
		}
	}
	return nil
}
