/// What the wire of a pipeline's speculative rounds needs from a family's
/// terms: the session's fixed draft depth and the family tag its packets'
/// schemas carry (`<family>_pipeline_speculative_round_v1`, ...), so a round
/// of one family is never read as another's. The round, result and decision
/// packets (`MiMoMTPWire.swift`) are the same contract for every family that
/// runs `pipeline_mtp_v1`. Pure: the model-free runners compile it with the
/// families' terms.
protocol PipelineSpeculativeRoundTerms {
    var depth: Int { get }
    static var roundFamily: String { get }
}
