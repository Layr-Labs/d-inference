### GLM-5.3-Flash serves long videos by sampling fewer frames

- A GLM Mac kept every frame of a video's 2 FPS sample at the clip's own size, within a 512 MiB decoded-frame cap, so it refused (400) a 720p clip past about 97 seconds and a 1080p clip past about 43, even after the long-video fit.
- Such a clip now keeps the frames the cap holds (193 of 720p, 85 of 1080p), spread over the whole clip, and the long-video fit shrinks them to the prepared-pixel cap, so clips up to the 600-second limit are served. A clip within the cap is sampled as before. A GLM pair still refuses such a clip: its second Mac prepares the video from the first Mac's budgets, which can't carry this yet.
- `DARKBLOOM_GLM_LONG_VIDEO_SAMPLING=0` (or `false`, `no`, `off`) keeps the full sample and the refusal; `darkbloom start` passes it to the launchd provider.
