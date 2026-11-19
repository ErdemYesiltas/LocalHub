import Foundation
import Vapor

/// Errors rendered as `{"error": {"code", "message", "provider"?}}` — the
/// OpenAI error shape, so OpenAI SDKs surface `message` unchanged.
public struct HubError: AbortError, Sendable {
    public let status: HTTPResponseStatus
    public let code: String
    public let message: String
    public var provider: String?

    public init(_ status: HTTPResponseStatus, _ code: String, _ message: String, provider: String? = nil) {
        self.status = status; self.code = code; self.message = message; self.provider = provider
    }
    public var reason: String { message }
}

struct ErrorBody: Content {
    struct Detail: Content { let code: String; let message: String; let provider: String? }
    let error: Detail
}

struct HubErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            let detail: ErrorBody.Detail
            let status: HTTPResponseStatus
            switch error {
            case let hub as HubError:
                status = hub.status
                detail = .init(code: hub.code, message: hub.message, provider: hub.provider)
            case let abort as any AbortError:
                status = abort.status
                detail = .init(code: Self.code(for: abort.status), message: abort.reason, provider: nil)
            case is DecodingError:
                status = .badRequest
                detail = .init(code: "bad_request", message: "Malformed request body", provider: nil)
            default:
                request.logger.report(error: error)
                status = .internalServerError
                detail = .init(code: "internal_error", message: "Something went wrong", provider: nil)
            }
            let response = Response(status: status)
            try response.content.encode(ErrorBody(error: detail))
            return response
        }
    }

    static func code(for status: HTTPResponseStatus) -> String {
        switch status {
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .notFound: "not_found"
        case .payloadTooLarge: "payload_too_large"
        case .tooManyRequests: "too_many_attempts"
        case .gone: "pairing_closed"
        default: status.code < 500 ? "bad_request" : "upstream_error"
        }
    }
}

/// One configured local app. Only fixed paths are ever appended; clients never
/// supply a host, scheme or path prefix.
struct Upstream: Sendable {
    let provider: ProviderConfiguration
    static let responseLimit = 16 * 1024 * 1024
    static let streamLimit = 64 * 1024 * 1024

    func url(_ path: String, query: String? = nil) throws -> URL {
        guard var components = URLComponents(string: provider.baseURL) else { throw Abort(.internalServerError) }
        let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Paths are fixed by the hub; a few (ComfyUI userdata) carry %-escapes that must survive as-is.
        components.percentEncodedPath = (base.isEmpty ? "" : "/" + base)
            + (path.contains("%") ? path : (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
        components.percentEncodedQuery = query
        guard let url = components.url else { throw Abort(.badRequest) }
        return url
    }

    func unavailable(_ error: any Error) -> HubError {
        let timedOut = (error as? URLError)?.code == .timedOut
        return HubError(timedOut ? .gatewayTimeout : .serviceUnavailable,
            timedOut ? "provider_timeout" : "provider_unavailable",
            timedOut ? "\(provider.name) did not answer in time"
                     : "\(provider.name) is not running on this Mac (\(provider.baseURL))",
            provider: provider.id)
    }

    /// Small JSON GET used for discovery and model listing.
    func getJSON<T: Decodable>(_ path: String, as type: T.Type, timeout: TimeInterval = 5) async throws -> T {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: URLRequest(url: try url(path), timeoutInterval: timeout)) }
        catch { throw unavailable(error) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HubError(.badGateway, "upstream_error", "\(provider.name) answered with an error", provider: provider.id)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HubError(.badGateway, "upstream_error", "\(provider.name) sent an unexpected response", provider: provider.id) }
    }

    /// A hub-originated request (jobs), with the same error mapping and size limit as forwarding.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String? = nil, timeout: TimeInterval = 30, limit: Int = responseLimit) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: try url(path, query: components.percentEncodedQuery), timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw unavailable(error) }
        guard let http = response as? HTTPURLResponse else { throw Abort(.badGateway) }
        guard data.count <= limit else {
            throw HubError(.badGateway, "response_too_large", "\(provider.name) response exceeds \(limit / 1_048_576) MiB", provider: provider.id)
        }
        return (data, http)
    }

    /// Forwards to a fixed path. `text/event-stream` responses are streamed
    /// line by line; dropping the client connection cancels the upstream request,
    /// which stops generation in LM Studio/Ollama.
    func forward(_ request: Request, path: String, body: Data? = nil, recorder: ChatRecorder? = nil) async throws -> Response {
        var outgoing = URLRequest(url: try url(path, query: request.url.query), timeoutInterval: 120)
        outgoing.httpMethod = request.method.rawValue
        outgoing.setValue(request.headers.first(name: .contentType), forHTTPHeaderField: "Content-Type")
        outgoing.setValue(request.headers.first(name: .accept) ?? "application/json, */*", forHTTPHeaderField: "Accept")
        outgoing.httpBody = body ?? request.body.data.map { Data($0.readableBytesView) }
        let session = Self.session()
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: outgoing) }
        catch { session.invalidateAndCancel(); throw unavailable(error) }
        guard let http = response as? HTTPURLResponse else { session.invalidateAndCancel(); throw Abort(.badGateway) }

        var headers = HTTPHeaders()
        let type = http.value(forHTTPHeaderField: "Content-Type")
        if let type { headers.add(name: .contentType, value: type) }
        let status = HTTPResponseStatus(statusCode: http.statusCode)
        recorder?.received(status: http.statusCode, streaming: type?.hasPrefix("text/event-stream") == true)

        guard type?.hasPrefix("text/event-stream") == true else {
            defer { session.invalidateAndCancel() }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.responseLimit else {
                    throw HubError(.badGateway, "response_too_large", "\(provider.name) response exceeds 16 MiB", provider: provider.id)
                }
                data.append(byte)
            }
            recorder?.append(data)
            recorder?.finish()
            return Response(status: status, headers: headers, body: .init(data: data))
        }

        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        let stream = UncheckedSendable(value: bytes)
        return Response(status: status, headers: headers, body: .init(managedAsyncStream: { writer in
            defer { session.invalidateAndCancel() }
            var buffer = ByteBuffer()
            var total = 0
            do {
                for try await byte in stream.value {
                    total += 1
                    guard total <= Self.streamLimit else { break }
                    buffer.writeInteger(byte)
                    if byte == 0x0A || buffer.readableBytes >= 8192 {
                        recorder?.append(Data(buffer.readableBytesView))
                        try await writer.writeBuffer(buffer)
                        buffer.clear()
                    }
                }
                if buffer.readableBytes > 0 {
                    recorder?.append(Data(buffer.readableBytesView))
                    try await writer.writeBuffer(buffer)
                }
                recorder?.finish()
            } catch {
                stream.value.task.cancel()
                recorder?.finish(interrupted: true)
                throw error
            }
        }))
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}

struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
