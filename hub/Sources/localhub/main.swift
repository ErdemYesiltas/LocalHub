import Foundation
import LocalHubCore

// Headless hub for development or a Mac without a logged-in UI. Shares the
// app's state directory and database; don't run both at once.
let arguments = CommandLine.arguments
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--help") {
    print("""
    localhub — serve this Mac's local AI apps to paired devices (headless)

      --state-dir <dir>    default ~/Library/Application Support/LocalHub (shared with LocalHub.app)
      --lan                listen on the local network for this run
      --port <n>           port for this run
      --advertise <host>   host to put in the QR instead of the detected LAN IP
      --legacy-qr          also print the ArtBlend Companion v1 QR
      --no-qr              print the pairing values without a QR
      --import-workflow <file>  add a ComfyUI workflow file (UI or API format; slots detected automatically), then serve
      --comfy-list         list ComfyUI's saved workflows and recent runs, then exit
      --comfy-export <name>     print a saved ComfyUI workflow converted to API format, then exit
      --comfy-run <id>     print a recent ComfyUI run's API graph (id prefix from --comfy-list), then exit
      --export-template <id>    print a workflow template's API graph, then exit
      --update-template <id> <file> [--name <name>] [--timeout <minutes>]
                           replace a template's graph (UI or API format; slots re-detected, ID kept), then exit.
                           Safe while LocalHub.app runs; the app uses the new graph after it restarts.
    Integrations and settings are edited in LocalHub.app.
    """)
    exit(0)
}

let stateDirectory = option("--state-dir").map { URL(fileURLWithPath: $0) } ?? HubCore.defaultDirectory

// Template commands open only the database: no server, and no re-attaching the app's running jobs.
if let id = option("--export-template") {
    guard let template = try HubStore.open(directory: stateDirectory).templates().first(where: { $0.id == id }) else {
        throw ConfigurationError.invalid("No workflow template \(id)")
    }
    print(template.workflow)
    exit(0)
}
if let index = arguments.firstIndex(of: "--update-template") {
    guard arguments.indices.contains(index + 2) else { throw ConfigurationError.invalid("Usage: --update-template <id> <file>") }
    let store = try HubStore.open(directory: stateDirectory)
    guard var template = try store.templates().first(where: { $0.id == arguments[index + 1] }) else {
        throw ConfigurationError.invalid("No workflow template \(arguments[index + 1])")
    }
    guard let comfy = try store.integrations().first(where: { $0.id == template.integrationID && $0.kind == .comfyui }) else {
        throw ConfigurationError.invalid("The template's ComfyUI integration \(template.integrationID) is gone")
    }
    let library = ComfyLibrary(integration: comfy)
    var converter = ComfyUIConverter(objectInfo: try await library.objectInfo())
    let json = try converter.convert(try String(contentsOf: URL(fileURLWithPath: arguments[index + 2]), encoding: .utf8))
    let detected = try WorkflowGraph(json: json).detectSlots()
    guard detected.capability == template.capability else {
        throw ConfigurationError.invalid("The new graph is \(detected.capability.title), the template is \(template.capability.title)")
    }
    template.workflow = json
    template.slots = detected.slots
    template.outputNode = detected.outputNode
    if let name = option("--name") { template.name = name }
    if let minutes = option("--timeout").flatMap(Int.init) { template.timeoutMinutes = minutes }
    try store.save(template)
    print("Updated \(comfy.id)/\(template.id) (\(template.name)): \(template.slots.map(\.kind.rawValue).joined(separator: ", "))")
    if let warning = template.unsupportedModelWarning(device: await library.deviceType()) { print("Warning: \(warning)") }
    exit(0)
}

