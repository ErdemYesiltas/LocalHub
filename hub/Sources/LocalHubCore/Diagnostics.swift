import Foundation
import Security

public enum DiagnosticAction: String, Sendable { case startHub, settings, integrations, workflows, devices, files }

public struct DiagnosticCheck: Sendable, Identifiable {
    public var id: String { finding.id }
    public let finding: HealthFinding
    public let code: String
    public let action: DiagnosticAction?
    public init(_ id: String, _ title: String, _ status: CheckStatus, _ detail: String, code: String, action: DiagnosticAction? = nil) {
        finding = HealthFinding(id, title, status, detail); self.code = code; self.action = action
    }
}

public struct DiagnosticReport: Sendable {
    public let checkedAt: Date
    public let checks: [DiagnosticCheck]
    public var failureCount: Int { checks.filter { $0.finding.status == .failed }.count }
    public var warningCount: Int { checks.filter { $0.finding.status == .warning }.count }

    /// Explicitly allow-listed support data; never exports raw finding details or titles.
    public var supportText: String {
        let lines = checks.enumerated().map { "\($0.offset + 1). [\($0.element.finding.status.rawValue)] \($0.element.code)" }
        return (["LocalHub diagnostics \(hubVersion)", "Checked: \(checkedAt.ISO8601Format())",
                 "System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                 "Private identifiers, addresses, device names, paths, fingerprints, prompts and tokens are excluded.", ""] + lines).joined(separator: "\n")
    }
}

extension LocalCertificate {
    public var expirationDate: Date? {
        guard let pem = try? String(contentsOf: certificate, encoding: .utf8),
              let der = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("---") }.joined()),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let field = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = field[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}

public enum HubDiagnostics {
    public static func run(core: HubCore, server: HubServer, deviceID: String? = nil, capability: Capability? = nil) async -> DiagnosticReport {
        var checks: [DiagnosticCheck] = []
        let now = Date()
        let running = await server.isRunning
        checks.append(DiagnosticCheck("hub", "Hub listener", running ? .passed : .failed,
            running ? "The HTTPS listener is running on this Mac." : "The hub is stopped. Start it before connecting a device.",
            code: running ? "hub.running" : "hub.stopped", action: running ? nil : .startHub))
        let settings: HubSettings
        do { settings = try core.store.settings() }
        catch {
            checks.append(DiagnosticCheck("settings", "Stored configuration", .failed, "The hub settings could not be read from the database.", code: "storage.settings_unreadable", action: .settings))
            return DiagnosticReport(checkedAt: now, checks: checks)
        }
        let devices = await core.authority.listDevices().filter { $0.app != PairingAuthority.playgroundApp }
        let lanHosts = PairingInvite.lanAddresses()
        let vpnHosts = settings.allowVPN ? PairingInvite.vpnAddresses() : []
        if !settings.lanEnabled {
            checks.append(DiagnosticCheck("network", "Network access", deviceID == nil && devices.isEmpty ? .info : .warning,
                "Only this Mac can connect. Enable network access to use a tablet or another computer.", code: "network.local_only", action: .settings))
        } else {
            let reachable = !lanHosts.isEmpty || !vpnHosts.isEmpty
            checks.append(DiagnosticCheck("network", "Network address", reachable ? .passed : .failed,
                reachable ? "A private LAN or permitted VPN address is available. Pair again if your device has an old address."
                    : "No private network address was found. Connect this Mac to your local network or enable your VPN network in Settings.",
                code: reachable ? "network.address_available" : "network.no_private_address", action: reachable ? nil : .settings))
        }
        if let expires = core.certificate.expirationDate {
            let days = Int(expires.timeIntervalSince(now) / 86_400)
            let status: CheckStatus = expires <= now ? .failed : days < 30 ? .warning : .passed
            checks.append(DiagnosticCheck("certificate", "Certificate validity", status,
                expires <= now ? "The certificate has expired. Paired clients will refuse it."
                    : "The certificate expires in \(days) days. Certificate rotation is not yet automated; plan a renewal and device re-pairing before expiry.",
                code: status == .passed ? "certificate.valid" : status == .warning ? "certificate.expiring" : "certificate.expired", action: status == .passed ? nil : .settings))
        } else {
            checks.append(DiagnosticCheck("certificate", "Certificate validity", .warning, "The certificate expiration date could not be read.", code: "certificate.unverified", action: .settings))
        }
        let writable = FileManager.default.isWritableFile(atPath: core.directory.path)
            && FileManager.default.isWritableFile(atPath: core.files.directory.path)
        checks.append(DiagnosticCheck("storage", "Data storage", writable ? .passed : .failed,
            writable ? "The data and file directories are writable." : "LocalHub cannot write to its data or file directory. Check its macOS file permissions.",
            code: writable ? "storage.writable" : "storage.not_writable", action: writable ? nil : .settings))
        if let free = try? core.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            checks.append(DiagnosticCheck("disk", "Available disk space", free < 1_073_741_824 ? .warning : .passed,
                "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available on the data volume.",
                code: free < 1_073_741_824 ? "storage.low_disk_space" : "storage.disk_space_available", action: free < 1_073_741_824 ? .settings : nil))
        }
        let statuses = await core.integrations.current.statuses()
        if statuses.isEmpty {
            checks.append(DiagnosticCheck("apps", "AI integrations", .warning, "No local AI apps are configured.", code: "integration.none", action: .integrations))
        }
        for status in statuses {
            let ready = status.state == "running"
            checks.append(DiagnosticCheck("app-\(status.id)", status.name, ready ? .passed : .failed,
                ready ? "The local service answered its discovery request."
                    : "This local service did not answer correctly. Open the app, enable its server and verify its configured address.",
                code: ready ? "integration.reachable" : "integration.unavailable", action: ready ? nil : .integrations))
            if ready, status.kind == ProviderKind.openai.rawValue, status.models == 0 {
                checks.append(DiagnosticCheck("models-\(status.id)", "Models in \(status.name)", .warning,
                    "The server is reachable but its model catalog is empty. Load or expose a model in the local app.", code: "models.empty_catalog", action: .integrations))
            }
            if ready, status.kind == ProviderKind.comfyui.rawValue {
                let templates = core.integrations.templates.filter { $0.integrationID == status.id }
                checks.append(DiagnosticCheck("workflows-\(status.id)", "Workflows in \(status.name)", templates.isEmpty ? .warning : .info,
                    templates.isEmpty ? "Import a workflow to enable image, audio or video generation."
                        : "\(templates.count) workflow(s) configured. Use Workflow Health to verify installed nodes and models.",
                    code: templates.isEmpty ? "workflow.none" : "workflow.health_check_available", action: .workflows))
            }
        }
        if let deviceID {
            if let device = devices.first(where: { $0.id == deviceID }) {
                checks.append(DiagnosticCheck("device", "Selected device", .passed, "\(device.name) is paired. Pairing alone does not prove it can currently reach this Mac.", code: "device.paired", action: .devices))
                if let capability {
                    let allowed = device.allows(capability.rawValue)
                    checks.append(DiagnosticCheck("permission", "Device permission", allowed ? .passed : .failed,
                        allowed ? "This device is allowed to \(capability.title.lowercased())." : "Grant “\(capability.title)” to this device under Devices.",
                        code: allowed ? "device.permission_granted" : "device.permission_missing", action: allowed ? nil : .devices))
                }
                let usage = (try? core.files.usage(deviceID: device.id)) ?? 0
                let quota = device.effectiveFileQuota(settings)
                let full = usage >= quota
                checks.append(DiagnosticCheck("quota", "Device file quota", full ? .failed : .passed,
                    "\(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file)) used of \(ByteCountFormatter.string(fromByteCount: Int64(quota), countStyle: .file)). Delete unneeded files if the quota is full.",
                    code: full ? "device.quota_full" : "device.quota_available", action: full ? .files : nil))
            } else {
                checks.append(DiagnosticCheck("device", "Selected device", .failed, "This device is no longer paired. Pair it again with a fresh QR code.", code: "device.not_paired", action: .devices))
            }
        }
        let pending = await core.permissions.open
        if !pending.isEmpty {
            checks.append(DiagnosticCheck("pending", "Permission requests", .warning, "\(pending.count) request(s) are waiting for approval in LocalHub.", code: "device.permission_pending", action: .devices))
        }
        if let capability {
            let candidates = core.integrations.list.filter { $0.kind.capabilities.contains(capability) }
            let online = candidates.filter { integration in statuses.contains { $0.id == integration.id && $0.state == "running" } }
            if online.isEmpty {
                checks.append(DiagnosticCheck("capability", capability.title, .failed, "No reachable integration can provide this capability.", code: "capability.provider_unavailable", action: .integrations))
            } else if Capability.workflowCapabilities.contains(capability) {
                let templates = core.integrations.templates.filter { t in t.capability == capability && online.contains { $0.id == t.integrationID } }
                checks.append(DiagnosticCheck("capability", capability.title, templates.isEmpty ? .failed : .info,
                    templates.isEmpty ? "No workflow is configured for this capability on a reachable integration."
                        : "A workflow is configured. Check its health to verify the installed models and nodes.",
                    code: templates.isEmpty ? "capability.workflow_missing" : "capability.workflow_configured", action: .workflows))
            } else if capability == .chat || capability == .embeddings {
                let models = (try? await core.integrations.current.chatModels()) ?? []
                let exists = models.contains { $0.capabilities.contains(capability.rawValue) }
                checks.append(DiagnosticCheck("capability", capability.title, exists ? .passed : .failed,
                    exists ? "A compatible model is exposed by a reachable local server." : "No compatible model was discovered. Load or expose the appropriate model in the local app.",
                    code: exists ? "capability.model_available" : "capability.model_missing", action: exists ? nil : .integrations))
            }
        }
        checks.append(DiagnosticCheck("route", "Connection from your other device", .info,
            "These checks run on the Mac. They cannot verify the other device's Wi-Fi, firewall or VPN route. Use the current QR code on the same network and check the device's connection error.", code: "network.remote_route_not_tested", action: .devices))
        return DiagnosticReport(checkedAt: now, checks: checks)
    }
}
