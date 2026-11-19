import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

/// A stdio MCP server in a few lines of Python: `echo` (safe) and `delete_everything` (never allowed).
private let fakeServer = #"""
import sys, json
for line in sys.stdin:
    msg = json.loads(line)
    mid, method = msg.get("id"), msg.get("method")
    if mid is None:
        continue
    if method == "initialize":
        res = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "echo", "version": "1"}}
    elif method == "tools/list":
        res = {"tools": [
            {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
            {"name": "delete_everything", "description": "Dangerous", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call":
        res = {"content": [{"type": "text", "text": "echo: " + msg["params"]["arguments"].get("text", "")}], "isError": False}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": res}), flush=True)
"""#

final class MCPTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var config: MCPServerConfiguration!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        let script = directory.appendingPathComponent("echo_server.py")
        try fakeServer.write(to: script, atomically: true, encoding: .utf8)
        config = MCPServerConfiguration(id: "echo", executable: "/usr/bin/python3", arguments: ["-u", script.path], allowedTools: ["echo"])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testDiscoveryListsEveryToolAndValidationRejectsBadConfigs() async throws {
        let tools = try await MCPRegistry.discover(config)
        XCTAssertEqual(tools.map(\.name), ["echo", "delete_everything"])
        XCTAssertEqual(tools.first?.description, "Echo text")
        XCTAssertThrowsError(try MCPServerConfiguration(id: "x", executable: "python3").validate(), "relative command")
        XCTAssertThrowsError(try MCPServerConfiguration(id: "x", endpoint: "http://example.com/mcp").validate(), "plain http off this Mac")
        XCTAssertThrowsError(try MCPServerConfiguration(id: "x", executable: "/usr/bin/python3", endpoint: "https://a/mcp").validate())
        XCTAssertNoThrow(try MCPServerConfiguration(id: "x", endpoint: "https://tools.example.com/mcp").validate())
    }

    func testDevicesCallOnlyAllowedToolsWithValidArguments() async throws {
        let core = try HubCore(directory: directory.appendingPathComponent("state"))
        var settings = HubSettings()
        settings.mcpServers = [config]
        settings.defaultScopes = ["chat", "mcp:echo"]
        try core.store.save(settings)
        let server = HubServer(core: core)
        try await server.start(settings: settings, portOverride: 0)
        defer { Task { await server.stop() } }
        let port = await server.port
        let base = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))/v2/mcp")!
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let window = await core.authority.openWindow()
        let (paired, _) = try await client.json("POST", base.deletingLastPathComponent().appendingPathComponent("pair"), token: nil,
            body: ["code": window.code, "deviceName": "Olive", "app": "olive-studio"])
        let token = try XCTUnwrap(paired["token"] as? String)
        XCTAssertEqual(paired["scopes"] as? [String], ["chat", "mcp:echo"])

        let (servers, _) = try await client.raw("GET", base.appendingPathComponent("servers"), token: token)
        XCTAssertTrue(String(decoding: servers, as: UTF8.self).contains(#""allowedTools":["echo"]"#))
        let (tools, _) = try await client.json("GET", base.appendingPathComponent("echo/tools"), token: token)
        XCTAssertEqual((tools["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["echo"], "only allowed tools are listed")

        let (result, status) = try await client.json("POST", base.appendingPathComponent("echo/call"), token: token,
            body: ["name": "echo", "arguments": ["text": "merhaba"]])
        XCTAssertEqual(status, 200, "\(result)")
        XCTAssertEqual(((result["content"] as? [[String: Any]])?.first)?["text"] as? String, "echo: merhaba")

        let (_, denied) = try await client.json("POST", base.appendingPathComponent("echo/call"), token: token,
            body: ["name": "delete_everything", "arguments": [:]])
        XCTAssertEqual(denied, 403)
        let (_, invalid) = try await client.json("POST", base.appendingPathComponent("echo/call"), token: token,
            body: ["name": "echo", "arguments": ["text": 42]])
        XCTAssertEqual(invalid, 400, "arguments are checked against the tool's schema")

        let devices = await core.authority.listDevices()
        try await core.authority.update(devices[0].id) { $0.scopes = ["chat"] }
        let (_, forbidden) = try await client.json("GET", base.appendingPathComponent("echo/tools"), token: token)
        XCTAssertEqual(forbidden, 403, "the mcp:echo permission is required")
        await server.stop()
    }

    func testChatCallsMCPToolsOnTheModelsBehalf() async throws {
        let model = try await Application.make(.testing)
        model.get("v1", "models") { _ in Response(status: .ok, body: .init(string: #"{"data": [{"id": "m"}]}"#)) }
        model.post("v1", "chat", "completions") { request -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            if let tool = messages.last(where: { $0["role"] as? String == "tool" }) {
                return Response(status: .ok, body: .init(string: #"{"id": "c2", "model": "m", "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Tool said: \#(tool["content"] as! String)"}}]}"#))
            }
            let names = (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertEqual(names, ["echo__echo"], "only allowed tools are offered to the model")
            return Response(status: .ok, body: .init(string: #"{"id": "c1", "model": "m", "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "echo__echo", "arguments": "{\"text\": \"merhaba\"}"}}]}}]}"#))
        }
        try await model.server.start(address: .hostname("127.0.0.1", port: 0))
        let modelPort = try XCTUnwrap(model.http.server.shared.localAddress?.port)

        let core = try HubCore(directory: directory.appendingPathComponent("chat-state"))
        try core.integrations.save(ProviderConfiguration(id: "lmstudio", kind: .openai, name: "LM Studio", baseURL: "http://127.0.0.1:\(modelPort)"))
        var settings = HubSettings()
        settings.mcpServers = [config]
        settings.defaultScopes = ["chat", "mcp:echo"]
        try core.store.save(settings)
        let server = HubServer(core: core)
        try await server.start(settings: settings, portOverride: 0)
        let port = await server.port
        let base = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))")!
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let window = await core.authority.openWindow()
        let (paired, _) = try await client.json("POST", base.appendingPathComponent("v2/pair"), token: nil,
            body: ["code": window.code, "deviceName": "Olive", "app": "olive-studio"])
        let token = try XCTUnwrap(paired["token"] as? String)
        let chat = base.appendingPathComponent("v1/chat/completions")
        let body: [String: Any] = ["model": "lmstudio/m", "mcp_servers": ["echo"], "messages": [["role": "user", "content": "echo merhaba"]]]

        let (reply, status) = try await client.json("POST", chat, token: token, body: body)
        XCTAssertEqual(status, 200, "\(reply)")
        let message = ((reply["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(message, "Tool said: echo: merhaba", "the hub ran the tool and gave the result back to the model")
        let traces = try XCTUnwrap(reply["localhub_tool_calls"] as? [[String: Any]])
        XCTAssertEqual(traces.first?["tool"] as? String, "echo")
        XCTAssertEqual(traces.first?["is_error"] as? Bool, false)

        var streaming = body
        streaming["stream"] = true
        let (stream, _) = try await client.raw("POST", chat, token: token, body: streaming)
        XCTAssertTrue(String(decoding: stream, as: UTF8.self).contains("Tool said: echo: merhaba"))
        XCTAssertTrue(String(decoding: stream, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))

        let logs = try core.store.chatLogs()
        XCTAssertEqual(logs.first?.response, "Tool said: echo: merhaba", "tool chats are logged with the final answer")

        let devices = await core.authority.listDevices()
        try await core.authority.update(devices[0].id) { $0.scopes = ["chat"] }
        let (_, forbidden) = try await client.json("POST", chat, token: token, body: body)
        XCTAssertEqual(forbidden, 403)
        await server.stop()
        await model.server.shutdown(); try await model.asyncShutdown()
    }
}
