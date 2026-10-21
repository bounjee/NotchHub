import Foundation

/// Notices new screenshots and finished downloads so they can land on the shelf.
@MainActor
final class FileArrivals: NSObject {
    enum Kind: String, Codable { case screenshot, download }

    var onArrival: ((URL, Kind) -> Void)?

    private let downloadsURL: URL
    private let startedAt = Date()
    private let query = NSMetadataQuery()
    private var seenScreenshots: Set<String> = []
    private var knownDownloads: Set<String> = []
    private var downloadsSource: DispatchSourceFileSystemObject?
    private var checkTask: Task<Void, Never>?

    init(downloadsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) {
        self.downloadsURL = downloadsURL
    }

    func start(screenshots: Bool = true) {
        if screenshots { startScreenshotQuery() }
        startDownloadsWatcher()
    }

    // MARK: - Screenshots

    /// Spotlight marks screenshots wherever they are saved (Desktop, a custom folder, ...).
    private func startScreenshotQuery() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", startedAt as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.operationQueue = .main
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    @objc private func queryUpdated(_ notification: Notification) {
        let added = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
        for item in added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  seenScreenshots.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path)
            else { continue }
            onArrival?(URL(fileURLWithPath: path), .screenshot)
        }
    }

    // MARK: - Downloads

    private func startDownloadsWatcher() {
        knownDownloads = Set(listDownloads())
        let fd = open(downloadsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDownloadsCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        downloadsSource = source
    }

    /// Browsers touch the folder many times per download; look once things settle.
    private func scheduleDownloadsCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.checkDownloads()
        }
    }

    func checkDownloads() async {
        let current = Set(listDownloads())
        let new = current.subtracting(knownDownloads)
        let candidates = new.filter { Self.isFinished($0, siblings: current) }
        // Unfinished names stay unknown so they are picked up once complete.
        knownDownloads = current.subtracting(new.subtracting(candidates))
        for name in candidates.sorted() {
            let url = downloadsURL.appendingPathComponent(name)
            guard await isSettled(url) else {
                knownDownloads.remove(name)
                continue
            }
            onArrival?(url, .download)
        }
    }

    private func listDownloads() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) ?? []
    }

    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    /// Hidden files, in-progress downloads and Firefox's empty placeholder (next to its .part) are not arrivals.
    static func isFinished(_ name: String, siblings: Set<String>) -> Bool {
        if name.hasPrefix(".") { return false }
        if partialExtensions.contains((name as NSString).pathExtension.lowercased()) { return false }
        return !siblings.contains(name + ".part") && !siblings.contains(name + ".crdownload")
    }

    /// A file whose size holds for a moment is done being written.
    private func isSettled(_ url: URL) async -> Bool {
        func size() -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        }
        guard let first = size() else { return false }
        try? await Task.sleep(for: .milliseconds(600))
        guard let second = size() else { return false }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return first == second && (second > 0 || isDirectory.boolValue)
    }
}
