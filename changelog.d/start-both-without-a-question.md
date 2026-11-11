### `darkbloom start` serves Both without a question; `darkbloom local` serves only you

- `darkbloom start` no longer asks how this Mac serves, in a terminal or not. On a Mac with no choice saved it
  serves the Darkbloom network and this Mac's local API, and Darkbloom keeps serving while you use the Mac; one
  line says so (``Serving Darkbloom and your local API at http://127.0.0.1:8001/v1 (`darkbloom local` for local
  only).``) and the choice is saved (`[local] mode = "both"`, `me_first = false`). With an account key saved, a
  request this Mac can't take goes to your other Macs, free. Scripts and the desktop app's Start without its local
  API take the same default where nothing is saved (they served the Darkbloom network alone before).
- A saved choice is never changed: starts, `restart`, `update`, login and the watchdog serve it as saved, a pause
  saved by the earlier question included. `--local`, `--network`, `--me-first`, `--no-me-first`, `--me-first-idle`
  and `--local-endpoint` work as before. `--choose` asks nothing and says which commands to use.
- `darkbloom local` starts Only me in the background where nothing serves, then prints the address and key. Where
  Darkbloom serves, it prints them (or that there is no local API) and, only in a terminal, asks `Switch this Mac
  to local only (stops serving Darkbloom)? [y/N]`; without a terminal it never switches. On a Mac in a two-Mac
  cluster it points to `darkbloom cluster local`. `--model <id>` names Only me's models; `--json` only reads.
