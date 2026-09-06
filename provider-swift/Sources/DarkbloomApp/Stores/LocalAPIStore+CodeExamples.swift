import Foundation

extension LocalAPIStore {
    // MARK: - Code examples

    func code(
        _ example: LocalAPICodeExample,
        endpoint: LocalAPIEndpointSnapshot
    ) -> String {
        let modelID = endpoint.availableModelIDs?.first ?? "<model-id>"
        switch example {
        case .curl:
            let authLine = endpoint.requiresAuthentication
                ? "  -H \"Authorization: Bearer $OPENAI_API_KEY\" \\\n"
                : ""
            return """
            curl \(endpoint.baseURL.absoluteString)/chat/completions \\
            \(authLine)  -H 'Content-Type: application/json' \\
              -d '{"model":"\(modelID)","messages":[{"role":"user","content":"Hello from this Mac"}]}'
            """

        case .python:
            let apiKey = endpoint.requiresAuthentication
                ? "os.environ[\"OPENAI_API_KEY\"]"
                : "\"not-needed\""
            return """
            import os
            from openai import OpenAI

            client = OpenAI(
                base_url="\(endpoint.baseURL.absoluteString)",
                api_key=\(apiKey),
            )

            response = client.chat.completions.create(
                model="\(modelID)",
                messages=[{"role": "user", "content": "Hello from this Mac"}],
            )
            print(response.choices[0].message.content)
            """
        }
    }
}
