### A latent stop race in GLM tensor parallel's one-token decode

- No released pair is affected, and serving is unchanged: every v0.10.6 GLM-5.3-Flash tensor-parallel pair loads the model's NextN (MTP) layer and decodes every request in MTP rounds, which already end both Macs together when a request stops just before the model's end token.
- The one-token decode, which only a build without that layer runs, now does the same: both Macs end at the end token and return the text up to the stop (for example, a stop string that matched just before the answer ended). Before, the stopped Mac built one more step alone and waited in a collective the other Mac, already finished at that token, never joined, so the request would stall and fail on both Macs.
