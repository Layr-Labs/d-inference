/// A different Gemma batch graph must be agreed before either rank reads
/// weights. Singleton and every other family retain their existing bytes.
enum Gemma4BatchArithmeticAgreement {
    static func fields(runtimeModelID: String, lanes: Int) -> [String] {
        guard (2...8).contains(lanes), Gemma4RegisteredModel(rawValue: runtimeModelID) != nil else { return [] }
        return ["gemma4-batch-row-m1-v1", "lanes=\(lanes)", "expert-rows=singleton"]
    }
}
