### Uninstall Darkbloom: keep your data, or remove everything

- `darkbloom uninstall` takes Darkbloom off a Mac in one step. In a terminal it shows what each choice removes, with sizes, and asks: keep models and settings (you might come back), remove everything (not coming back), or cancel.
- Keeping models and settings stops serving the way `darkbloom stop` does, stops this Mac's part of a two-Mac pair and removes every Darkbloom background service, including the cluster service. Every file stays, with the pairing and the cable port setup; install again and run `darkbloom start` or `darkbloom cluster` to come back.
- Removing everything also forgets the pairing, undoes the cable port setup (macOS asks for your password) and deletes Darkbloom's settings, the models it downloaded, its caches, logs, the app and the `darkbloom` command link, then says what it removed and how much space it freed.
- It never deletes anything outside Darkbloom's folders: models in a folder you chose, and links that point elsewhere, are kept and listed. Keychain keys stay; a new install replaces them. On a paired Mac it ends with what to run on the other Mac.
- For scripts and agents: `--keep-data` or `--everything` with `--yes`, and `--dry-run` (with `--json`) to list every action and path without changing anything. `darkbloom stop --uninstall` works as before.
