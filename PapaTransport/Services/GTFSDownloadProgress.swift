import Combine
import Foundation

@MainActor
final class GTFSDownloadProgress: ObservableObject {
    static let shared = GTFSDownloadProgress()

    @Published var isActive = false
    @Published var stage = ""
    @Published var detail = ""

    private init() {}

    func update(stage: String, detail: String = "") {
        isActive = true
        self.stage = stage
        self.detail = detail
    }

    func finish() {
        isActive = false
        stage = ""
        detail = ""
    }
}
