### A simpler start: Autopilot only for the network, a picker that opens on what fits, no key on screen

- `darkbloom start` asks about the experimental Autopilot only when this Mac serves the Darkbloom network. Both, me first and Only me never ask; `darkbloom autopilot enable` enrolls them, and `--autopilot` / `--no-autopilot` still decide for any start.
- The model picker opens with your last selection still on this Mac selected, else one downloaded model that fits with room to spare, else the smallest one that fits. It never pre-selects a model it would have to download, and no longer the biggest one that fits (it pre-selected a 176 GiB model on a test Mac).
- No start screen prints the local key: `darkbloom start --local --here` now says ``API key:  `darkbloom local` shows it``, and where your requests go, instead of the key and `export OPENAI_API_KEY=…` lines.
