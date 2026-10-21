import AppKit
import Observation

struct ShelfItem: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String
    /// Set for screenshots and downloads added automatically; those expire after a day.
    var source: FileArrivals.Kind?
    var addedAt: Date?
    var url: URL { URL(fileURLWithPath: path) }

    init(path: String, source: FileArrivals.Kind? = nil, addedAt: Date? = Date()) {
        self.path = path
        self.source = source
        self.addedAt = addedAt
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Files dropped on the notch. Only paths are stored, the files are never copied.
@MainActor @Observable
final class Shelf: NSObject, NSSharingServiceDelegate {
    private(set) var items: [ShelfItem] = []
    var selection: Set<ShelfItem.ID> = []
    /// True while the AirDrop sheet is open, so the panel stays open.
    private(set) var isSharing = false
    /// The app that was frontmost before AirDrop activated us, re-activated afterwards.
    private var previousApp: NSRunningApplication?
    private var sharingTimeout: Task<Void, Never>?

    private let storeURL: URL

    init(storeURL: URL = Shelf.defaultStoreURL) {
        self.storeURL = storeURL
        super.init()
        load()
    }

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchHub/shelf.json")
    }

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    static let autoItemLifetime: TimeInterval = 24 * 60 * 60

    func add(_ urls: [URL], source: FileArrivals.Kind? = nil, now: Date = Date()) {
        var seen = Set<String>()
        let new = urls.filter(\.isFileURL)
            .map { ShelfItem(path: $0.standardizedFileURL.path, source: source, addedAt: now) }
            .filter { seen.insert($0.path).inserted }
        guard !new.isEmpty else { return }
        items.removeAll { item in new.contains(item) }
        items.insert(contentsOf: new, at: 0)
        save()
    }

    /// Drops automatically added items after a day; files the user put here stay.
    func removeExpired(now: Date = Date()) {
        let kept = items.filter { item in
            guard item.source != nil, let added = item.addedAt else { return true }
            return now.timeIntervalSince(added) < Self.autoItemLifetime
        }
        guard kept.count != items.count else { return }
        items = kept
        selection = selection.filter { id in kept.contains { $0.id == id } }
        save()
    }

    func remove(_ removed: [ShelfItem]) {
        items.removeAll { removed.contains($0) }
        selection.subtract(removed.map(\.id))
        save()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        save()
    }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func revealInFinder(_ shown: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(shown.map(\.url))
    }

    func airDrop(_ shared: [ShelfItem]) {
        airDrop(urls: shared.map(\.url))
    }

    func airDrop(urls: [URL]) {
        let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return }
        service.delegate = self
        isSharing = true
        // If the sheet never reports back, do not keep the panel pinned open forever.
        sharingTimeout?.cancel()
        sharingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.isSharing = false
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finishSharing() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        MainActor.assumeIsolated { finishSharing() }
    }

    private func finishSharing() {
        sharingTimeout?.cancel()
        isSharing = false
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        previousApp = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        if items.count != saved.count { save() }
        removeExpired()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
    }
}
