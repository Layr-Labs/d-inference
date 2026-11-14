### Grammar-aware MTP

- Adopt SDK #409: with `DARKBLOOM_CBV2_MTP_GRAMMAR=1` (forwarded by the LaunchAgent), constrained rows draft with MTP and every committed position is verified under the row's grammar; unset or `0` keeps 0.10.12's target-only constrained rows. Default per `docs/reference/configuration.md` (SDK feature defaults).
