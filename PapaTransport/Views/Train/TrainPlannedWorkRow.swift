import SwiftUI

// MARK: - Planned Work Row

struct TrainPlannedWorkRow: View {
    let work: TrainPlannedWork

    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette

    private var badge: (text: String, color: Color) {
        work.upcomingCurrent.lowercased() == "current"
            ? ("Current", palette.warning)
            : ("Upcoming", palette.info)
    }

    var body: some View {
        Button {
            if let url = URL(string: work.link), !work.link.isEmpty { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(badge.text)
                    .font(.transitBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.15))
                    .foregroundStyle(badge.color)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    Text(work.title)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !work.affectedStations.isEmpty {
                        Text(work.affectedStations.joined(separator: " · "))
                            .font(.transitBadge)
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !work.link.isEmpty {
                    Image(systemName: "arrow.up.right.square")
                        .font(.transitBadge)
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
