package api

// DAR-347 dispatch-loop integration tests: oversized / capacity rejections must
// stop the failover loop early (uptime-neutral 429) instead of storming all 64
// providers, while genuine transient-capacity rejections still fail over. They
// reuse the failover harness (setupFailoverServer / startFailoverProvider /
// postChat) and drive the REAL dispatch loop through fake WS providers.
