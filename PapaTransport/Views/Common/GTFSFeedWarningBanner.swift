import SwiftUI

/// Surfaces an expired or near-expired Queensland timetable.
///
/// Renders nothing for Victoria (served live by the PTV API, so it has no
/// local schedule to expire) or when the feed is current.
struct GTFSFeedWarningBanner: View {
    let provider: BusProvider

    @ObservedObject private var feedStatus = GTFSFeedStatusStore.shared
    @Environment(\.themePalette) private var palette

    var body: some View {
        if provider.region == .queensland, let warning = feedStatus.warning {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: warning.isError
                      ? "exclamationmark.triangle.fill"
                      : "clock.badge.exclamationmark.fill")
                    .foregroundStyle(warning.isError ? palette.danger : palette.warning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(warning.title)
                        .font(.transitLabel)
                        .foregroundStyle(palette.textPrimary)

                    Text(warning.detail)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                (warning.isError ? palette.danger : palette.warning).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        (warning.isError ? palette.danger : palette.warning).opacity(0.35),
                        lineWidth: 1
                    )
            }
        }
    }
}
