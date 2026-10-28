### Expired checkpoints no longer count as corrupt after a restart

- When a provider restarted more than 30 minutes after its last cache use,
  the complete-checkpoint store (Qwen, Nemotron, GLM, Bonsai, MiMo) removed
  each expired file through the corrupt-file path, so every one was reported
  in `corrupt_drops_total`. Expired files are still removed at startup, but
  they are no longer counted as corrupt, so that counter again reports only
  files that failed validation.
