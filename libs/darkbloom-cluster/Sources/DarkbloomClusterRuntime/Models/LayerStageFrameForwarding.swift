import MLX
import MLXLMCommon

/// A loaded stage whose model runs its own frames, for a family whose product
/// model class has no entry point that starts or stops inside the trunk. The
/// stage session owns the request state, the frame schedule and every check of
/// what comes back; the model owns only the arithmetic of one frame.
///
/// A model that does not conform is driven through the product class's own
/// forwarding protocols, as before.
protocol LayerStageFrameForwarding: AnyObject {
    /// The request-state geometry of this stage alone, with fresh, empty caches.
    func layerStageRequestGeometry(maximumTokens: Int) throws -> CBv2RequestGeometry

    /// One frame. `tokens` is `[1, n]`. The producer stage (rank 0) gets no
    /// residual and returns every row's residual, `[1, n, hidden]`, in the
    /// stage's activation dtype. The consumer stage (rank 1) gets the
    /// producer's rows and returns the last position's logits `[1, vocabulary]`,
    /// or, on a prompt chunk that is not the last, a `[1, 1]` handle whose
    /// evaluation commits the chunk.
    func layerStageForward(tokens: MLXArray, residual: MLXArray?,
                           caches: [any CBv2AttendingLayerCache], frame: QwenLayerStageFrame) -> MLXArray
}
