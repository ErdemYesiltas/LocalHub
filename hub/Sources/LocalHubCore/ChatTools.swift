import Foundation
import struct MCP.Tool
import enum MCP.Value
import Vapor

/// One tool call the hub made on the model's behalf, reported back as `localhub_tool_calls`.
struct ToolCallTrace: Content {
    let server: String
    let tool: String
    let arguments: String
    let is_error: Bool
}

/// Chat with MCP tools run by the hub: the client sends `mcp_servers: ["files"]`, the model sees
/// those servers' allowed tools as OpenAI functions (`files__read_file`), and the hub executes
/// the calls (allowlist + schema checked) until the model answers. Up to six rounds.
func chatWithTools(_ request: Request, body json: [String: Any], servers: [String], device: PairedDevice,
                   provider: OpenAICompatibleProvider, upstreamModel: String, mcp: MCPRegistry,
                   recorder: ChatRecorder?) async throws -> Response {
    var functions: [[String: Any]] = []
    var routes: [String: (server: String, tool: String)] = [:]
    for server in servers {
        try await request.require(scope: "mcp:\(server)")
        let tools: [Tool]
        do { tools = try await mcp.listTools(serverID: server).tools }
        catch MCPRegistryError.unknownServer { throw HubError(.notFound, "not_found", "No MCP server named \(server)") }
        catch { throw HubError(.badGateway, "upstream_error", "MCP server \(server) did not list its tools", provider: "mcp:\(server)") }
        for tool in tools {
            let name = String("\(server)__\(tool.name)".map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(64))
            routes[name] = (server, tool.name)
            let schema = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema))) ?? ["type": "object"]
            functions.append(["type": "function", "function": [
                "name": name, "description": tool.description ?? "", "parameters": schema]])
        }
    }

    let wantsStream = json["stream"] as? Bool == true
    var conversation = json
    conversation.removeValue(forKey: "mcp_servers")
    conversation["model"] = upstreamModel
    conversation["stream"] = false
    conversation["tools"] = ((json["tools"] as? [[String: Any]]) ?? []) + functions
    var messages = json["messages"] as? [[String: Any]] ?? []
    var traces: [ToolCallTrace] = []

    for _ in 0..<6 {
        conversation["messages"] = messages
        let (data, response) = try await provider.upstream.send("POST", "/v1/chat/completions",
            body: try JSONSerialization.data(withJSONObject: conversation), contentType: "application/json", timeout: 600)
        if let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { recorder?.recordToolUsage(payload) }
        guard response.statusCode == 200, var reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (reply["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            recorder?.received(status: response.statusCode)
            recorder?.append(data)
            recorder?.finish()
            return Response(status: HTTPResponseStatus(statusCode: response.statusCode), headers: ["Content-Type": "application/json"], body: .init(data: data))
        }
        let calls = message["tool_calls"] as? [[String: Any]] ?? []
        let ours = calls.filter { routes[(($0["function"] as? [String: Any])?["name"] as? String) ?? ""] != nil }
        guard !calls.isEmpty, ours.count == calls.count else {
            // A final answer, or a call to one of the client's own tools: hand it back.
            reply["localhub_tool_calls"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(traces))
            let final = try JSONSerialization.data(withJSONObject: reply)
            recorder?.received(status: 200)
            recorder?.append(final)
            recorder?.finish()
            return wantsStream ? asEventStream(reply) : Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: final))
        }
        messages.append(message)
        for call in ours {
            let function = call["function"] as? [String: Any] ?? [:]
            let route = routes[function["name"] as? String ?? ""]!
            let argumentsText = function["arguments"] as? String ?? "{}"
            var output: String
            var failed = false
            do {
                let arguments = try JSONDecoder().decode([String: Value].self, from: Data(argumentsText.utf8))
                let result = try await mcp.call(serverID: route.server, name: route.tool, arguments: arguments)
                output = result.content.map { content -> String in
                    if case .text(let text, _, _) = content { return text }
                    return "[\(String(describing: content).prefix(40))]"
                }.joined(separator: "\n")
                failed = result.isError ?? false
            } catch MCPRegistryError.invalidArguments {
                output = "Error: the arguments do not match the tool's schema"; failed = true
            } catch MCPRegistryError.deniedTool {
                output = "Error: this tool is not allowed on this Mac"; failed = true
            } catch {
                output = "Error: the tool failed (\(error.localizedDescription))"; failed = true
            }
            traces.append(ToolCallTrace(server: route.server, tool: route.tool, arguments: String(argumentsText.prefix(2000)), is_error: failed))
            messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": String(output.prefix(100_000))])
        }
    }
    recorder?.finish(error: "The model kept calling tools; stopped after 6 rounds")
    throw HubError(.badGateway, "upstream_error", "The model kept calling tools; stopped after 6 rounds")
}

/// A finished completion replayed as one SSE chunk, for clients that asked to stream.
private func asEventStream(_ reply: [String: Any]) -> Response {
    let choice = (reply["choices"] as? [[String: Any]])?.first ?? [:]
    let message = choice["message"] as? [String: Any] ?? [:]
    var chunk: [String: Any] = ["id": reply["id"] ?? "chatcmpl-localhub", "object": "chat.completion.chunk", "model": reply["model"] ?? "",
        "choices": [["index": 0, "delta": ["role": "assistant", "content": message["content"] ?? ""], "finish_reason": choice["finish_reason"] ?? "stop"]]]
    chunk["localhub_tool_calls"] = reply["localhub_tool_calls"]
    let data = (try? JSONSerialization.data(withJSONObject: chunk)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return Response(status: .ok, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
        body: .init(string: "data: \(data)\n\ndata: [DONE]\n\n"))
}
