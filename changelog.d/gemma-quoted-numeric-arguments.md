### Gemma quoted numeric tool arguments

Adopt the opt-in SDK parser fix. `DARKBLOOM_GEMMA_SCHEMA_COERCION=1` enables it (the LaunchAgent forwards the switch to the installed service); unset or `0` retains current behavior. Numeric marker strings become numbers at frame close only when the parameter schema unambiguously requests a numeric type. Potentially converted values stay withheld from argument deltas until the completed parse; unsupported or ambiguous schemas preserve their quoted text. The provider still validates strict calls.

On by default since 0.10.13 (measured on Gemma 4 26B in its ON state); `DARKBLOOM_GEMMA_SCHEMA_COERCION=0` restores 0.10.12's strings.
