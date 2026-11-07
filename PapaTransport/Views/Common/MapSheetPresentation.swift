import Foundation
import Observation

@MainActor @Observable
final class MapSheetPresentation {
    enum Detent: CaseIterable {
        case collapsed
        case medium
        case expanded

        var accessibilityDescription: String {
            switch self {
            case .collapsed: "Next departure"
            case .medium: "Partly expanded"
            case .expanded: "Fully expanded"
            }
        }
    }

    var detent: Detent = .medium
    private(set) var revealID = UUID()
    private(set) var focusedStopID: String?

    func showDepartures(at stopID: String? = nil) {
        focusedStopID = stopID
        detent = .expanded
        revealID = UUID()
    }
}
