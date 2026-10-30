### A Mac pair keeps its DevNet cluster approval across provider updates

- The coordinator can serve a model approval: a cluster approval that names the model, its prefill schedule and its serving terms, but no build. The pair takes it when its model, schedule and artifact are the saved setup's, and it computes no build facts for it. Entries pinned to one build are matched as before.
- After an update, the re-adopted setups find the same model approval at the next check, so the pair is registered with the coordinator again with no new entry from the operator.
- Under a model approval each Mac registers its plan with its own runtime (worker, capability, resource policy and profile), and a session starts only with that runtime. Each Mac hashes its worker against its saved setup and its metallib and resource library against the digests it took when it registered.
