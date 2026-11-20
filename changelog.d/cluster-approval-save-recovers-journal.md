### A pair set up through Darkbloom no longer stays on its local API after a stop that came too early

- The setup's approval step stops both Macs' parts and saves the cluster approval. When that stop came seconds after the pair came up, it could leave this Mac's device journal behind, the save failed on it, and the pair kept serving only on its local API ("not offered to Darkbloom … run `darkbloom cluster recover`"), with nothing trying again. The save now runs the same recovery as `darkbloom cluster recover`, once, and saves again. It still clears nothing while anything from the earlier session runs.
- If that recovery can't clear the journal yet, the cluster service tries the approval again as soon as it has cleared the journal itself, and the status no longer tells you to run `darkbloom cluster recover`.
- `DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER=0` turns this off, as it does the part's own recovery.
