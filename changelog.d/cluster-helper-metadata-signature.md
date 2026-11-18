### A two-Mac pair reads its helpers' answers only from helpers signed like Darkbloom itself (security)

- A signed Darkbloom now applies the same signature check to the short runs it makes of its cluster helpers to read what they report (the worker's runtime description and the placement tool's answers): it checks the file before starting it and the started process before it runs, and uses nothing a helper signed otherwise prints. `darkbloom cluster doctor` also checks the placement tool.
