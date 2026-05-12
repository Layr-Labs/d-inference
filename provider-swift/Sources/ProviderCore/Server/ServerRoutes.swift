/// Shared Hummingbird response helpers for the standalone local server.

import Foundation
import Hummingbird

struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
}

struct OpenAIModel: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String
}

struct OpenAIModelsResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIModel]
}

struct OpenAIErrorResponse: Codable, Sendable {
    struct ErrorObject: Codable, Sendable {
        let message: String
        let type: String
    }

    let error: ErrorObject
}

struct StandaloneHeadersMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.method == .options {
            return Response(status: .noContent, headers: defaultHeaders())
        }

        var response = try await next(request, context)
        response.headers[.accessControlAllowOrigin] = "*"
        return response
    }
}

func defaultHeaders(contentType: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.accessControlAllowOrigin] = "*"
    headers[.accessControlAllowHeaders] = "accept, authorization, content-type, origin"
    headers[.accessControlAllowMethods] = "GET, POST, HEAD, OPTIONS"
    if let contentType {
        headers[.contentType] = contentType
    }
    return headers
}

func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    do {
        let data = try encoder.encode(value)
        return Response(
            status: status,
            headers: defaultHeaders(contentType: "application/json"),
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    } catch {
        return openAIErrorResponse(
            status: .internalServerError,
            message: "Failed to encode response"
        )
    }
}

func openAIErrorResponse(
    status: HTTPResponse.Status,
    message: String,
    type: String = "invalid_request_error"
) -> Response {
    let response = OpenAIErrorResponse(
        error: .init(message: message, type: type)
    )
    return jsonResponse(response, status: status)
}
