### The app's Studio serves the CLI's way, and Updates can roll back

- This Mac > Studio asks the start question in its own words: **Only me**, **Darkbloom network** or **Both, me first** (recommended), with the saved choice marked. **Apply** saves the new choice and restarts serving with the models serving now (or one you choose when none serves), and says so first. Before, Studio offered only "Alongside the network" and "Local only", and the network alone couldn't be chosen in the app.
- With **Both, me first**, Studio turns me first on or off and sets the minutes with none of your requests before Darkbloom comes back (1 to 120); a change applies when serving restarts, and **Restart serving** is offered. It says when Darkbloom is paused for you and when it comes back.
- **When this Mac can't take a request**: Only this Mac, Only my Macs (free) or My Macs first (then the network, billed to your balance), saved as `darkbloom route` saves it. The last two need your account API key: paste it once and **Save key**. The app sends it to the Keychain and keeps no copy; it shows only "Key saved".
- **Use it in your tools**: **Set up OpenCode** and **Set up Hermes** run `darkbloom --opencode` and `--hermes`; with an older CLI, Studio shows those commands to copy. Connection details add the port and address the local API listens on.
- Updates offers **Return to the previous release** (`darkbloom update --rollback`), asked first.
- With a CLI from before these, Studio stays as it was, with one line saying a newer Darkbloom CLI adds me first, request routing and tool setup.
