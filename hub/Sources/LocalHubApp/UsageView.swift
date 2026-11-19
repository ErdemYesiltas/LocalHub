import Charts
import LocalHubCore
import SwiftUI

struct UsageView: View {
    @Environment(HubController.self) private var hub
    @State private var days = 14
    @State private var report: UsageReport?
    @State private var clearing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let report, report.totalRequests > 0 {
                    HStack(spacing: 16) {
                        stat("AI requests", "\(report.totalRequests)")
                        stat("Devices", "\(report.devices.count)")
                        stat("Tokens out", "\(report.devices.reduce(0) { $0 + $1.completionTokens })")
                        stat("Failed jobs", "\(report.devices.reduce(0) { $0 + $1.failedJobs })")
                    }
                    Text("Counts are independent of chat history. Tokens reflect provider reports; \(report.unreportedTokenRequests) completed text request(s) did not report complete token usage.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Requests per day").font(.headline)
                        Chart(report.days) { day in
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Requests", day.count))
                                .foregroundStyle(by: .value("Capability", Capability(rawValue: day.capability)?.title ?? day.capability))
                        }
                        .chartXScale(domain: periodStart...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!)
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: days > 14 ? 5 : 2)) { _ in
                            AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        } }
                        .frame(height: 220)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Devices").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow { header("Device"); header("AI requests"); header("Tokens in / out"); header("Jobs"); header("Failed") }
                            ForEach(report.devices) { device in
                                GridRow {
                                    Text(device.name)
                                    Text("\(device.requests)").monospacedDigit()
                                    Text("\(device.promptTokens) / \(device.completionTokens)").monospacedDigit()
                                    Text("\(device.jobs)").monospacedDigit()
                                    Text("\(device.failedJobs)").monospacedDigit().foregroundStyle(device.failedJobs > 0 ? .red : .primary)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Models, workflows and tools").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow { header("Model"); header("Runs"); header("Failures"); header("Average") }
                            ForEach(report.models) { model in
                                GridRow {
                                    Label(modelTitle(model), systemImage: model.id.hasPrefix("unresolved/") ? "exclamationmark.triangle" : model.isWorkflow ? "point.topleft.down.to.point.bottomright.curvepath" : model.id.hasPrefix("mcp/") ? "wrench" : "text.bubble")
                                        .font(.body.monospaced())
                                    Text("\(model.runs)").monospacedDigit()
                                    Text("\(model.failures)").monospacedDigit()
                                    Text(model.averageSeconds.map { HubJob.format($0) } ?? "—")
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No usage yet", systemImage: "chart.bar.xaxis",
                        description: Text("Chats and jobs from paired devices in the last \(days) days appear here."))
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem { Button("Clear Usage…", systemImage: "trash") { clearing = true } }
            ToolbarItem {
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
            }
        }
        .confirmationDialog("Clear all usage metadata?", isPresented: $clearing) {
            Button("Clear Usage", role: .destructive) {
                do { try hub.core.store.clearUsage(); report = hub.usage(days: days) }
                catch { hub.errorMessage = HubController.describe(error) }
            }
        } message: { Text("Chat history and output files stay unchanged. Active requests can create new metadata when they finish.") }
        .task(id: days) {
            while !Task.isCancelled {
                report = hub.usage(days: days)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var periodStart: Date {
        Calendar.current.date(byAdding: .day, value: -days + 1, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func header(_ text: String) -> some View { Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
    private func modelTitle(_ model: UsageReport.Model) -> String {
        guard model.id.hasPrefix("unresolved/") else { return model.id }
        let capability = String(model.id.dropFirst("unresolved/".count))
        return "Rejected \(Capability(rawValue: capability)?.title.lowercased() ?? capability) requests"
    }
}
