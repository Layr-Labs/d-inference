### Two-Mac cluster: findings of the 0.10.8 candidate on real Macs

- Choosing **Serve locally only** at the first setup's login check now starts the local plan: the model is planned again
  for serving locally before anything starts, so Qwen 3.8 27B tensor parallel keeps its tensor assistant (the candidate
  measured 15.7 tok/s without it, 36–39 with it on the same pair).
- When a part keeps ending because the link to the other Mac keeps closing, the ✗ says so and names the other Mac's side
  ("the other Mac's worker ended or the cable dropped") instead of blaming this Mac and calling the other "running, no
  error reported"; the title no longer shows the internal "starting; " word.
- The DevNet app's cluster screens and `status` name its own command (`darkbloom-dev …`), not the production
  `darkbloom`.
