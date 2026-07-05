import { proxyHeaders } from "../http/proxy-client";
import type { Model } from "./types";

export async function fetchModels(): Promise<Model[]> {
  const res = await fetch("/api/models", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch models: ${res.status}`);
  const data = await res.json();
  const raw = Array.isArray(data)
    ? data
    : Array.isArray(data.data)
      ? data.data
      : Array.isArray(data.models)
        ? data.models
        : [];
  // Flatten metadata into top-level fields for the UI.
  return raw.map((m: Record<string, unknown>) => {
    const meta = (m.metadata || {}) as Record<string, unknown>;
    return {
      ...m,
      model_type: m.model_type || meta.model_type,
      quantization: m.quantization || meta.quantization,
      provider_count: m.provider_count ?? meta.provider_count,
      trust_level: m.trust_level || meta.trust_level,
      attested: m.attested ?? (meta.attested_providers as number) > 0,
      display_name: m.display_name || meta.display_name,
      size_bytes: m.size_bytes ?? meta.size_bytes,
      size_gb: m.size_gb ?? meta.size_gb,
      min_ram_gb: m.min_ram_gb ?? meta.min_ram_gb,
      max_context_length: m.max_context_length ?? meta.max_context_length,
      max_output_length: m.max_output_length ?? meta.max_output_length,
      architecture: m.architecture ?? meta.architecture,
      family: m.family ?? meta.family,
      capabilities: m.capabilities ?? meta.capabilities,
      // OpenRouter provider schema fields.
      name: m.name ?? meta.display_name,
      hugging_face_id: m.hugging_face_id ?? m.id,
      created: m.created,
      description: m.description ?? meta.description,
      context_length: m.context_length ?? m.max_context_length ?? meta.max_context_length,
      pricing: m.pricing,
      input_modalities: m.input_modalities,
      output_modalities: m.output_modalities,
      supported_features: m.supported_features,
      supported_sampling_parameters: m.supported_sampling_parameters,
    };
  });
}
