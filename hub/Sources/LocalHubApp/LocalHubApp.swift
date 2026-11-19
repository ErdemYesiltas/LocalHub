import AppKit
import LocalHubCore
import SwiftUI

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            return
        }
        LocalHubApp.main()
    }
}

@MainActor
enum Boot {
    static let result: Result<HubController, any Error> = {
        do {
            let controller = try HubController()
            Task { await controller.start() }
            Notifier.requestPermission()
            return .success(controller)
        } catch { return .failure(error) }
    }()
}

struct LocalHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LocalHub", id: "main") {
            switch Boot.result {
            case .success(let controller):
                RootView().environment(controller).frame(minWidth: 860, minHeight: 540)
            case .failure(let error):
                ContentUnavailableView("LocalHub could not start", systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: error)))
                    .frame(minWidth: 480, minHeight: 300)
            }
        }
        .defaultSize(width: 980, height: 640)

        Window("Pair a Device", id: "pair") {
            if case .success(let controller) = Boot.result {
                PairingView().environment(controller)
            }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            if case .success(let controller) = Boot.result {
                MenuBarContent().environment(controller)
            } else {
                Text("LocalHub could not start")
                Button("Quit") { NSApp.terminate(nil) }
            }
        } label: {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        }
    }
}

/// Hides the Dock icon when no window is open; the hub keeps serving from the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
                    if !visible { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard case .success(let controller) = MainActor.assumeIsolated({ Boot.result }) else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await controller.server.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
}

extension NSApplication {
    @MainActor func bringToFront() {
        setActivationPolicy(.regular)
        activate()
    }
}
