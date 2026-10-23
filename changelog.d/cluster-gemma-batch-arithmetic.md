### Preserve Gemma request arithmetic in native batches

Gemma cluster decode preserves each request’s singleton projection, value normalization and expert arithmetic while retaining independent cache histories. Both ranks agree on the batch arithmetic before loading. Full-artifact GPU and pair performance qualification remain separate gates.
