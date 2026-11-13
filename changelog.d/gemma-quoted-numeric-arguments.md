### Gemma quoted numeric tool arguments

Adopt the opt-in SDK parser fix. `DARKBLOOM_GEMMA_SCHEMA_COERCION=1` enables it for a foreground provider; unset or `0` retains current behavior. Numeric marker strings become numbers at frame close only when the parameter schema unambiguously requests a numeric type. Potentially converted values stay withheld from argument deltas until the completed parse; unsupported or ambiguous schemas preserve their quoted text. The provider still validates strict calls.
