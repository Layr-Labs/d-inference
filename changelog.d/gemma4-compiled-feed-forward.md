### Gemma 4 compiled feed-forward dispatch

Adopt the native SDK's shape-specialized feed-forward graph for eligible Gemma 4
GPU decode and verification rows. A matched single-request M5 Max endpoint
comparison with 8K cached context measured a further 2.5–3.2% decode-proxy gain
over the prior dispatch change. Parameter updates, eager fallbacks and existing
attention, MTP, admission, prefix-cache and SSD-write behavior are preserved.
Broader concurrency and other-chip gains remain unqualified.
