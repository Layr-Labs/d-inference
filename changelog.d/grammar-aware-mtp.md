### Grammar-aware MTP

- Constrained Qwen rows draft with MTP and every committed position is verified under the row's grammar (SDK #409), on by default since 0.10.13 (measured on Qwen 3.8 27B); `DARKBLOOM_CBV2_MTP_GRAMMAR=0` restores 0.10.12's target-only constrained rows. Forwarded by the LaunchAgent.
