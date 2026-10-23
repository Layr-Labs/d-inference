### Queued requests across cluster batch-mode changes

- Preserve queued local cluster requests across trusted batch-mode changes, retaining their cancellation and wait deadlines while old workers release and fresh replacements or rollback sessions start.
