### GPT-OSS independent-history batch primitive

- Add a native decode primitive that batches GPT-OSS projections while retaining each request's own positions, full/sliding histories and cleanup. Resident worker concurrency remains disabled pending scheduling, admission and hardware qualification.
