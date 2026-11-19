import Foundation
import MCP
import JSONSchema

public enum MCPRegistryError: Error { case unknownServer, invalidConfiguration, deniedTool, tooManyTools, invalidArguments }

public struct MCPToolsResponse: Codable, Sendable {
    let tools: [Tool]
}

public struct MCPCallResponse: Codable, Sendable {
    let content: [Tool.Content]
    let isError: Bool?
}

public actor MCPRegistry {
    private struct Connection: Sendable {
        let client: MCP.Client
        let process: Process?
        let input: Pipe?
        let output: Pipe?
    }
    private let configurations: [MCPServerConfiguration]
    private var connections: [String: Connection] = [:]
    private var connecting: [String: Task<Connection, Error>] = [:]

    public init(configurations: [MCPServerConfiguration]) { self.configurations = configurations }

    func servers() -> [MCPServerConfiguration] { configurations }

    func listTools(serverID: String) async throws -> MCPToolsResponse {
        let config = try configuration(serverID)
        return MCPToolsResponse(tools: try await fetchTools(config).filter { config.allowedTools.contains($0.name) })
    }

    /// Every tool a server offers, ignoring the allowlist: for the app's MCP editor only.
    public static func discover(_ config: MCPServerConfiguration) async throws -> [(name: String, description: String)] {
        try config.validate()
        let registry = MCPRegistry(configurations: [config])
        do {
            let tools = try await registry.fetchTools(config)
            await registry.shutdown()
            return tools.map { ($0.name, $0.description ?? "") }
        } catch {
            await registry.shutdown()
            throw error
        }
    }

    private func fetchTools(_ config: MCPServerConfiguration) async throws -> [Tool] {
        let connection = try await connection(config)
        var cursor: String?
        var tools: [Tool] = []
        var pages = 0
        repeat {
            pages += 1
            guard pages <= 100 else { throw MCPRegistryError.tooManyTools }
            let request: MCP.Request<ListTools>
            if let cursor { request = ListTools.request(.init(cursor: cursor)) }
            else { request = ListTools.request(.init()) }
            let context = try await connection.client.send(request)
            let result = try await awaitResult(context, client: connection.client)
            tools += result.tools
            cursor = result.nextCursor
            guard tools.count <= 1000 else { throw MCPRegistryError.tooManyTools }
        } while cursor != nil
        return tools
    }

    func call(serverID: String, name: String, arguments: [String: Value]) async throws -> MCPCallResponse {
        let config = try configuration(serverID)
        guard config.allowedTools.contains(name) else { throw MCPRegistryError.deniedTool }
        let discovered = try await listTools(serverID: serverID)
        guard let tool = discovered.tools.first(where: { $0.name == name }) else { throw MCPRegistryError.deniedTool }
        let schemaText = String(decoding: try JSONEncoder().encode(tool.inputSchema), as: UTF8.self)
        let argumentsText = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        let schema = try Schema(instance: schemaText)
        let validation = try schema.validate(instance: argumentsText)
        guard validation.isValid else { throw MCPRegistryError.invalidArguments }
        let connection = try await connection(config)
        let context: RequestContext<CallTool.Result> = try await connection.client.callTool(name: name, arguments: arguments)
        let result = try await awaitResult(context, client: connection.client)
        return MCPCallResponse(content: result.content, isError: result.isError)
    }

    private func configuration(_ id: String) throws -> MCPServerConfiguration {
        guard let config = configurations.first(where: { $0.id == id }) else { throw MCPRegistryError.unknownServer }
        return config
    }

    private func awaitResult<T: Sendable & Decodable>(_ context: RequestContext<T>, client: MCP.Client) async throws -> T {
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            try await client.cancelRequest(context.requestID, reason: "LocalHub request deadline")
        }
        defer { timeout.cancel() }
        return try await context.value
    }

    private func connection(_ config: MCPServerConfiguration) async throws -> Connection {
        if let result = connections[config.id] { return result }
        if let pending = connecting[config.id] { return try await pending.value }
        let task = Task { try await self.open(config) }
        connecting[config.id] = task
        defer { connecting.removeValue(forKey: config.id) }
        let result = try await task.value
        connections[config.id] = result
        return result
    }

    private func open(_ config: MCPServerConfiguration) async throws -> Connection {
        let client = MCP.Client(name: "LocalHub", version: "0.1.0", configuration: .strict)
        let transport: any Transport
        let process: Process?
        let input: Pipe?
        let output: Pipe?
        if let endpoint = config.endpoint {
            guard config.executable == nil, let url = URL(string: endpoint),
                  ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else {
                throw MCPRegistryError.invalidConfiguration
            }
            transport = HTTPClientTransport(endpoint: url)
            process = nil; input = nil; output = nil
        } else if let executable = config.executable, executable.hasPrefix("/") {
            let child = Process(), toServer = Pipe(), fromServer = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = config.arguments ?? []
            child.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            if let directory = config.workingDirectory { child.currentDirectoryURL = URL(fileURLWithPath: directory) }
            child.standardInput = toServer; child.standardOutput = fromServer
            child.standardError = FileHandle.nullDevice
            try child.run()
            transport = StdioTransport(input: .init(rawValue: fromServer.fileHandleForReading.fileDescriptor),
                output: .init(rawValue: toServer.fileHandleForWriting.fileDescriptor))
            process = child; input = toServer; output = fromServer
        } else { throw MCPRegistryError.invalidConfiguration }
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            await client.disconnect()
            if let process, process.isRunning { process.terminate() }
        }
        defer { timeout.cancel() }
        do {
            _ = try await client.connect(transport: transport)
            return Connection(client: client, process: process, input: input, output: output)
        } catch {
            await client.disconnect()
            if let process, process.isRunning { process.terminate() }
            throw error
        }
    }

    public func shutdown() async {
        for task in connecting.values { task.cancel() }
        for connection in connections.values {
            await connection.client.disconnect()
            if let process = connection.process, process.isRunning { process.terminate() }
        }
        connections.removeAll()
    }
}
