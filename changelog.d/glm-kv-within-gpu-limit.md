### GLM-5.3-Flash: the KV grant stays within the GPU wired-memory limit

- GLM-5.3-Flash's KV grant was sized from 90 % of physical memory alone. On a
  256 GB Mac that plans 230.4 GiB of GPU memory at full KV, more than macOS's
  default GPU wired-memory limit there (222.72 GiB). A Mac runs that default
  until the limit is raised, and after a reboot without the boot job. Long
  prompts served concurrently could then fill the KV cache past the limit, and
  Metal command buffers failed with "Insufficient Memory", which ended the
  provider.
- While GLM is resident, being loaded or retained, the KV budget now also stays
  within the live GPU limit, less the resident weights and the activation
  reserve. At the macOS default GLM's grant is about 47.9 GiB instead of
  55.6 GiB. Macs with the raised limit (`iogpu.wired_limit_mb=245760`) keep
  the full grant, and sets without GLM are unchanged. `darkbloom doctor` says when
  the lower limit holds GLM's KV cache.
