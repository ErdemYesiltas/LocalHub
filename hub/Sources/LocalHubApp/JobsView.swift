import AppKit
import LocalHubCore
import SwiftUI

struct JobsView: View {
    @Environment(HubController.self) private var hub
    @State private var selection: HubJob.ID?
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", active = "Active", failed = "Failed" }

    private var shown: [HubJob] {
        switch filter {
        case .all: hub.jobs
        case .active: hub.jobs.filter { !$0.status.isFinished }
        case .failed: hub.jobs.filter { $0.status == .failed }
        }
    }

    var body: some View {
        HSplitView {
            List(shown, selection: $selection) { job in
                JobListRow(job: job).tag(job.id)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(filter == .active ? "Nothing running" : "No jobs", systemImage: "clock.arrow.circlepath",
                        description: Text("Image, audio and video requests from paired devices show up here."))
                }
            }
            Group {
                if let job = hub.jobs.first(where: { $0.id == selection }) { JobDetail(job: job) }
                else { ContentUnavailableView("Select a job", systemImage: "clock") }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Jobs")
        .onAppear { if let id = hub.selectedJobID { selection = id; filter = .all } }
        .onChange(of: hub.selectedJobID) { selection = hub.selectedJobID; filter = .all }
        .navigationSubtitle("\(hub.jobs.filter { !$0.status.isFinished }.count) running or queued")
        .toolbar {
            ToolbarItem {
                Button(hub.settings.queue.paused ? "Resume Queue" : "Pause Queue",
                       systemImage: hub.settings.queue.paused ? "play.fill" : "pause.fill") {
                    var next = hub.settings; next.queue.paused.toggle()
                    Task { await hub.apply(next) }
                }
                .help("Pausing holds waiting jobs; workflows already submitted keep running")
            }
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

extension HubJob {
    var statusSymbol: String {
        switch status {
        case .queued: "clock"
        case .inProgress: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .queued, .inProgress: .accentColor
        case .cancelled: .secondary
        }
    }

    /// "Sampler 12/30 · about 1 min left", "2 ahead in ComfyUI", "Waiting for memory…".
    var activityLine: String {
        if let waitingReason { return waitingReason }
        var parts: [String] = []
        if status == .queued {
            parts.append(queuePosition.map { $0 == 0 ? "Next in ComfyUI" : "\($0) ahead in ComfyUI" } ?? "Queued")
        }
        if let currentNode { parts.append(currentNode) }
        if let etaSeconds { parts.append("about \(Self.format(TimeInterval(etaSeconds))) left") }
        return parts.isEmpty ? (status == .inProgress ? "Running" : status.rawValue) : parts.joined(separator: " · ")
    }

    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

struct JobListRow: View {
    let job: HubJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.statusSymbol).foregroundStyle(job.statusColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.prompt).lineLimit(1)
                if job.status.isFinished {
                    Text("\(job.deviceName) · \(job.model) · \(job.duration.map(HubJob.format) ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    ProgressView(value: job.progress ?? 0).controlSize(.small)
                    Text(job.activityLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct JobDetail: View {
    @Environment(HubController.self) private var hub
    let job: HubJob
    @State private var showingRecipe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label(job.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: job.statusSymbol)
                        .foregroundStyle(job.statusColor).font(.headline)
                    Spacer()
                    if !job.status.isFinished { Button("Cancel Job", role: .destructive) { hub.cancel(job) } }
                }
                Text(job.prompt).font(.title3).textSelection(.enabled)
                if job.status == .queued && job.dispatchedAt == nil {
                    Picker("Queue priority", selection: Binding(get: { job.priority ?? 0 }, set: { value in
                        Task {
                            do { try await hub.core.jobs.setPriority(job.id, priority: value) }
                            catch { hub.errorMessage = HubController.describe(error) }
                        }
                    })) {
                        ForEach(-10...10, id: \.self) { Text($0 == 0 ? "Normal (0)" : String($0)).tag($0) }
                    }.frame(maxWidth: 280)
                }
                if job.schedule == .night {
                    Label("Night queue · \(hub.settings.queue.nightStartHour):00–\(hub.settings.queue.nightEndHour):00 on this Mac", systemImage: "moon.stars")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let recipe = job.recipe {
                    HubCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Production recipe saved", systemImage: "doc.text.magnifyingglass").font(.headline)
                                Text("\(recipe.template.name) · v\(recipe.workflowVersion.prefix(10))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recipe & Replay…") { showingRecipe = true }
                        }
                    }
                } else {
                    Text("Recipes are available for jobs created after this update.").font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Workflow").foregroundStyle(.secondary); Text(job.model).font(.body.monospaced()) }
                    GridRow { Text("Device").foregroundStyle(.secondary); Text(job.deviceName) }
                    GridRow { Text("Requested").foregroundStyle(.secondary); Text(job.createdAt.formatted(date: .abbreviated, time: .standard)) }
                    if let started = job.startedAt {
                        GridRow {
                            Text("Waited").foregroundStyle(.secondary)
                            Text(HubJob.format(started.timeIntervalSince(job.createdAt)))
                        }
                    }
                    if let duration = job.duration {
                        GridRow { Text(job.status.isFinished ? "Took" : "Running for").foregroundStyle(.secondary); Text(HubJob.format(duration)) }
                    }
                    if let promptID = job.promptID {
                        GridRow { Text("ComfyUI prompt").foregroundStyle(.secondary); Text(promptID).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                .font(.callout)
                if !job.status.isFinished {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: job.progress ?? 0)
                        Text(job.activityLine).font(.callout).foregroundStyle(.secondary)
                    }
                    if let data = hub.previews[job.id], let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let error = job.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
                let outputs = hub.files.filter { job.outputFileIDs.contains($0.id) }
                if !outputs.isEmpty {
                    Text("Outputs").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(outputs) { file in
                            FileCard(file: file, url: hub.core.files.contentURL(file), owner: job.deviceName)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(hub.core.files.contentURL(file)) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingRecipe) { RecipeSheet(job: job) }
    }
}
