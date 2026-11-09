### MiMo image fixture downloads stay on their host

`scripts/prepare-mimo-image-http-fixtures.py` now follows a redirect only to
the scheme, host and port of the requested URL, for at most 10 redirects. curl
no longer follows redirects itself, so the script never requests another
origin. A redirect to another HTTPS host, another port or plain HTTP fails at
once and is not retried. The provider test gate now runs the script's offline
self-test on every run.
