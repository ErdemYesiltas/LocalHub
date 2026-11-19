import SwiftUI

struct HubCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }
}

struct StatusPill: View {
    let title: String
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
    }
}

struct SectionHeading: View {
    let title: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action, action: perform).buttonStyle(.link)
        }
    }
}

struct DashboardStat: View {
    let title: String
    let value: String
    let symbol: String
    let detail: String

    var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
    }
}
