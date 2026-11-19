import Foundation
import Network

public struct DiscoveredHub: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Advertised fingerprint; only picks the right hub. Trust stays with the pin you stored.
    public let fingerprint: String
    public let host: String
    public let port: Int
}

/// Finds LocalHub instances on the local network via Bonjour (`_localhub._tcp`).
public func discoverHubs(timeout: Duration = .seconds(2)) async -> [DiscoveredHub] {
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_localhub._tcp", domain: nil), using: .tcp)
    let found = OSAllocatedUnfairLockBox<[NWBrowser.Result]>([])
    browser.browseResultsChangedHandler = { results, _ in found.set(Array(results)) }
    browser.start(queue: .global())
    try? await Task.sleep(for: timeout)
    browser.cancel()

    var hubs: [String: DiscoveredHub] = [:]
    for result in found.get() {
        guard case .bonjour(let txt) = result.metadata, txt["v"] == "2", let id = txt["id"],
              let fp = txt["fp"].flatMap({ try? normalizeFingerprint($0) }), hubs[id] == nil,
              case .service(let name, _, _, _) = result.endpoint,
              let (host, port) = await resolve(result.endpoint) else { continue }
        hubs[id] = DiscoveredHub(id: id, name: txt["n"] ?? name, fingerprint: fp, host: host, port: port)
    }
    return Array(hubs.values)
}

/// A Bonjour service endpoint to an IP and port, by opening (and dropping) a TCP connection.
private func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
    let parameters = NWParameters.tcp
    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
    let connection = NWConnection(to: endpoint, using: parameters)
    let result = OSAllocatedUnfairLockBox<(String, Int)?>(nil)
    return await withCheckedContinuation { continuation in
        let done = OSAllocatedUnfairLockBox(false)
        let finish: @Sendable () -> Void = {
            guard !done.swap(true) else { return }
            connection.cancel()
            continuation.resume(returning: result.get())
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    var text = "\(host)"
                    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                    result.set((text, Int(port.rawValue)))
                }
                finish()
            case .failed, .cancelled: finish()
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish() }
    }
}

final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func swap(_ new: Value) -> Value { lock.withLock { let old = value; value = new; return old } }
}
