import LocalHubCore
import SwiftUI

struct PairingView: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 18) {
            if let device = hub.lastPaired {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("\(device.name) is paired").font(.title2.weight(.semibold))
                Text("It can now use: \(device.scopes.isEmpty ? "nothing yet" : device.scopes.joined(separator: ", ")). Change this under Devices.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Pair Another") { Task { await hub.openPairing() } }
                    Button("Done") { dismissWindow(id: "pair") }.keyboardShortcut(.defaultAction)
                }
            } else if let window = hub.pairingWindow, let invite = hub.invite {
                Text("Scan with ArtBlend or Olive Studio").font(.title3.weight(.semibold))
                Picker("Device policy", selection: Binding(get: { hub.settings.defaultDeviceProfileID ?? "" }, set: { id in
                    Task {
                        await hub.closePairing()
                        var next = hub.settings; next.defaultDeviceProfileID = id.isEmpty ? nil : id
                        await hub.apply(next); await hub.openPairing()
                    }
                })) {
                    Text("Default permissions").tag("")
                    ForEach(hub.settings.deviceProfiles) { Text($0.name).tag($0.id) }
                }.frame(width: 340)
                QRCodeView(text: invite).frame(width: 260, height: 260)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(window.expiresAt.timeIntervalSince(context.date)))
                    VStack(spacing: 6) {
                        Text(window.code.map(String.init).joined(separator: " "))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        if remaining > 0 {
                            Text("Or enter this code with \(hub.address.replacingOccurrences(of: "https://", with: "")) · \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Code expired — Get a New Code") { Task { await hub.openPairing() } }
                        }
                    }
                }
                if !hub.settings.lanEnabled {
                    lanWarning
                } else if hub.reachableHosts.count > 1 {
                    @Bindable var hub = hub
                    Picker("Reach this Mac at", selection: Binding(get: { hub.inviteHost ?? hub.reachableHosts.first ?? "" },
                                                                    set: { hub.inviteHost = $0 })) {
                        ForEach(hub.reachableHosts, id: \.self) { host in
                            Text(LocalNetwork.isVPN(host) ? "\(host) (VPN)" : host).tag(host)
                        }
                    }
                    .frame(width: 300)
                }
                if !hub.isRunning {
                    Label("The hub is not running. Start it from Overview.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .frame(width: 420)
        .task { if hub.pairingWindow == nil { await hub.openPairing() } }
        .onDisappear { Task { await hub.closePairing() } }
    }

    private var lanWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Only this Mac can reach the hub right now.", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.medium))
            Toggle("Allow devices on this network", isOn: Binding(get: { hub.settings.lanEnabled }, set: { enabled in
                var next = hub.settings
                next.lanEnabled = enabled
                Task { await hub.apply(next); await hub.openPairing() }
            }))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct QRCodeView: View {
    private let modules: [[Bool]]

    init(text: String) { modules = PairingInvite.modules(for: text) ?? [] }

    var body: some View {
        Canvas { context, size in
            let quiet = 3
            let count = modules.count + quiet * 2
            let cell = floor(min(size.width, size.height) / CGFloat(max(count, 1)))
            let origin = CGPoint(x: (size.width - cell * CGFloat(count)) / 2, y: (size.height - cell * CGFloat(count)) / 2)
            context.fill(Path(CGRect(origin: origin, size: CGSize(width: cell * CGFloat(count), height: cell * CGFloat(count)))), with: .color(.white))
            var path = Path()
            for (y, row) in modules.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    path.addRect(CGRect(x: origin.x + CGFloat(x + quiet) * cell, y: origin.y + CGFloat(y + quiet) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(.black))
        }
        .accessibilityLabel("Pairing QR code")
    }
}
