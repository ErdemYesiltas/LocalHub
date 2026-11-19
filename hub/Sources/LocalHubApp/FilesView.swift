import AppKit
import LocalHubCore
import SwiftUI

struct FilesView: View {
    @Environment(HubController.self) private var hub
    @State private var device = "all"
    @State private var deleting: HubFile?
    @State private var recipeJob: HubJob?

    private var shown: [HubFile] {
        device == "all" ? hub.files : hub.files.filter { ($0.deviceID ?? "mac") == device }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                ForEach(shown) { file in
                    FileCard(file: file, url: hub.core.files.contentURL(file), owner: hub.deviceName(file.deviceID))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(hub.core.files.contentURL(file)) }
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(hub.core.files.contentURL(file)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hub.core.files.contentURL(file)]) }
                            if let jobID = file.jobID, let job = try? hub.core.store.job(jobID), job.recipe != nil {
                                Button("Production Recipe…") { recipeJob = job }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = file }
                        }
                }
            }
            .padding(20)
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("No files", systemImage: "photo.stack",
                    description: Text("Images that devices upload or generate through LocalHub appear here."))
            }
        }
        .navigationTitle("Files")
        .navigationSubtitle(ByteCountFormatter.string(fromByteCount: Int64(shown.reduce(0) { $0 + $1.bytes }), countStyle: .file))
        .toolbar {
            ToolbarItem {
                Picker("Device", selection: $device) {
                    Text("All devices").tag("all")
                    ForEach(hub.devices) { Text($0.name).tag($0.id) }
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { hub.refreshFiles() }
            }
        }
        .confirmationDialog("Delete \(deleting?.filename ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { hub.deleteFile(deleting) } }
        } message: {
            Text("The device that owns it loses it too. This can't be undone.")
        }
        .onAppear { hub.refreshFiles() }
        .sheet(item: $recipeJob) { RecipeSheet(job: $0) }
    }
}

struct FileCard: View {
    let file: HubFile
    let url: URL
    let owner: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.background.secondary)
                if file.mime.hasPrefix("image/"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)).padding(4)
                } else {
                    Image(systemName: file.mime.hasPrefix("audio/") ? "waveform" : file.mime.hasPrefix("video/") ? "film" : "doc")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            Text(file.filename).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Image(systemName: file.source == "job" ? "wand.and.stars" : "arrow.up.circle")
                Text("\(owner) · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))")
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(file.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct JobRow: View {
    @Environment(HubController.self) private var hub
    let job: HubJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.prompt).lineLimit(1)
                    Text(job.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if job.status == .inProgress || job.status == .queued {
                    ProgressView(value: job.progress ?? 0).controlSize(.small)
                } else {
                    Text(job.error ?? "\(job.deviceName) · \(job.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(job.error == nil ? .secondary : Color.red).lineLimit(1)
                }
            }
            Spacer()
            if !job.status.isFinished {
                Button("Cancel") { hub.cancel(job) }.controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .inProgress: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    private var color: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .queued, .inProgress: .accentColor
        case .cancelled: .secondary
        }
    }
}
