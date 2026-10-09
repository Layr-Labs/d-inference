export interface ModelTokenGrant {
  model_id: string;
  total_tokens: number;
  used_tokens: number;
  reserved_tokens: number;
  remaining_tokens: number;
  claimed_at: string;
}
export interface ModelTokenOffer {
  model_id: string;
  tokens: number;
  remaining_claims: number;
  max_claims: number;
  signup_cutoff_at: string;
  claim_ends_at: string | null;
  status: "available" | "claimed" | "sold_out" | "ineligible" | "unavailable";
}

export async function fetchModelTokenPromotions(token: string, model?: string): Promise<{ grants: ModelTokenGrant[]; offers: ModelTokenOffer[] }> {
  const response = await fetch(`/api/me/token-promotions${model ? "/claim" : ""}`, {
    method: model ? "POST" : "GET",
    headers: { Authorization: `Bearer ${token}`, ...(model ? { "Content-Type": "application/json" } : {}) },
    ...(model ? { body: JSON.stringify({ model_id: model }) } : {}), cache: "no-store",
  });
  if (!model && response.status === 404) return { grants: [], offers: [] };
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || "Model token promotions couldn’t be loaded. Please try again.");
  if (!Array.isArray(data.grants) || !Array.isArray(data.offers)) throw new Error("Model token promotions couldn’t be loaded. Please try again.");
  return data;
}
