### Cluster: degraded mode only where single-Mac Darkbloom serves the model

- When the other Mac goes away, a Mac serves the model alone only if single-Mac Darkbloom would serve that model on it (the same runtime requirements `darkbloom start --local` applies, such as an Apple M5 chip for Qwen3.8 27B) and the planner said it fits in that Mac's memory. Otherwise its status says it cannot serve the model alone and waits for the other Mac; the cluster re-forms by itself when it is back. A single-Mac server that still ends right after starting three times in a row is not started again until the cluster re-forms.
- The deployment line ("Serving … across both Macs: pipeline, M5 Ultra 40 layers / M3 Ultra 8 layers") is the same on whichever Mac leads, also when the model's first part runs on the other Mac. Models are listed by their catalog names.
- A stopped cluster's `darkbloom cluster` offers `v` (check that both Macs released their memory) on the leading Mac too, not only on a member.
