package api

// Model registry handlers and helpers were split into per-concern files:
//   - model_registry_catalog_handlers.go — read-side catalog HTTP handlers
//   - model_registry_write_handlers.go   — register + admin model-action handlers
//   - model_registry_auth.go             — publishing/admin authentication
//   - model_registry_validate.go         — request/manifest validation predicates
//   - model_registry_manifest.go         — CDN manifest fetch/HEAD verify + path parsers
//   - model_registry_projection.go       — record->catalog/SupportedModel projection + helpers
