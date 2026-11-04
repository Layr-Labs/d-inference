### Two-Mac cluster: findings of the 0.10.8 candidate on real Macs

- Choosing **Serve locally only** at the first setup's login check now starts the local plan: the model is planned again
  for serving locally before anything starts, so Qwen 3.8 27B tensor parallel keeps its tensor assistant (the candidate
  measured 15.7 tok/s without it, 36–39 with it on the same pair).
- When a part keeps ending because the link to the other Mac keeps closing, the ✗ says so and names the other Mac's side
  ("the other Mac's worker ended or the cable dropped") instead of blaming this Mac and calling the other "running, no
  error reported"; the title no longer shows the internal "starting; " word.
- The DevNet app's cluster screens and `status` name its own command (`darkbloom-dev …`), not the production
  `darkbloom`.
- The mode you choose for a model is now the one that loads, also for GLM-5.3-Flash. When a part keeps ending, the
  message names the Mac whose worker actually stopped (or says it can't tell), gives the other Mac's own reason when it
  can't connect (for example, macOS blocking its local network access), and no longer shows a planned model switch as
  a crash. The DevNet app names its own command in more messages.
