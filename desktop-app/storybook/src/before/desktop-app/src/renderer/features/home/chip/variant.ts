export type ChipVariant = 'blueprint' | 'photoreal';
export const CHIP_VARIANTS: { id: ChipVariant; label: string }[] = [
  { id: 'blueprint', label: 'Blueprint' },
  { id: 'photoreal', label: 'Photoreal' },
];
const PARAM = 'chip';

export function readVariant(search = window.location.search): ChipVariant {
  return new URLSearchParams(search).get(PARAM) === 'photoreal' ? 'photoreal' : 'blueprint';
}
/** Records the variant in the URL, keeping other parameters as written, without a history entry. */
export function writeVariant(variant: ChipVariant) {
  const { pathname, search, hash } = window.location;
  const params = search
    .replace(/^\?/, '')
    .split('&')
    .filter((part) => part && part.split('=')[0] !== PARAM);
  window.history.replaceState(
    window.history.state,
    '',
    `${pathname}?${[...params, `${PARAM}=${variant}`].join('&')}${hash}`,
  );
}
