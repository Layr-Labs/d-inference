### The Models page shows what the network registered

- Each model on the Models page now says whether this Mac's live registration carries it: "Registered with the network" (the network sends it requests), "Registered for Autopilot" (Autopilot can load it), or, for a selected or pool model, a warning "Not registered with the network yet". Before, the page showed only what was selected, downloaded or loaded, so a selected model the network did not know looked like it was serving.
- The provider writes the registered set to its state file (`registered_models`).
- A Mac with Autopilot that is busy at every check, or always under a lease, now reports a newly verified build after at most 10 minutes. The re-registration closes admission, lets accepted requests finish, then reconnects. Before, such a Mac could wait without end, and Autopilot could not use the build.
