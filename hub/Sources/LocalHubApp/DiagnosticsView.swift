import AppKit
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Environment(HubController.self) private var hub
    @State private var deviceID = ""
    @State private var capability = ""
    @State private var refreshID = UUID()
    @State private var report: DiagnosticReport?
    @State private var checking = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Find the missing connection", systemImage: "stethoscope").font(.title2.weight(.semibold))
                    Text("Check this Mac, its local AI apps and a device's permissions. Nothing is changed by a check.")
                        .foregroundStyle(.secondary)
                }
                HubCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Device", selection: $deviceID) {
                            Text("All devices / this Mac").tag("")
                            ForEach(hub.devices) { Text($0.name).tag($0.id) }
                            if !deviceID.isEmpty && !hub.devices.contains(where: { $0.id == deviceID }) { Text("Removed device").tag(deviceID) }
                        }
                        Picker("Capability", selection: $capability) {
                            Text("General connection check").tag("")
                            ForEach(Capability.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                }
                if checking { HStack { ProgressView().controlSize(.small); Text("Checking connections and configuration…").foregroundStyle(.secondary) } }
                if let report {
                    HubCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(report.failureCount > 0 ? "\(report.failureCount) issue(s) need attention" : "Mac checks completed")
                                .font(.headline)
                            Text("\(report.warningCount) warning(s) · Checked \(report.checkedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("A successful Mac check does not prove another device can reach it. Follow the network guidance below if connection still fails.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(report.checks) { check in
                        HubCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HealthFindingRow(finding: check.finding)
                                if let action = check.action {
                                    Button(actionTitle(action)) { perform(action) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                    HubCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Share a private support summary", systemImage: "lock.shield").font(.headline)
                            Text("Only app/system versions, check time, result codes and statuses are included. Names, addresses, paths, certificate fingerprints, prompts and tokens are excluded.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(copied ? "Copied" : "Copy Support Report", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(report.supportText, forType: .string)
                                    copied = true
                                }
                                Button("Save Report…") { save(report) }
                            }
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem { Button("Run Checks", systemImage: "arrow.clockwise") { refreshID = UUID() }.disabled(checking) }
        }
        .task(id: "\(deviceID)|\(capability)|\(refreshID)") {
            checking = true; report = nil; error = nil; copied = false
            let result = await HubDiagnostics.run(core: hub.core, server: hub.server,
                deviceID: deviceID.isEmpty ? nil : deviceID, capability: Capability(rawValue: capability))
            guard !Task.isCancelled else { return }
            report = result; checking = false
        }
    }

    private func actionTitle(_ action: DiagnosticAction) -> String {
        switch action {
        case .startHub: "Start Hub"
        case .settings: "Open Settings"
        case .integrations: "Check Integrations"
        case .workflows: "Check Workflows"
        case .devices: "Manage Devices"
        case .files: "Manage Files"
        }
    }

    private func perform(_ action: DiagnosticAction) {
        switch action {
        case .startHub: Task { await hub.start(); refreshID = UUID() }
        case .settings: hub.requestedSection = .settings
        case .integrations: hub.requestedSection = .integrations
        case .workflows: hub.requestedSection = .workflows
        case .devices: hub.requestedSection = .devices
        case .files: hub.requestedSection = .files
        }
    }

    private func save(_ report: DiagnosticReport) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "localhub-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.supportText.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = HubController.describe(error) }
    }
}
