import SwiftUI

/// Shows Queensland content only once there is a timetable to show it from.
///
/// Wraps the Queensland Bus and Trains tabs only — Plan needs no schedule, and
/// Victoria is served live by the PTV API, so both pass straight through.
struct GTFSProvisioningGate<Content: View>: View {
    let region: TransportRegion
    @ViewBuilder let content: () -> Content

    @ObservedObject private var store = GTFSProvisioningStore.shared

    var body: some View {
        Group {
            if region != .queensland {
                content()
            } else {
                switch store.state {
                case .ready:
                    content()
                case .checking:
                    // Deliberately blank: the bundled path resolves in
                    // milliseconds and a spinner would just flicker.
                    Color.clear
                case .working:
                    GTFSFirstRunView(failure: nil)
                case .failed(let message):
                    GTFSFirstRunView(failure: message)
                }
            }
        }
        .task(id: region) {
            guard region == .queensland else { return }
            await store.provisionIfNeeded()
        }
    }
}

/// First-run download experience, and the offline dead end it can reach.
struct GTFSFirstRunView: View {
    let failure: String?

    @ObservedObject private var progress = GTFSDownloadProgress.shared
    @ObservedObject private var store = GTFSProvisioningStore.shared
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: failure == nil ? "arrow.down.circle" : "wifi.exclamationmark")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(failure == nil ? palette.accentText : palette.danger)

            VStack(spacing: 8) {
                Text(failure == nil ? "Setting up Queensland" : "Couldn't set up Queensland")
                    .font(.transitHeadline)
                    .foregroundStyle(palette.textPrimary)

                Text(failure ?? bodyText)
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            if failure == nil {
                VStack(spacing: 10) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .tint(palette.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(palette.accent)
                    }

                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.transitBadge)
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                .padding(.horizontal, 44)
            } else {
                Button("Try Again") {
                    Task { await store.retry() }
                }
                .buttonStyle(TransitPrimaryButtonStyle())
                .padding(.horizontal, 44)
            }

            Spacer()

            Text("This happens once. Afterwards the timetable updates itself in the background.")
                .font(.transitBadge)
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.screenBackground.ignoresSafeArea())
    }

    private var bodyText: String {
        progress.stage.isEmpty
            ? "Downloading the South East Queensland timetable — about 28 MB."
            : progress.stage
    }
}
