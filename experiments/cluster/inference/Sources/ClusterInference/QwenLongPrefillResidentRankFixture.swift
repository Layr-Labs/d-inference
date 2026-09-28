import Foundation

/// Exact retained CPU configuration used by the registered-profile fixture.
/// No filesystem, model payload, environment or native operation is performed.
enum QwenLongPrefillResidentRankFixture {
    static let artifactSHA256 = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"
    static let configurationSHA256 = "c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423"

    static func configuration() throws -> Data {
        let encoded = [
        "ewogICJhcmNoaXRlY3R1cmVzIjogWwogICAgIlF3ZW4zXzVGb3JDb25kaXRpb25hbEdlbmVyYXRpb24iCiAgXSwKICAiaW1hZ2Vf",
        "dG9rZW5faWQiOiAyNDgwNTYsCiAgIm1vZGVsX3R5cGUiOiAicXdlbjNfNSIsCiAgInF1YW50aXphdGlvbiI6IHsKICAgICJncm91",
        "cF9zaXplIjogNjQsCiAgICAiYml0cyI6IDQsCiAgICAibW9kZSI6ICJhZmZpbmUiCiAgfSwKICAicXVhbnRpemF0aW9uX2NvbmZp",
        "ZyI6IHsKICAgICJncm91cF9zaXplIjogNjQsCiAgICAiYml0cyI6IDQsCiAgICAibW9kZSI6ICJhZmZpbmUiCiAgfSwKICAidGV4",
        "dF9jb25maWciOiB7CiAgICAiYXR0ZW50aW9uX2JpYXMiOiBmYWxzZSwKICAgICJhdHRlbnRpb25fZHJvcG91dCI6IDAuMCwKICAg",
        "ICJhdHRuX291dHB1dF9nYXRlIjogdHJ1ZSwKICAgICJkdHlwZSI6ICJiZmxvYXQxNiIsCiAgICAiZW9zX3Rva2VuX2lkIjogMjQ4",
        "MDQ0LAogICAgImZ1bGxfYXR0ZW50aW9uX2ludGVydmFsIjogNCwKICAgICJoZWFkX2RpbSI6IDI1NiwKICAgICJoaWRkZW5fYWN0",
        "IjogInNpbHUiLAogICAgImhpZGRlbl9zaXplIjogNDA5NiwKICAgICJpbml0aWFsaXplcl9yYW5nZSI6IDAuMDIsCiAgICAiaW50",
        "ZXJtZWRpYXRlX3NpemUiOiAxMjI4OCwKICAgICJsYXllcl90eXBlcyI6IFsKICAgICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAg",
        "ICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9uIiwKICAg",
        "ICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAgICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwK",
        "ICAgICAgImZ1bGxfYXR0ZW50aW9uIiwKICAgICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAgICAibGluZWFyX2F0dGVudGlvbiIs",
        "CiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9uIiwKICAgICAgImxpbmVhcl9hdHRlbnRpb24i",
        "LAogICAgICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9u",
        "IiwKICAgICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAgICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50",
        "aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9uIiwKICAgICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAgICAibGluZWFyX2F0dGVu",
        "dGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9uIiwKICAgICAgImxpbmVhcl9hdHRl",
        "bnRpb24iLAogICAgICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJfYXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0",
        "ZW50aW9uIiwKICAgICAgImxpbmVhcl9hdHRlbnRpb24iLAogICAgICAibGluZWFyX2F0dGVudGlvbiIsCiAgICAgICJsaW5lYXJf",
        "YXR0ZW50aW9uIiwKICAgICAgImZ1bGxfYXR0ZW50aW9uIgogICAgXSwKICAgICJsaW5lYXJfY29udl9rZXJuZWxfZGltIjogNCwK",
        "ICAgICJsaW5lYXJfa2V5X2hlYWRfZGltIjogMTI4LAogICAgImxpbmVhcl9udW1fa2V5X2hlYWRzIjogMTYsCiAgICAibGluZWFy",
        "X251bV92YWx1ZV9oZWFkcyI6IDMyLAogICAgImxpbmVhcl92YWx1ZV9oZWFkX2RpbSI6IDEyOCwKICAgICJtYXhfcG9zaXRpb25f",
        "ZW1iZWRkaW5ncyI6IDI2MjE0NCwKICAgICJtbHBfb25seV9sYXllcnMiOiBbXSwKICAgICJtb2RlbF90eXBlIjogInF3ZW4zXzVf",
        "dGV4dCIsCiAgICAibXRwX251bV9oaWRkZW5fbGF5ZXJzIjogMSwKICAgICJtdHBfdXNlX2RlZGljYXRlZF9lbWJlZGRpbmdzIjog",
        "ZmFsc2UsCiAgICAibnVtX2F0dGVudGlvbl9oZWFkcyI6IDE2LAogICAgIm51bV9oaWRkZW5fbGF5ZXJzIjogMzIsCiAgICAibnVt",
        "X2tleV92YWx1ZV9oZWFkcyI6IDQsCiAgICAicm1zX25vcm1fZXBzIjogMWUtMDYsCiAgICAidXNlX2NhY2hlIjogdHJ1ZSwKICAg",
        "ICJ2b2NhYl9zaXplIjogMjQ4MzIwLAogICAgIm1hbWJhX3NzbV9kdHlwZSI6ICJmbG9hdDMyIiwKICAgICJyb3BlX3BhcmFtZXRl",
        "cnMiOiB7CiAgICAgICJtcm9wZV9pbnRlcmxlYXZlZCI6IHRydWUsCiAgICAgICJtcm9wZV9zZWN0aW9uIjogWwogICAgICAgIDEx",
        "LAogICAgICAgIDExLAogICAgICAgIDEwCiAgICAgIF0sCiAgICAgICJyb3BlX3R5cGUiOiAiZGVmYXVsdCIsCiAgICAgICJyb3Bl",
        "X3RoZXRhIjogMTAwMDAwMDAsCiAgICAgICJwYXJ0aWFsX3JvdGFyeV9mYWN0b3IiOiAwLjI1CiAgICB9CiAgfSwKICAidGllX3dv",
        "cmRfZW1iZWRkaW5ncyI6IGZhbHNlLAogICJ0cmFuc2Zvcm1lcnNfdmVyc2lvbiI6ICI0LjU3LjAuZGV2MCIsCiAgInZpZGVvX3Rv",
        "a2VuX2lkIjogMjQ4MDU3LAogICJ2aXNpb25fY29uZmlnIjogewogICAgImRlZXBzdGFja192aXN1YWxfaW5kZXhlcyI6IFtdLAog",
        "ICAgImRlcHRoIjogMjcsCiAgICAiaGlkZGVuX2FjdCI6ICJnZWx1X3B5dG9yY2hfdGFuaCIsCiAgICAiaGlkZGVuX3NpemUiOiAx",
        "MTUyLAogICAgImluX2NoYW5uZWxzIjogMywKICAgICJpbml0aWFsaXplcl9yYW5nZSI6IDAuMDIsCiAgICAiaW50ZXJtZWRpYXRl",
        "X3NpemUiOiA0MzA0LAogICAgIm1vZGVsX3R5cGUiOiAicXdlbjNfNSIsCiAgICAibnVtX2hlYWRzIjogMTYsCiAgICAibnVtX3Bv",
        "c2l0aW9uX2VtYmVkZGluZ3MiOiAyMzA0LAogICAgIm91dF9oaWRkZW5fc2l6ZSI6IDQwOTYsCiAgICAicGF0Y2hfc2l6ZSI6IDE2",
        "LAogICAgInNwYXRpYWxfbWVyZ2Vfc2l6ZSI6IDIsCiAgICAidGVtcG9yYWxfcGF0Y2hfc2l6ZSI6IDIKICB9LAogICJ2aXNpb25f",
        "ZW5kX3Rva2VuX2lkIjogMjQ4MDU0LAogICJ2aXNpb25fc3RhcnRfdG9rZW5faWQiOiAyNDgwNTMsCiAgIm10cGx4X210cCI6IHsK",
        "ICAgICJpbmNsdWRlZCI6IHRydWUsCiAgICAicHJlZml4IjogIm10cC4iLAogICAgIm1vZGVsX3R5cGUiOiAicXdlbjNfNV9tdHAi",
        "LAogICAgImJsb2NrX3NpemUiOiAzLAogICAgInNoYXJlc190YXJnZXRfZW1iZWRkaW5ncyI6IHRydWUsCiAgICAic2hhcmVzX3Rh",
        "cmdldF9sbV9oZWFkIjogdHJ1ZQogIH0sCiAgIm10cGx4X210cF9xdWFudGl6YXRpb24iOiB7CiAgICAiZ3JvdXBfc2l6ZSI6IDY0",
        "LAogICAgImJpdHMiOiA0LAogICAgIm1vZGUiOiAiYWZmaW5lIgogIH0KfQ==",
        ].joined()
        guard let value = Data(base64Encoded: encoded), sha256(value) == configurationSHA256 else {
            throw ProbeError("Resident admission fixture configuration changed")
        }
        return value
    }

    static func epoch(_ index: Int) throws -> String {
        guard (1...17).contains(index) else { throw ProbeError("Fixture epoch index is outside1...17") }
        let suffix = String(index, radix: 16)
        return String(repeating: "0", count: 32 - suffix.count) + suffix
    }

    static func prompt(_ variant: Int) throws -> Data {
        guard (0...1).contains(variant) else { throw ProbeError("Unknown fixture prompt") }
        return try JSONSerialization.data(withJSONObject: (0..<8192).map { ($0 * 17 + variant) % 1024 })
    }
}
