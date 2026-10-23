### GLM-5.3-Flash variable-frame-rate video

- Serve GLM-5.3-Flash `video_url` clips with a variable frame rate instead of refusing them with 400 `invalid_media`. OpenRouter's `input-video-base64` readiness clip (QuickTime, 211 frames in 10.8 s) was refused this way. Like the reference loader, the processor now indexes frames in presentation order and times frame i at i / the track's average frame rate, then applies the unchanged 2 FPS sampler; constant-frame-rate clips sample exactly as before.
