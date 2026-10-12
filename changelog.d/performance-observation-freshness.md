### Performance observation freshness

- Keep provider measurement age and expiry tied to the newest observation when older completed work arrives later. Delayed receipts no longer expire fresh aggregate, qualified or workload-bucket evidence, or cause the next sample to reseed an estimate across a false evidence gap. Existing arrival-order rate averaging and completed-work counts are preserved.
