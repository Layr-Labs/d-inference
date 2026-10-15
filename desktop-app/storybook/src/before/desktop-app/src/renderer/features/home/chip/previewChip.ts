/**
 * Development preview only: review any chip tier without a matching Mac, e.g.
 * `/?preview&soc=Apple%20M3%20Ultra&memory=192`.
 */
export function previewChip(search = window.location.search) {
  const params = new URLSearchParams(search),
    memory = Number(params.get('memory'));
  return {
    chip: params.get('soc') ?? undefined,
    memoryGb: Number.isFinite(memory) && memory > 0 ? memory : undefined,
  };
}
