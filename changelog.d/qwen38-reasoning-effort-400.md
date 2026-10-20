### Qwen3.8 unsupported reasoning effort is a client error

Qwen3.8-27B requests with thinking enabled and an effort its template does not
accept, such as `high` or `minimal`, now fail before rendering with the typed
HTTP 400 that Flash-Next already returns. They previously reached the
template's `raise_exception` and surfaced as a provider 500 `template_render`
failure.
