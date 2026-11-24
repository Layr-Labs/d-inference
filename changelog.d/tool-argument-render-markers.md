### Tool-call arguments under `{}`, `true` and `false` parameter schemas read as untyped

- The coordinator forwards a parameter schema of `{}`, `true` or `false` as a
  string with a render marker. The provider's strict check already read the
  marker; argument reading now does too, so such a parameter (or an array's
  items) is read as untyped, or as admitting nothing, rather than as a
  declared string.
- `DARKBLOOM_LOCAL_ALLOW_TOOL_SCHEMA_METADATA=1` is a testing switch that lets
  the local API (`darkbloom start --local`) accept tool schemas with that
  marker, as the coordinator forwards them. Off by default; a warning is
  logged when it is on.
