### Grammar-aware MTP

- Constrained rows draft with MTP and every committed position is verified under the row's grammar (SDK #409). On by default since 0.10.13 for the Qwen 3.8 27B build only (measured there in its ON state, with constraint spans); Gemma 4 and Super keep target-only constrained rows unless `DARKBLOOM_CBV2_MTP_GRAMMAR=1`. `DARKBLOOM_CBV2_MTP_GRAMMAR=0` restores 0.10.12 everywhere. Forwarded by the LaunchAgent.
