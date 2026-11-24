### A new slot prices deadline requests from the requests it is decoding

Before its first completed request, a slot refused every request with a
first-content deadline that arrived while another request was decoding: it had
no decode rate (`decode_rate_unavailable`). It now prices that decode work at
the slowest delivered cadence among the requests decoding on it, once one has
8 tokens after its first, charged per row, and admits the request only if the
projection meets the deadline. With no such request, or with
`DARKBLOOM_TTFT_ADMISSION_FIXES=0`, it refuses as before. The
heartbeat's `observed_decode_tps` and `performance_measurements` are
unchanged.
