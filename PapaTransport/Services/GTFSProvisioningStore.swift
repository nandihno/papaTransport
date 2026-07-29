import Combine
import Foundation

/// Whether Queensland has a usable timetable yet.
///
/// Only meaningful for Queensland: Victoria is served live by the PTV API and
/// has nothing to provision. The bundled database makes this resolve instantly;
/// without it, first run has to download and import before any board can be
/// shown, and that is a state the UI must be able to render honestly.
@MainActor
final class GTFSProvisioningStore: ObservableObject {
    static let shared = GTFSProvisioningStore()

    enum State: Equatable {
        /// Not yet checked. Renders as a quiet placeholder, never as a
        /// download prompt — the common path resolves to `.ready` immediately
        /// and a flash of "Downloading…" would be a lie.
        case checking
        case ready
        case working
        case failed(String)
    }

    @Published private(set) var state: State = .checking

    private init() {}

    private var isProvisioning = false

    func provisionIfNeeded() async {
        guard !isProvisioning else { return }
        if case .ready = state { return }

        isProvisioning = true
        defer { isProvisioning = false }

        // Fast path: something usable is already installed.
        if await GTFSDatabase.shared.isDatabaseReady(),
           let validity = await GTFSDatabase.shared.feedValidity(),
           validity.isUsable() {
            state = .ready
            await GTFSFeedStatusStore.shared.refresh()
            return
        }

        // An expired database still beats no database — the board will be
        // empty, but the warning banner explains why and everything else
        // (alerts, live vehicles, the map) keeps working.
        let hasUnusableDatabase = await GTFSDatabase.shared.isDatabaseReady()

        state = hasUnusableDatabase ? .ready : .working

        do {
            _ = try await GTFSFeedRefreshService.shared.provision()
            state = .ready
        } catch {
            state = hasUnusableDatabase ? .ready : .failed(message(for: error))
        }

        await GTFSFeedStatusStore.shared.refresh()
    }

    func retry() async {
        state = .checking
        await provisionIfNeeded()
    }

    private func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. The Queensland timetable needs to be downloaded once — about 28 MB — before departures can be shown."
            case .timedOut:
                return "The download timed out. Check your connection and try again."
            default:
                return "The timetable could not be downloaded (\(urlError.localizedDescription))."
            }
        }
        return error.localizedDescription
    }
}
