### Inkling 2 Mini serves without its drafter by default

Inkling 2 Mini's DSpark drafter is now off under the default
`mtp_mode = "auto"`: on 0.10.18 candidates, sampled GPQA answers looped and ran
to their length with it on, and answered correctly with it off.
`DARKBLOOM_CBV2_MTP=1` (or `true`, `yes`, `on`) or `mtp_mode = "on"` turns it
back on; `DARKBLOOM_CBV2_MTP=0` still turns MTP off everywhere. Every other
model's MTP default is unchanged. Without the drafter, Inkling 2 Mini decodes
more slowly; its advertised decode rate and calibration are measured on the
engine as served, so they follow.
