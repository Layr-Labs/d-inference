### One command for a cluster: `darkbloom cluster`

- Run `darkbloom cluster` on each Mac, pick a model, done. `darkbloom cluster setup` is the same command; with no terminal it says where to run it.
- Choosing the model starts it (3 s to press n); no second question. The screen then says how the model is served in one line, for example "Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers", and where the API is ("API at http://localhost:8000 on <Mac>").
- Models that fit in the Macs' free memory now are listed first, a model that does not fit says what frees the memory, and the fit is checked again right before the start. A model the pair may not serve with this release is listed under "Not offered" ("Not yet qualified on this pair of Macs") instead of failing after a long wait.
- Two cables: the onboarding asks which one to use. The cable check prints plain lines ("Cable found.", "Cable ready."). macOS's one Local Network prompt is announced before it appears, and a denied prompt is named with where to allow it.
- After a Darkbloom update the cluster sets itself up again by itself ("Updating the cluster setup after a Darkbloom update."). After a restart, the screen says whether the Mac comes back by itself (automatic login) or once someone logs in (FileVault).
- A start that does not finish shows each Mac's last error and offers `d` to save a redacted diagnostics file. Error messages name only `darkbloom cluster`; `plan`, `configure`, `console`, `pair` and the other developer subcommands and options are hidden from the help.
