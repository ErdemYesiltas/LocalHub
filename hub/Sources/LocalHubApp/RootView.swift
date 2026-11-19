import LocalHubCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, jobs, playground, usage, integrations, workflows, devices, profiles, conversations, files, diagnostics, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .jobs: "Jobs"
        case .playground: "Playground"
        case .usage: "Usage"
        case .integrations: "Integrations"
        case .workflows: "Workflows"
        case .devices: "Devices"
        case .profiles: "Profiles"
        case .conversations: "Conversations"
        case .files: "Files"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .jobs: "clock.arrow.circlepath"
        case .playground: "play.rectangle"
        case .usage: "chart.bar.xaxis"
        case .integrations: "puzzlepiece.extension"
        case .workflows: "point.topleft.down.to.point.bottomright.curvepath"
        case .devices: "ipad.and.iphone"
        case .profiles: "slider.horizontal.3"
        case .conversations: "bubble.left.and.text.bubble.right"
        case .files: "photo.stack"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(HubController.self) private var hub
    @State var selection: SidebarItem? = .overview
    @State private var showingSetup = false

    var body: some View {
        @Bindable var hub = hub
        NavigationSplitView {
            List(selection: $selection) {
                sidebarSection("Workspace", items: [.overview, .playground, .jobs, .conversations, .files])
                sidebarSection("Connections", items: [.integrations, .workflows, .devices])
                sidebarSection("Management", items: [.profiles, .usage, .diagnostics, .settings])
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { ServerBadge().padding(12) }
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(selection: $selection, showSetup: { showingSetup = true })
            case .jobs: JobsView()
            case .playground: PlaygroundView(navigate: { selection = $0 },
                capability: hub.playgroundIntent?.capability, providerID: hub.playgroundIntent?.providerID)
            case .usage: UsageView()
            case .integrations: IntegrationsView()
            case .workflows: WorkflowsView()
            case .devices: DevicesView()
            case .profiles: ProfilesView()
            case .conversations: ConversationsView()
            case .files: FilesView()
            case .diagnostics: DiagnosticsView()
            case .settings: SettingsView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !hub.permissionRequests.isEmpty {
                VStack(spacing: 6) {
                    ForEach(hub.permissionRequests) { PermissionBanner(request: $0) }
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }
        }
        .alert("LocalHub", isPresented: Binding(get: { hub.errorMessage != nil }, set: { if !$0 { hub.errorMessage = nil } })) {
            Button("OK") { hub.errorMessage = nil }
        } message: {
            Text(hub.errorMessage ?? "")
        }
        .sheet(isPresented: $showingSetup, onDismiss: { hub.dismissSetup() }) {
            SetupGuideView(navigate: { selection = $0 })
        }
        .onChange(of: hub.selectedJobID) { if hub.selectedJobID != nil { selection = .jobs } }
        .onChange(of: hub.requestedSection) {
            if let destination = hub.requestedSection { selection = destination; hub.requestedSection = nil }
        }
        .task {
            guard !CommandLine.arguments.contains("--snapshot") else { return }
            await hub.refreshDevices()
            if !hub.setupDismissed && !hub.hasCompletedPlaygroundRun && hub.devices.isEmpty { showingSetup = true }
        }
    }

    private func sidebarSection(_ title: String, items: [SidebarItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                HStack {
                    Image(systemName: item.symbol).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.secondary).frame(width: 22)
                    Text(item.title)
                    Spacer(minLength: 4)
                    let count = item == .jobs ? hub.activeJobs.count : item == .devices ? hub.permissionRequests.count : 0
                    if count > 0 {
                        Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .accessibilityLabel("\(count) \(item == .jobs ? "active jobs" : "permission requests")")
                    }
                }
                .tag(item)
            }
        }
    }
}

struct ServerBadge: View {
    @Environment(HubController.self) private var hub

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch hub.serverState {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }
    private var title: String {
        switch hub.serverState {
        case .running: "Hub running"
        case .starting: "Starting…"
        case .stopped: "Hub stopped"
        case .failed: "Hub failed"
        }
    }
    private var subtitle: String {
        if case .failed(let reason) = hub.serverState { return reason }
        return hub.address.replacingOccurrences(of: "https://", with: "")
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3))
    }
}

extension ProviderStatus {
    var color: Color {
        switch state {
        case "running": .green
        case "unreachable": .gray
        default: .orange
        }
    }
    var label: String {
        switch state {
        case "running": models.map { "Running · \($0) model\($0 == 1 ? "" : "s")" } ?? detail.map { "Running · \($0)" } ?? "Running"
        case "unreachable": "Not running"
        default: detail ?? "Error"
        }
    }
}

extension ProviderKind {
    var title: String {
        switch self {
        case .openai: "OpenAI-compatible"
        case .comfyui: "ComfyUI"
        case .whisper: "Whisper (transcription)"
        }
    }
    var symbol: String {
        switch self {
        case .openai: "text.bubble"
        case .comfyui: "photo.on.rectangle.angled"
        case .whisper: "waveform"
        }
    }
}

struct PermissionBanner: View {
    @Environment(HubController.self) private var hub
    let request: PermissionRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("**\(request.deviceName)** (\(request.app)) asks to **\(request.title)**.")
            Spacer()
            Button("Deny") { hub.answer(request, allow: false) }
            Button("Allow") { hub.answer(request, allow: true) }.buttonStyle(.borderedProminent)
        }
    }
}
