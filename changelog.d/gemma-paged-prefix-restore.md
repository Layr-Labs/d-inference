### Restore Gemma paged prefix tails safely

- Restore sliding-window prefix tails in writes bounded by the page pool's configured chunk size. A cached tail longer than one prefill chunk no longer traps a cluster worker when another request joins the batch.
- Keep the paged default when installed Gemma serving widens its batch. Contiguous storage remains available as an explicit local diagnostic.
