### Nemotron prefix chunk preservation

Nemotron 3.5 Lightning prefix caching now preserves original prefill chunk boundaries and reuses only existing chunk-grid frontiers, avoiding the extra final-token frame that changes Mamba scan arithmetic. Repeated prompts recompute their final chunk. Its numerical receipt separates old cache scopes and mixed rank implementations; other model framing and qualification tolerances are unchanged.
