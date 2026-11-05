### The mode question recommends without quoting speeds

- `darkbloom cluster`'s mode question no longer shows tokens per second. The recommendation says why in words ("Recommended for Gemma 4 26B on these two Macs: Pipeline, faster here.") instead of "faster here (about 56 against 52 tokens/s, predicted)", and each mode's line drops its "N tok/s measured" or "not measured on these Macs yet". A re-plan's "Planned in the mode chosen" line drops the planner's predicted speed too. The measured or predicted speeds still decide which mode is recommended.
- A mode that serves more requests at once and is as fast now says "serves up to 8 requests at once and is as fast here" instead of calling itself faster.
