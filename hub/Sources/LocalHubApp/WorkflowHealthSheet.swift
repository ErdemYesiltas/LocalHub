import AppKit
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

extension CheckStatus {
    var symbol: String {
        switch self { case .passed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle" }
    }
    var color: Color {
        switch self { case .passed: .green; case .failed: .red; case .warning: .orange; case .info: .secondary }
    }
}

struct HealthFindingRow: View {
    let finding: HealthFinding
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.status.symbol).foregroundStyle(finding.status.color).frame(width: 18)
                .accessibilityLabel(finding.status.rawValue)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.callout.weight(.semibold))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkflowHealthSheet: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let template: WorkflowTemplate
    @State private var report: WorkflowHealthReport?
    @State private var checking = false
    @State private var testing = false
    @State private var prompt = "A small red cube on a clean white background"
    @State private var inputURL: URL?
    @State private var error: String?

    init(template: WorkflowTemplate, initialReport: WorkflowHealthReport? = nil) {
        self.template = template
        _report = State(initialValue: initialReport)
    }

    private var requiredInput: SlotKind? { template.capability.requiredInput ?? (template.capability == .model3DCreate ? .image : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Workflow Health", systemImage: "stethoscope").font(.title2.weight(.semibold))
                    Text(template.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(testing)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if checking { HStack { ProgressView().controlSize(.small); Text("Checking installed nodes and models…").font(.callout) } }
                    if let report {
                        HubCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(report.hasErrors ? "Needs attention" : report.warningCount > 0 ? "Checks passed with warnings" : "Catalog checks passed",
                                      systemImage: report.hasErrors ? "exclamationmark.triangle" : "checkmark.shield")
                                    .font(.headline).foregroundStyle(report.hasErrors ? Color.orange : Color.green)
                                Text("v\(report.workflowVersion.prefix(12)) · Checked \(report.checkedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(report.findings) { HealthFindingRow(finding: $0) }
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                    Divider()
                    Text("Test this workflow").font(.headline)
                    TextField("Test prompt", text: $prompt, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    if let requiredInput {
                        HStack {
                            Text(inputURL?.lastPathComponent ?? "Choose \(requiredInput.title.lowercased())").font(.caption).lineLimit(1)
                            Spacer()
                            Button("Choose File…") { choose(requiredInput) }
                        }
                    }
                    Text(template.capability == .imageCreate
                         ? "Test requests use 4 steps and 512 × 512 where mapped. A test creates a real job and output files."
                         : "A test uses the workflow's generation defaults and local compute. Long audio/video workflows may take several minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !hub.isRunning { Button("Start Hub") { Task { await hub.start() } }.disabled(hub.serverState == .starting) }
                }
            }
            HStack {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await check() } }.disabled(checking || testing)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Run Test", systemImage: "play.fill") { runTest() }.buttonStyle(.borderedProminent)
                    .disabled(checking || testing || report == nil || report?.hasErrors == true || !hub.isRunning
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (requiredInput != nil && inputURL == nil))
            }
        }
        .padding(24).frame(width: 620, height: 680)
        .interactiveDismissDisabled(testing)
        .task { if report == nil { await check() } }
    }

    private func check() async {
        checking = true; error = nil; report = nil
        defer { checking = false }
        guard let integration = hub.integrations.first(where: { $0.id == template.integrationID && $0.kind == .comfyui }) else {
            error = "Choose an available ComfyUI integration, then check again."
            return
        }
        report = await WorkflowInspector.check(template, integration: integration)
    }

    private func choose(_ kind: SlotKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind == .audio ? [.audio] : kind == .video ? [.movie] : [.png, .jpeg, .webP]
        if panel.runModal() == .OK { inputURL = panel.url }
    }

    private func runTest() {
        testing = true; error = nil
        Task {
            defer { testing = false }
            do {
                let input = try inputURL.map { JobInput(data: try Data(contentsOf: $0), filename: $0.lastPathComponent) }
                _ = try await hub.testWorkflow(template, prompt: prompt, input: input)
                dismiss()
            } catch { self.error = HubController.describe(error) }
        }
    }
}
