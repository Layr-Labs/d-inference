### A short reply no longer moves the deadline decode rate once it has a sample

Deadline admission's decode rate now follows the published rate's rule: after
its first sample, only a request that generated at least 32 tokens moves it.
Any completed request still starts it, on a new slot or after the decode
evidence expired, so a slot that serves only short replies keeps a decode rate
and is priced for deadline requests as before. The heartbeat's
`observed_decode_tps`, the rate's age and `performance_measurements` are
unchanged.
