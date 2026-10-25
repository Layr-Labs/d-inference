### Concurrent tensor-parallel requests verify together

- Concurrent speculative requests on a two-Mac tensor-parallel pair now stay in one verify cohort. A request that still has up to one round of accepted tokens waiting joins the next round from its own settled position instead of waiting for its queue to drain, so requests that started a step apart no longer take turns verifying alone. Every request still produces exactly the tokens it produces alone.
