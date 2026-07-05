import Foundation
import Testing
@testable import ProviderCore

// Errors whose `String(describing:)` carries the rich signature text — mirrors
// the real Harmony `TemplateException`, whose informative message only shows up
// in `String(describing:)` (its `localizedDescription` collapses to the lossy
// "(Jinja.TemplateException error 1.)").
private struct DescribedError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - classifyInferenceErrorReason

@Test func classifyChannelTagsFromCanonicalHarmonyText() {
    // The real provider log text. Note it ALSO contains "TemplateException" /
    // "Jinja"; channel-tags must win because it is checked first.
    let error = DescribedError(
        description: #"TemplateException(message: "You have passed a message containing <|channel|> tags in the content field. ...")"#
    )
    #expect(classifyInferenceErrorReason(error) == "jinja_channel_tags")
}

@Test func classifyChannelTagsFromContentSignaturePair() {
    // Does not contain the contiguous "containing <|channel|> tags" phrase, but
    // does carry "<|channel|>" + "tags in the content" — the secondary match.
    let error = DescribedError(
        description: "render error: a raw <|channel|> appeared; tags in the content field are rejected"
    )
    #expect(classifyInferenceErrorReason(error) == "jinja_channel_tags")
}

@Test func classifyChannelTagsFromThinkingSignaturePair() {
    let error = DescribedError(
        description: "raw <|channel|> token present; tags in the thinking field are not allowed"
    )
    #expect(classifyInferenceErrorReason(error) == "jinja_channel_tags")
}

@Test func classifyNullBridgeBeatsGenericJinja() {
    // Contains "Jinja" (would match jinja_template) but the null-bridge pair is
    // checked first, so it must classify as jinja_null_bridge.
    let error = DescribedError(
        description: "Cannot convert value of type 'Optional<Any>' to Jinja Value"
    )
    #expect(classifyInferenceErrorReason(error) == "jinja_null_bridge")
}

@Test func classifyGenericTemplateException() {
    let error = DescribedError(description: "Jinja.TemplateException: unexpected '}' in template")
    #expect(classifyInferenceErrorReason(error) == "jinja_template")
}

@Test func classifyGenericJinjaMentionOnly() {
    let error = DescribedError(description: "Jinja render failed for an unknown reason")
    #expect(classifyInferenceErrorReason(error) == "jinja_template")
}

@Test func classifyTemplateExceptionFromNSErrorLossyForm() {
    // The lossy form the coordinator sees today: NSError whose describing/
    // localized text still carries "Jinja"/"TemplateException".
    let error = NSError(
        domain: "Jinja.TemplateException",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (Jinja.TemplateException error 1.)"]
    )
    #expect(classifyInferenceErrorReason(error) == "jinja_template")
}

@Test func classifyReturnsNilForUnclassifiableError() {
    let error = DescribedError(description: "connection reset by peer")
    #expect(classifyInferenceErrorReason(error) == nil)
}

@Test func classifyReturnsNilForGenericNSError() {
    let error = NSError(domain: "NSURLErrorDomain", code: -1004, userInfo: nil)
    #expect(classifyInferenceErrorReason(error) == nil)
}

// MARK: - offendingHarmonyMessageLocation

@Test func offendingLocationFindsAssistantContentByIndexAndRole() {
    let messages: [[String: any Sendable]] = [
        ["role": "system", "content": "You are helpful."],
        ["role": "user", "content": "Hello"],
        ["role": "assistant", "content": "<|channel|>analysis<|message|>SECRET reasoning text"],
    ]
    let location = offendingHarmonyMessageLocation(in: messages)
    #expect(location?.index == 2)
    #expect(location?.role == "assistant")
}

@Test func offendingLocationScansReasoningContentField() {
    let messages: [[String: any Sendable]] = [
        ["role": "assistant", "content": "clean", "reasoning_content": "<|channel|>final SECRET"],
    ]
    let location = offendingHarmonyMessageLocation(in: messages)
    #expect(location?.index == 0)
    #expect(location?.role == "assistant")
}

@Test func offendingLocationScansThinkingField() {
    let messages: [[String: any Sendable]] = [
        ["role": "user", "content": "hi"],
        ["role": "assistant", "thinking": "leading <|channel|> SECRET"],
    ]
    let location = offendingHarmonyMessageLocation(in: messages)
    #expect(location?.index == 1)
    #expect(location?.role == "assistant")
}

@Test func offendingLocationReturnsFirstMatch() {
    let messages: [[String: any Sendable]] = [
        ["role": "user", "content": "earliest <|channel|> here"],
        ["role": "assistant", "content": "later <|channel|> too"],
    ]
    let location = offendingHarmonyMessageLocation(in: messages)
    #expect(location?.index == 0)
    #expect(location?.role == "user")
}

@Test func offendingLocationReturnsNilWhenNoChannelTags() {
    let messages: [[String: any Sendable]] = [
        ["role": "system", "content": "You are helpful."],
        ["role": "assistant", "content": "a perfectly normal reply"],
    ]
    #expect(offendingHarmonyMessageLocation(in: messages) == nil)
}

@Test func offendingLocationNeverExposesContent() {
    // The return type is (index, role) only — there is no channel through which
    // content could leak. Assert the returned values carry NO substring of the
    // (secret) content, as a privacy regression guard.
    let secret = "TOP-SECRET-PROMPT-9f3a"
    let messages: [[String: any Sendable]] = [
        ["role": "assistant", "content": "<|channel|>\(secret)"],
    ]
    let location = offendingHarmonyMessageLocation(in: messages)
    #expect(location?.role == "assistant")
    #expect(location?.role.contains(secret) == false)
    #expect(location.map { "\($0.index)\($0.role)" }?.contains(secret) == false)
}
