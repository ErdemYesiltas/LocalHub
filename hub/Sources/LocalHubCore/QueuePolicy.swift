import Foundation

public enum JobSchedule: String, Codable, Sendable, CaseIterable {
    case anytime, night
}

/// Local Mac wall-clock hours. A window may cross midnight; equal endpoints
/// intentionally mean all day. Pausing stops admission, never a running workflow.
public struct QueueSettings: Codable, Sendable, Equatable {
    public var paused = false
    public var maxConcurrent = 2
    public var nightStartHour = 22
    public var nightEndHour = 7
    public init() {}

    public func validate() throws {
        guard (1...16).contains(maxConcurrent), (0...23).contains(nightStartHour), (0...23).contains(nightEndHour) else {
            throw ConfigurationError.invalid("Queue concurrency must be 1–16 and night hours must be 0–23")
        }
    }

    public func allowsNight(at date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if nightStartHour == nightEndHour { return true }
        if nightStartHour < nightEndHour { return hour >= nightStartHour && hour < nightEndHour }
        return hour >= nightStartHour || hour < nightEndHour
    }
}

/// Priority ages once every five minutes so low-priority work cannot starve.
/// Equal scores rotate among devices, with FIFO inside a device.
enum QueueOrder {
    static func ordered(_ jobs: [HubJob], lastServed: [String: UInt64], now: Date) -> [HubJob] {
        func score(_ job: HubJob) -> Int {
            (job.priority ?? 0) + Int(max(0, now.timeIntervalSince(job.createdAt)) / 300)
        }
        return jobs.sorted { a, b in
            if score(a) != score(b) { return score(a) > score(b) }
            let left = lastServed[a.deviceID] ?? 0, right = lastServed[b.deviceID] ?? 0
            if left != right { return left < right }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
    }
}
