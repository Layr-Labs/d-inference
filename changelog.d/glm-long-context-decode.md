### GLM-5.3-Flash decodes faster at long context

GLM's paged attention reads (index metadata, latent history and each query's selected latents) now bind up to 17
memory segments per GPU launch and copy only the pages each segment holds, instead of one full-history launch per
segment after a zero fill. A long conversation's decode step therefore issues a handful of these launches instead of
hundreds. Plain decode steps (three or more concurrent requests) also submit GPU work in larger command buffers, as
Nemotron Super already does. Outputs are unchanged: every read copies the same bytes.