let core = try HubCore(directory: stateDirectory)
if arguments.contains("--comfy-list") || option("--comfy-export") != nil || option("--comfy-run") != nil {
    guard let comfy = core.integrations.list.first(where: { $0.kind == .comfyui }) else {
        throw ConfigurationError.invalid("Add a ComfyUI integration first")
    }
    let library = ComfyLibrary(integration: comfy)
    if let prefix = option("--comfy-run") ?? option("--comfy-export"), option("--comfy-run") != nil || option("--comfy-export") != nil {
        let json = option("--comfy-run") != nil
            ? try await library.recentRuns().first(where: { $0.id.hasPrefix(prefix) }).map(\.workflow) ?? { throw ConfigurationError.invalid("No run \(prefix)") }()
            : try await library.savedWorkflow(prefix)
        print(json)
        let detected = try WorkflowGraph(json: json).detectSlots()
        FileHandle.standardError.write(Data("\(detected.capability.rawValue) → output \(detected.outputNode ?? "-"): \(detected.slots.map { "\($0.kind.rawValue)=\($0.node).\($0.input)" }.joined(separator: " "))\n".utf8))
    } else {
        print("Saved workflows (\(comfy.name)):")
        for name in try await library.savedWorkflows() { print("  \(name)") }
        print("Recent runs:")
        for run in try await library.recentRuns() {
            print("  \(run.id.prefix(8))  \(run.output.padding(toLength: 5, withPad: " ", startingAt: 0)) \(run.nodeCount) nodes  \(run.summary)")
        }
    }
    exit(0)
}

var settings = try core.store.settings()
if arguments.contains("--lan") { settings.lanEnabled = true }
if let port = option("--port").flatMap(Int.init) { settings.port = port }

if let path = option("--import-workflow") {
    let url = URL(fileURLWithPath: path)
    guard let comfy = core.integrations.list.first(where: { $0.kind == .comfyui }) else {
        throw ConfigurationError.invalid("Add a ComfyUI integration first")
    }
    var converter = ComfyUIConverter(objectInfo: try await ComfyLibrary(integration: comfy).objectInfo())
    let json = try converter.convert(try String(contentsOf: url, encoding: .utf8))
    let detected = try WorkflowGraph(json: json).detectSlots()
    let id = url.deletingPathExtension().lastPathComponent.lowercased()
    try core.integrations.save(WorkflowTemplate(id: id, name: id, integrationID: comfy.id, capability: detected.capability,
        workflow: json, slots: detected.slots, outputNode: detected.outputNode))
    print("Imported workflow \(comfy.id)/\(id) (\(detected.capability.title)): \(detected.slots.map(\.kind.rawValue).joined(separator: ", "))")
    if let warning = WorkflowTemplate(id: id, name: id, integrationID: comfy.id, capability: detected.capability, workflow: json,
        slots: detected.slots, outputNode: detected.outputNode).unsupportedModelWarning(device: await ComfyLibrary(integration: comfy).deviceType()) {
        print("Warning: \(warning)")
    }
}

let server = HubServer(core: core)
try await server.start(settings: settings)
let window = await core.authority.openWindow()
let address = option("--advertise").map { "https://\($0):\(settings.port)" }
    ?? core.advertisedAddress(settings: settings, port: settings.port)

print("LocalHub \(hubVersion) · \(core.identity.name) · \(address)")
print("Certificate SHA-256: \(core.certificate.fingerprint)")
print("Pairing code (3 minutes, one device): \(window.code)")
print("Integrations: \(core.integrations.list.map { "\($0.id) → \($0.baseURL)" }.joined(separator: ", "))")
let invite = core.invite(address: address, window: window)
print("Invite: \(invite)")
if !arguments.contains("--no-qr"), let modules = PairingInvite.modules(for: invite) {
    print("\nScan with a LocalHub client:")
    print(PairingInvite.terminal(modules))
}
if arguments.contains("--legacy-qr") {
    let legacy = PairingInvite.legacyURI(address: address, fingerprint: core.certificate.fingerprint, code: window.code)
    print("ArtBlend (Companion v1) invite: \(legacy)")
    if let modules = PairingInvite.modules(for: legacy) { print(PairingInvite.terminal(modules)) }
}
if !settings.lanEnabled && option("--advertise") == nil {
    print("Listening on this Mac only; start with --lan so tablets can reach it.")
}
fflush(nil)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let (stop, continuation) = AsyncStream<Void>.makeStream()
let sources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0) }
for source in sources {
    source.setEventHandler { continuation.yield() }
    source.resume()
}
for await _ in stop { break }
await server.stop()
print("\nLocalHub stopped.")
