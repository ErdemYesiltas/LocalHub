import LocalHubCore
import SwiftUI

struct OverviewView: View {
    @Environment(HubController.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SidebarItem?
    var showSetup: () -> Void = {}
    @State private var connectionDetails = false
    @State private var report: UsageReport?

    private var recentJobs: [HubJob] {
        hub.activeJobs + hub.jobs.filter { $0.status.isFinished }.prefix(max(0, 4 - hub.activeJobs.count))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                serverCard
                if !hub.hasCompletedPlaygroundRun && hub.devices.isEmpty {
                    HubCard {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Make your first connection").font(.headline)
                                Text("Connect a local app, try a prompt, then pair a device.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Set Up LocalHub", action: showSetup).buttonStyle(.borderedProminent)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { stats }.frame(minWidth: 676)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { stats }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Your AI apps", action: "Manage Integrations") { selection = .integrations }
                    if hub.integrations.isEmpty {
                        HubCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Connect LM Studio, Ollama or ComfyUI to get started.", systemImage: "puzzlepiece.extension")
                                    .foregroundStyle(.secondary)
                                Button("Add an Integration") { selection = .integrations }
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(hub.integrations) { integration in
                                IntegrationCard(integration: integration, status: hub.statuses[integration.id],
                                    capabilities: hub.capabilities(for: integration), hubRunning: hub.isRunning,
                                    manage: { selection = .integrations },
                                    tryIt: {
                                        let capabilities = hub.capabilities(for: integration)
                                        if integration.kind == .comfyui && capabilities.isEmpty { selection = .workflows }
                                        else if let capability = capabilities.first {
                                            hub.playgroundIntent = PlaygroundIntent(capability: capability, providerID: integration.id)
                                            selection = .playground
                                        } else { selection = .integrations }
                                    })
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Activity", action: "All Jobs") { selection = .jobs }
                    HubCard {
                        if recentJobs.isEmpty {
                            HStack {
                                Label("Your next idea starts here.", systemImage: "play.rectangle")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Try Playground") { selection = .playground }
                            }
                        } else {
                            VStack(spacing: 12) {
                                ForEach(recentJobs.prefix(6)) { JobRow(job: $0) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Devices", action: "Manage Devices") { selection = .devices }
                    HubCard {
                        if hub.devices.isEmpty {
                            HStack {
                                Text("Bring your local AI to a tablet or another computer.").foregroundStyle(.secondary)
                                Spacer()
                                Button("Pair a Device", systemImage: "qrcode") { openWindow(id: "pair") }
                            }
                        } else {
                            VStack(spacing: 12) { ForEach(hub.devices.prefix(5)) { DeviceSummaryRow(device: $0) } }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem { Button("Diagnostics", systemImage: "stethoscope") { selection = .diagnostics } }
            ToolbarItem { Button("Setup Guide", systemImage: "checklist", action: showSetup) }
            ToolbarItem { Button("Pair a Device", systemImage: "qrcode") { openWindow(id: "pair") } }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }.disabled(hub.loadingModels)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func refresh() async {
        report = hub.usage(days: 1)
        await hub.refreshStatuses()
        await hub.refreshModels()
        await hub.refreshComfyDevices()
    }

    private var stats: some View {
        Group {
            DashboardStat(title: "Ready capabilities", value: "\(hub.readyCapabilities.count)", symbol: "sparkles",
                          detail: hub.isRunning ? "Across your local apps" : "Start the hub to use AI")
            DashboardStat(title: "Active jobs", value: "\(hub.activeJobs.count)", symbol: "clock.arrow.circlepath",
                          detail: "\(hub.activeJobs.filter { $0.status == .queued }.count) waiting in queue")
            DashboardStat(title: "Paired devices", value: "\(hub.devices.count)", symbol: "ipad.and.iphone",
                          detail: hub.settings.lanEnabled ? "Network access enabled" : "Network access off")
            DashboardStat(title: "Recorded requests", value: report.map { "\($0.totalRequests)" } ?? "—", symbol: "chart.bar.xaxis",
                          detail: "Last 24h · without chat content")
        }
    }

    private var serverCard: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 28)).foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hub.core.identity.name).font(.title2.weight(.semibold))
                        Text(hub.isRunning ? "Your local AI is one connection away." : "Start your hub to connect your AI apps.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch hub.serverState {
                    case .running:
                        Button("Stop Hub") { Task { await hub.stop() } }
                    case .starting:
                        ProgressView().controlSize(.small)
                        Text("Starting…").font(.caption).foregroundStyle(.secondary)
                    case .stopped, .failed:
                        Button("Start Hub", systemImage: "play.fill") { Task { await hub.start() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                HStack(spacing: 8) {
                    StatusPill(title: hub.isRunning ? "Hub running" : hub.serverState == .starting ? "Starting" : "Hub offline",
                               symbol: hub.isRunning ? "checkmark.circle.fill" : "circle", color: hub.isRunning ? .green : .secondary)
                    StatusPill(title: hub.settings.lanEnabled ? "Network enabled" : "This Mac only",
                               symbol: hub.settings.lanEnabled ? "wifi" : "desktopcomputer", color: .secondary)
                    Spacer()
                    Button("Try a Prompt", systemImage: "play.rectangle") { selection = .playground }
                        .disabled(!hub.isRunning)
                }
                if case .failed(let reason) = hub.serverState {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    Button("Open Network Settings") { selection = .settings }.buttonStyle(.link)
                }
                DisclosureGroup("Connection details", isExpanded: $connectionDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Address", value: hub.address)
                        LabeledContent("Certificate SHA-256") {
                            Text(hub.core.certificate.fingerprint).font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if !hub.settings.lanEnabled {
                            Button("Enable network access in Settings") { selection = .settings }.buttonStyle(.link)
                        }
                    }
                    .font(.caption).textSelection(.enabled).padding(.top, 8)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct IntegrationCard: View {
    let integration: ProviderConfiguration
    let status: ProviderStatus?
    var capabilities: [Capability] = []
    var hubRunning = false
    var manage: () -> Void = {}
    var tryIt: () -> Void = {}

    var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: integration.kind.symbol).foregroundStyle(.tint)
                    Text(integration.name).font(.body.weight(.semibold))
                    Spacer()
                    StatusDot(color: status?.color ?? .gray)
                }
                Text(status?.label ?? "Checking…").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(capabilityDescription).font(.caption).foregroundStyle(.secondary)
                    .frame(minHeight: 30, alignment: .top)
                HStack {
                    Button("Manage", action: manage).buttonStyle(.link)
                    Spacer()
                    if status?.state == "running" && hubRunning {
                        Button(integration.kind == .comfyui && capabilities.isEmpty ? "Set Up Workflow" : "Try It",
                               action: tryIt).controlSize(.small)
                    }
                }
            }
        }
    }

    private var capabilityDescription: String {
        if !hubRunning { return "Start the hub to use this app." }
        if status?.state != "running" { return "Open the app and enable its local server." }
        if !capabilities.isEmpty { return capabilities.map(\.title).joined(separator: " · ") }
        return integration.kind == .comfyui ? "Import a workflow to enable generation." : "Load a model, then refresh to get started."
    }
}

struct DeviceSummaryRow: View {
    let device: PairedDevice
    var body: some View {
        HStack {
            Image(systemName: device.symbol).frame(width: 22)
            Text(device.name)
            Text(device.app).foregroundStyle(.secondary)
            Spacer()
            Text(device.lastSeenText).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension PairedDevice {
    var symbol: String {
        switch app {
        case "artblend": "ipad.landscape"
        case "olive-studio": "macbook"
        default: "desktopcomputer"
        }
    }
    var lastSeenText: String {
        guard let lastSeenAt else { return "Never used" }
        return "Seen " + lastSeenAt.formatted(.relative(presentation: .named))
    }
}
