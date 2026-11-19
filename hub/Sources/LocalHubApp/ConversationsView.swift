import AppKit
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

struct ConversationsView: View {
    @Environment(HubController.self) private var hub
    @State private var selection: ChatLog.ID?
    @State private var confirmDeleteAll = false

    private var selected: ChatLog? { hub.chatLogs.first { $0.id == selection } }

    var body: some View {
        @Bindable var hub = hub
        HSplitView {
            List(hub.chatLogs, selection: $selection) { log in
                ChatLogRow(log: log).tag(log.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { hub.deleteChatLog(log); if selection == log.id { selection = nil } }
                    }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            .overlay {
                if hub.chatLogs.isEmpty {
                    ContentUnavailableView(hub.chatSearch.isEmpty ? "No conversations" : "No matches", systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(hub.chatSearch.isEmpty
                            ? "Chats from paired devices appear here for \(hub.settings.retentionDays) days."
                            : "Nothing matches “\(hub.chatSearch)”."))
                }
            }
            Group {
                if let selected { ChatLogDetail(log: selected) }
                else { ContentUnavailableView("Select a conversation", systemImage: "text.bubble") }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Conversations")
        .navigationSubtitle("\(hub.chatLogs.count) shown · kept \(hub.settings.retentionDays) days")
        .searchable(text: $hub.chatSearch, prompt: "Search prompts and replies")
        .onChange(of: hub.chatSearch) { hub.refreshChatLogs() }
        .toolbar {
            ToolbarItem {
                Picker("Device", selection: Binding(get: { hub.chatDevice ?? "" }, set: { hub.chatDevice = $0.isEmpty ? nil : $0; hub.refreshChatLogs() })) {
                    Text("All devices").tag("")
                    ForEach(hub.devices) { Text($0.name).tag($0.id) }
                }
            }
            ToolbarItem {
                Button("Export…", systemImage: "square.and.arrow.up") { export() }.disabled(hub.chatLogs.isEmpty)
            }
            ToolbarItem {
                Button("Delete Shown…", systemImage: "trash") { confirmDeleteAll = true }.disabled(hub.chatLogs.isEmpty)
            }
        }
        .confirmationDialog("Delete \(hub.chatLogs.count) conversation\(hub.chatLogs.count == 1 ? "" : "s")?", isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) { hub.deleteShownChatLogs(); selection = nil }
        } message: {
            Text("Only the conversations currently shown are deleted. This can't be undone.")
        }
        .task {
            while !Task.isCancelled {
                hub.refreshChatLogs()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "localhub-conversations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        hub.exportChatLogs(to: url)
    }
}

struct ChatLogRow: View {
    @Environment(HubController.self) private var hub
    let log: ChatLog

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(log.decodedMessages.last { $0.role == "user" }?.text ?? log.prompt)
                    .lineLimit(2).font(.body)
                Spacer(minLength: 4)
                if log.status != "completed" {
                    Image(systemName: log.status == "error" ? "exclamationmark.triangle.fill" : "scissors")
                        .foregroundStyle(log.status == "error" ? .red : .orange).help(log.error ?? log.status)
                }
            }
            HStack(spacing: 4) {
                Text(log.deviceName)
                Text("·")
                Text(log.model).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(log.createdAt.formatted(.relative(presentation: .named)))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct ChatLogDetail: View {
    let log: ChatLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(log.decodedMessages) { MessageBubble(role: $0.role, text: $0.text) }
                if !log.reasoning.isEmpty {
                    DisclosureGroup("Thinking (\(log.reasoning.count) characters)") {
                        Text(log.reasoning).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    .font(.caption)
                }
                if !log.response.isEmpty { MessageBubble(role: "assistant", text: log.response) }
                if let error = log.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                } else if log.status == "interrupted" {
                    Label("The device stopped reading before the reply finished.", systemImage: "scissors")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            .padding(20)
            .textSelection(.enabled)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(log.model).font(.headline.monospaced())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Device").foregroundStyle(.secondary); Text("\(log.deviceName) (\(log.app))") }
                GridRow { Text("When").foregroundStyle(.secondary); Text(log.createdAt.formatted(date: .abbreviated, time: .standard)) }
                GridRow {
                    Text("Took").foregroundStyle(.secondary)
                    Text(Duration.milliseconds(log.durationMs).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))
                        + (log.stream ? " · streamed" : ""))
                }
                if log.promptTokens != nil || log.completionTokens != nil {
                    GridRow { Text("Tokens").foregroundStyle(.secondary); Text("\(log.promptTokens ?? 0) in · \(log.completionTokens ?? 0) out") }
                }
                if let reason = log.finishReason {
                    GridRow { Text("Finished").foregroundStyle(.secondary); Text(reason) }
                }
            }
            .font(.caption)
            Divider().padding(.top, 4)
        }
    }
}

struct MessageBubble: View {
    let role: String
    let text: String

    var body: some View {
        HStack {
            if role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(role.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(text.isEmpty ? "—" : text)
                    .font(role == "system" ? .callout.italic() : .body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            if role != "user" { Spacer(minLength: 60) }
        }
    }

    private var background: AnyShapeStyle {
        switch role {
        case "user": AnyShapeStyle(Color.accentColor.opacity(0.15))
        case "system": AnyShapeStyle(Color.secondary.opacity(0.08))
        default: AnyShapeStyle(.background.secondary)
        }
    }
}
