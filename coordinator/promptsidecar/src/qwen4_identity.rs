// Exact mirror of ProviderCoreFoundation.Qwen4ModelIdentity.
pub(crate) fn is_qualified(model_id: Option<&str>) -> bool {
    matches!(
        model_id,
        Some("qwen3.8-flash-next" | "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp")
    )
}
