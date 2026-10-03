package api

// E4 (2026-07-15 platform errors deep dive): a provider error_reason of
// jinja_channel_tags / jinja_null_bridge / jinja_template is a DETERMINISTIC
// template-render failure (the same body renders identically on every
// provider). The dispatch ladder must stop on the FIRST occurrence and latch
// a single 422 model_capability rejection — instead of failing over
// fleet-wide (prod: 1.57 dispatch rows per jinja request, observed up to 17)
// — and the provider must take no reputation hit for it.
