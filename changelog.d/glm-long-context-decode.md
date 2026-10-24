### GLM-5.3-Flash decodes faster at long context

GLM's paged attention reads (index metadata, latent history and each query's selected latents) now bind up to 17
memory segments per GPU launch and copy only the pages each segment holds, instead of one full-history launch per
segment after a zero fill. Decode steps and MTP verification rounds also submit GPU work in larger command buffers,
as Nemotron Super already does for plain decode. On an M5 Ultra, one request now decodes at about 73, 62 and 48
tokens per second after 8K-, 32K- and 64K-token prompts, up from about 63, 36 and 19. Outputs are unchanged: every
read copies the same bytes.
