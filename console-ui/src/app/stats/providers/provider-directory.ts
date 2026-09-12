import { compareProviders, matchesTrustFilter, providerRouteState, type ProviderSortKey, type ProviderStats, type ProviderStatusFilter, type ProviderTrustFilter } from "../provider-fleet";

export const PROVIDERS_PER_PAGE = 25;
export interface ProviderDirectoryFilters {
  query: string;
  status: ProviderStatusFilter;
  trust: ProviderTrustFilter;
  model: string;
  sort: ProviderSortKey;
}
export const DEFAULT_DIRECTORY_FILTERS: ProviderDirectoryFilters = { query: "", status: "all", trust: "all", model: "all", sort: "readiness" };

export function providerModels(provider: ProviderStats): string[] {
  return [...new Set([...(provider.models ?? []), ...(provider.current_model ? [provider.current_model] : [])])];
}

export function filterProviderDirectory(providers: ProviderStats[], filters: ProviderDirectoryFilters): ProviderStats[] {
  const normalizedQuery = filters.query.trim().toLowerCase();
  return providers.filter((provider) => {
    const models = providerModels(provider);
    const haystack = [provider.id, provider.chip, provider.machine_model, ...models].filter(Boolean).join(" ").toLowerCase();
    return (!normalizedQuery || haystack.includes(normalizedQuery)) &&
      (filters.status === "all" || providerRouteState(provider) === filters.status) &&
      matchesTrustFilter(provider, filters.trust) &&
      (filters.model === "all" || models.includes(filters.model));
  }).sort((a, b) => compareProviders(a, b, filters.sort));
}

export function providerDirectoryPage(providers: ProviderStats[], requestedPage: number) {
  const pageCount = Math.max(1, Math.ceil(providers.length / PROVIDERS_PER_PAGE));
  const page = Math.max(1, Math.min(requestedPage, pageCount));
  const start = (page - 1) * PROVIDERS_PER_PAGE;
  return { page, pageCount, start, providers: providers.slice(start, start + PROVIDERS_PER_PAGE) };
}
