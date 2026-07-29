import Combine
import Foundation

@MainActor
final class GTFSDownloadProgress: ObservableObject {
    static let shared = GTFSDownloadProgress()

    @Published var isActive = false
    @Published var stage = ""
    @Published var detail = ""
    /// 0…1 once the import starts. Nil while downloading, where the total is
    /// not reported per-chunk — the UI shows an indeterminate bar instead of a
    /// fake one.
    @Published var fraction: Double?

    private init() {}

    func update(stage: String, detail: String = "", fraction: Double? = nil) {
        isActive = true
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
    }

    func finish() {
        isActive = false
        stage = ""
        detail = ""
        fraction = nil
    }
}
