### Qwen3.8 unsupported reasoning effort is a client error

Qwen3.8-27B requests with thinking enabled and an effort its template does not
accept, such as `high` or `minimal`, now fail before rendering with the typed
HTTP 400 that Flash-Next already returns. Text requests previously surfaced as
a provider 500 `template_render` failure; media requests hit the same raise
inside vision preparation and were reported as a retryable 503
`capacity_busy`. Typed request errors from media preparation now keep their
own status.
