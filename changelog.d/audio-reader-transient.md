### A MiMo V2.6 video whose audio reader fails once is decoded again, not refused

- When the reader of the audio track (LPCM or AAC) of a MiMo V2.6 video fails after the metadata checks passed, the provider reads the track once more with a new reader over the same bytes. A valid clip that met one audio reader failure is now served with the same samples. Before, the provider refused it as `invalid_media` (400), and the coordinator did not send it to another provider.
- When the audio reader fails again with a decoder, hardware or interruption fault, the provider refuses the request as a retryable 503, and the coordinator can send it to another provider. Any other second failure is still the deterministic `invalid_media` (400).
- Each failed audio reader pass logs a WARN `engine_health` event `audio_reader_failed` with the reader status and the domain and code of its errors. It carries no media or prompt content.
