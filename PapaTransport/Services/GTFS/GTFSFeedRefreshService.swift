import Foundation

/// Keeps the Queensland timetable current without a manual rebuild.
///
/// The bundled database remains the floor — first launch is instant and works
/// offline. This only steps in as that database approaches its expiry, pulls
/// the published SEQ_GTFS.zip, and imports it over the top. If anything fails
/// the existing database is left untouched.
actor GTFSFeedRefreshService {
    static let shared = GTFSFeedRefreshService()

    private init() {}

    static let feedURL = URL(string: "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip")!

    private enum Defaults {
        static let etag = "gtfsSeqFeedETag"
        static let lastAttempt = "gtfsSeqFeedLastAttempt"
    }

    /// Don't re-attempt more than once a day: the feed is republished weekly
    /// at most, and a failing network shouldn't mean a 28 MB retry per launch.
    private static let minimumRetryInterval: TimeInterval = 24 * 60 * 60

    private var activeTask: Task<Bool, Never>?
    private var provisionTask: Task<GTFSFeedValidity, Error>?

    /// Gets a usable timetable in place, by whatever route is available.
    ///
    /// Order matters: an already-installed database wins, then a bundled copy
    /// (instant, offline), and only failing both do we download. Shipping the
    /// bundled database is therefore optional — dropping it from the app
    /// trades ~320 MB of download size for a one-off first-run fetch.
    func provision() async throws -> GTFSFeedValidity {
        if let provisionTask { return try await provisionTask.value }

        let task = Task<GTFSFeedValidity, Error> {
            if await GTFSDatabase.shared.isDatabaseReady(),
               let validity = await GTFSDatabase.shared.feedValidity(),
               validity.isUsable() {
                return validity
            }

            if await GTFSDatabase.shared.hasBundledDatabaseAsset() {
                try await GTFSDatabase.shared.ensureReady()
                if let validity = await GTFSDatabase.shared.feedValidity(), validity.isUsable() {
                    return validity
                }
                // A bundled database that has already lapsed is no better than
                // none — fall through and fetch a current one.
            }

            guard let validity = try await downloadAndImport() else {
                throw URLError(.cannotLoadFromNetwork)
            }
            return validity
        }

        provisionTask = task
        defer { provisionTask = nil }
        return try await task.value
    }

    enum Outcome {
        case notNeeded
        case alreadyCurrent
        case updated(GTFSFeedValidity)
        case failed(String)
    }

    /// Refreshes when the installed feed is at or near expiry.
    /// Returns true when the database on disk changed.
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Bool {
        if let activeTask { return await activeTask.value }

        let task = Task<Bool, Never> { [force] in
            await performRefresh(force: force)
        }
        activeTask = task
        let result = await task.value
        activeTask = nil
        return result
    }

    private func performRefresh(force: Bool) async -> Bool {
        try? await GTFSDatabase.shared.ensureReady()

        if !force {
            guard let validity = await GTFSDatabase.shared.feedValidity(),
                  validity.shouldRefresh()
            else { return false }

            let defaults = UserDefaults.standard
            let lastAttempt = defaults.double(forKey: Defaults.lastAttempt)
            if lastAttempt > 0,
               Date().timeIntervalSince1970 - lastAttempt < Self.minimumRetryInterval,
               validity.isUsable() {
                // Still serving usable data — no need to hammer the endpoint.
                return false
            }
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Defaults.lastAttempt)

        await report(stage: "Checking for timetable update", detail: "TransLink SEQ")

        do {
            let validity = try await downloadAndImport(allowNotModified: true)
            guard let validity else {
                // 304 — the published feed has not moved since the last import.
                return false
            }
            print("✅ Queensland timetable updated: \(validity.startDate) → \(validity.endDate)")
            return true
        } catch {
            // Deliberately non-fatal: the previous database is still in place
            // and still serving whatever it can. The ETag is not committed, so
            // the next attempt re-downloads rather than seeing a 304 and
            // concluding it is already up to date.
            print("⚠️ Queensland timetable update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and imports the published feed.
    ///
    /// When `allowNotModified` is true a 304 returns nil; provisioning passes
    /// false, because "unchanged" is meaningless when there is no database to
    /// leave unchanged — a stale ETag there must force a full fetch.
    @discardableResult
    private func downloadAndImport(allowNotModified: Bool = false) async throws -> GTFSFeedValidity? {
        do {
            let downloadURL = try await downloadIfChanged(honourETag: allowNotModified)
            guard let downloadURL else {
                await finishReporting(commitETag: false)
                return nil
            }
            defer { try? FileManager.default.removeItem(at: downloadURL) }

            let destination = try await GTFSDatabase.shared.databasePathForImport()
            let importer = GTFSFeedImporter(
                archiveURL: downloadURL,
                destinationPath: destination
            ) { stage, fraction in
                Task { @MainActor in
                    GTFSDownloadProgress.shared.update(
                        stage: "Updating Queensland timetable",
                        detail: "\(stage) — \(Int(fraction * 100))%",
                        fraction: fraction
                    )
                }
            }

            let validity = try await runOffCooperativePool(importer)

            // The actor may be holding a handle to the file we just replaced.
            await GTFSDatabase.shared.reopenAfterExternalReplacement()
            await GTFSFeedStatusStore.shared.refresh()

            await finishReporting(commitETag: true)
            return validity
        } catch {
            await finishReporting(commitETag: false)
            throw error
        }
    }

    /// Runs the import on a dedicated background thread.
    ///
    /// `GTFSFeedImporter` is `nonisolated`, so it already stays off the main
    /// actor — but it is a *synchronous* call that runs for tens of seconds.
    /// Left on the Swift cooperative pool it would occupy one of its few
    /// threads for that whole time and stall unrelated async work. A GCD queue
    /// is the right home for long blocking CPU work.
    private func runOffCooperativePool(
        _ importer: GTFSFeedImporter
    ) async throws -> GTFSFeedValidity {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try importer.run())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Conditional GET — returns nil when the published feed has not changed
    /// since the last successful import.
    private func downloadIfChanged(honourETag: Bool) async throws -> URL? {
        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 120
        // Our stored ETag is the source of truth — it is only committed after
        // a successful import, so URLSession's own cache must not answer for
        // a download that never made it into the database.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if honourETag, let etag = UserDefaults.standard.string(forKey: Defaults.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        await report(stage: "Downloading timetable", detail: "About 28 MB")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }

        if http.statusCode == 304 {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }

        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw URLError(.badServerResponse)
        }

        // URLSession deletes the temp file when this call returns, so move it
        // somewhere we control before handing it to the importer.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("SEQ_GTFS-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: temporaryURL, to: staged)

        // Only remembered after a successful import, so a failed import
        // retries rather than being skipped as "unchanged".
        pendingETag = http.value(forHTTPHeaderField: "Etag")

        return staged
    }

    private var pendingETag: String?

    private func report(stage: String, detail: String) async {
        await MainActor.run {
            GTFSDownloadProgress.shared.update(stage: stage, detail: detail)
        }
    }

    private func finishReporting(commitETag: Bool) async {
        if commitETag, let pendingETag {
            UserDefaults.standard.set(pendingETag, forKey: Defaults.etag)
        }
        pendingETag = nil
        await MainActor.run {
            GTFSDownloadProgress.shared.finish()
        }
    }
}
